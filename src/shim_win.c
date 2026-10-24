// Windows platform layer for FreeVoiceTranscribe.
// Exposes the exact same C interface (shim.h) as shim.m on macOS:
// - System tray icon with live-rendered Orb and context menu
// - Floating per-pixel alpha-blended pill overlay (UpdateLayeredWindow + orb_render_bgra)
// - Global push-to-talk shortcuts (Ctrl+Shift+R / E / T) via WH_KEYBOARD_LL + RegisterHotKey
// - Clipboard stash, read, set, and restore (Unicode UTF-16 <-> UTF-8)
// - Live microphone RMS metering (WinMM waveIn) + speech recognition (libenhance.dll WinRT Speech
//   or built-in Windows SAPI / System.Speech streaming bridge)
// - Free on-device text enhancement & rewriting via Windows Copilot Runtime (Phi Silica in
//   libenhance.dll) with automatic fallback to built-in Windows Copilot / Windows AI helper script.

#define _CRT_SECURE_NO_WARNINGS
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <shellapi.h>
#include <mmsystem.h>
#include <shlobj.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "shim.h"
#include "orb.h"

#define WM_SA_TRAY       (WM_APP + 1)
#define WM_SA_HOTKEY     (WM_APP + 2)
#define WM_SA_TEXT       (WM_APP + 3)
#define WM_SA_ERROR      (WM_APP + 4)
#define WM_SA_ENH_DONE   (WM_APP + 5)
#define WM_SA_RW_DONE    (WM_APP + 6)
#define WM_SA_TOGGLE     (WM_APP + 7)

#define ID_TIMER_ANIM    1
#define ID_TIMER_BASE    100

enum {
    CMD_TOGGLE_PLAIN = 1001,
    CMD_TOGGLE_ENHANCE = 1002,
    CMD_TOGGLE_REWRITE = 1003,
    CMD_STYLE_BASE = 1010, // .. 1014
    CMD_SOUNDS = 1020,
    CMD_VOCAB = 1021,
    CMD_QUIT = 1022,
};

static const int kPillHeight = 56;
static const int kOrbSide = 56;

static sa_callbacks g_cb;
static HINSTANCE g_hinst;
static HWND g_hwnd_msg;
static HWND g_hwnd_pill;
static HHOOK g_kb_hook;
static NOTIFYICONDATAW g_nid;
static HICON g_tray_icon;
static HFONT g_pill_font;

static OrbAnim g_anim;
static volatile float g_level_in = 0.0f;
static int g_target = SA_IDLE;
static uint64_t g_last_tick_ms = 0;
static UINT g_timer_interval = 0;

static char g_text[16384] = "";
static unsigned int g_notice_gen = 0;
static bool g_notice_active = false;
static bool g_pill_visible = false;
static double g_pill_alpha = 0.0;
static int g_pill_y_offset = 0;

static const char *kStyleKeys[5] = { "clean", "formal", "concise", "prompt", "notes" };
static const wchar_t *kStyleTitles[5] = {
    L"Clean up", L"Formal", L"Concise", L"AI prompt", L"Bullet notes"
};
static int g_current_style = 0;
static bool g_sounds_enabled = true;

// ---- Runtime-loaded Windows Copilot Runtime / WinRT Speech DLL (libenhance.dll) ----

typedef void (*enhance_fn_t)(const char *, const char *, const char *, void (*)(const char *));
typedef void (*prewarm_fn_t)(void);
typedef void (*rewrite_fn_t)(const char *, const char *, const char *, void (*)(const char *));
typedef void (*prepare_fn_t)(void);
typedef bool (*ready_fn_t)(void);
typedef long (*start_fn_t)(const char *, void (*)(const char *, bool, long));
typedef void (*append_fn_t)(const void *, int);
typedef void (*finish_fn_t)(void);

static struct {
    HMODULE mod;
    enhance_fn_t enhance;
    prewarm_fn_t prewarm;
    rewrite_fn_t rewrite;
    prepare_fn_t prepare;
    ready_fn_t ready;
    start_fn_t start;
    append_fn_t append;
    finish_fn_t finish;
} g_sx;

static void get_exe_dir(wchar_t *out, size_t cap) {
    GetModuleFileNameW(NULL, out, (DWORD)cap);
    wchar_t *slash = wcsrchr(out, L'\\');
    if (slash) *slash = 0;
}

static void load_enhance_dll(void) {
    wchar_t path[MAX_PATH];
    get_exe_dir(path, MAX_PATH);
    wcscat_s(path, MAX_PATH, L"\\libenhance.dll");
    HMODULE h = LoadLibraryW(path);
    if (!h) h = LoadLibraryW(L"libenhance.dll");
    if (!h) return;
    g_sx.mod = h;
    g_sx.enhance = (enhance_fn_t)(void *)GetProcAddress(h, "sa_enhance_async");
    g_sx.prewarm = (prewarm_fn_t)(void *)GetProcAddress(h, "sa_enhance_prewarm");
    g_sx.rewrite = (rewrite_fn_t)(void *)GetProcAddress(h, "sa_rewrite_async");
    g_sx.prepare = (prepare_fn_t)(void *)GetProcAddress(h, "sa_sx_prepare");
    g_sx.ready = (ready_fn_t)(void *)GetProcAddress(h, "sa_sx_ready");
    g_sx.start = (start_fn_t)(void *)GetProcAddress(h, "sa_sx_start");
    g_sx.append = (append_fn_t)(void *)GetProcAddress(h, "sa_sx_append");
    g_sx.finish = (finish_fn_t)(void *)GetProcAddress(h, "sa_sx_finish");
}

// ---- UTF-8 / UTF-16 helpers & settings persistence --------------------------

static wchar_t *utf8_to_wide(const char *s) {
    if (!s) return _wcsdup(L"");
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return _wcsdup(L"");
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

static char *wide_to_utf8(const wchar_t *w) {
    if (!w) return _strdup("");
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (n <= 0) return _strdup("");
    char *s = (char *)malloc((size_t)n);
    if (!s) return NULL;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL);
    return s;
}

static void get_appdata_dir(wchar_t *out, size_t cap) {
    wchar_t base[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_APPDATA, NULL, 0, base))) {
        swprintf(out, cap, L"%ls\\FreeVoiceTranscribe", base);
        CreateDirectoryW(out, NULL);
    } else {
        get_exe_dir(out, cap);
    }
}

static void get_vocabulary_path(wchar_t *out, size_t cap) {
    wchar_t dir[MAX_PATH];
    get_appdata_dir(dir, MAX_PATH);
    swprintf(out, cap, L"%ls\\vocabulary.txt", dir);
}

static char *read_vocabulary_terms(void) {
    wchar_t path[MAX_PATH];
    get_vocabulary_path(path, MAX_PATH);
    FILE *f = _wfopen(path, L"rb");
    if (!f) return _strdup("");
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 65536) { fclose(f); return _strdup(""); }
    char *raw = (char *)malloc((size_t)sz + 1);
    char *clean = (char *)malloc((size_t)sz + 1);
    if (!raw || !clean) { free(raw); free(clean); fclose(f); return _strdup(""); }
    size_t rd = fread(raw, 1, (size_t)sz, f);
    fclose(f);
    raw[rd] = 0;
    clean[0] = 0;
    char *ctx = NULL;
    for (char *line = strtok_s(raw, "\r\n", &ctx); line; line = strtok_s(NULL, "\r\n", &ctx)) {
        while (*line == ' ' || *line == '\t') line++;
        if (*line == 0 || *line == '#') continue;
        size_t len = strlen(line);
        while (len > 0 && (line[len - 1] == ' ' || line[len - 1] == '\t')) line[--len] = 0;
        if (len > 0) {
            if (clean[0]) strcat(clean, "\n");
            strcat(clean, line);
        }
    }
    free(raw);
    return clean;
}

static void load_settings(void) {
    HKEY hkey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\FreeVoiceTranscribe", 0, KEY_READ, &hkey) == ERROR_SUCCESS) {
        wchar_t style[32] = {0};
        DWORD sz = sizeof(style);
        if (RegQueryValueExW(hkey, L"enhanceStyle", NULL, NULL, (LPBYTE)style, &sz) == ERROR_SUCCESS) {
            char *s = wide_to_utf8(style);
            if (s) {
                for (int i = 0; i < 5; i++) {
                    if (strcmp(s, kStyleKeys[i]) == 0) g_current_style = i;
                }
                free(s);
            }
        }
        DWORD snd = 1;
        sz = sizeof(snd);
        if (RegQueryValueExW(hkey, L"sounds", NULL, NULL, (LPBYTE)&snd, &sz) == ERROR_SUCCESS) {
            g_sounds_enabled = (snd != 0);
        }
        RegCloseKey(hkey);
    }
}

static void save_settings(void) {
    HKEY hkey;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\FreeVoiceTranscribe", 0, NULL, 0, KEY_WRITE, NULL, &hkey, NULL) == ERROR_SUCCESS) {
        wchar_t *wstyle = utf8_to_wide(kStyleKeys[g_current_style]);
        if (wstyle) {
            RegSetValueExW(hkey, L"enhanceStyle", 0, REG_SZ, (const BYTE *)wstyle, (DWORD)((wcslen(wstyle) + 1) * sizeof(wchar_t)));
            free(wstyle);
        }
        DWORD snd = g_sounds_enabled ? 1 : 0;
        RegSetValueExW(hkey, L"sounds", 0, REG_DWORD, (const BYTE *)&snd, sizeof(snd));
        RegCloseKey(hkey);
    }
}

static void report_error_async(const char *msg) {
    if (!g_hwnd_msg || !msg) return;
    PostMessageW(g_hwnd_msg, WM_SA_ERROR, 0, (LPARAM)_strdup(msg));
}

// ---- Monotonic clock & one-shot timers --------------------------------------

uint64_t sa_now_ms(void) {
    static LARGE_INTEGER freq = {0};
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (uint64_t)(now.QuadPart * 1000ULL / (uint64_t)freq.QuadPart);
}

typedef struct {
    UINT_PTR timer_id;
    void (*fn)(uint32_t);
    uint32_t token;
    bool active;
} OneShotTimer;

#define MAX_ONESHOT_TIMERS 32
static OneShotTimer g_timers[MAX_ONESHOT_TIMERS];
static UINT_PTR g_next_timer_id = ID_TIMER_BASE;

void sa_after_ms(uint32_t ms, void (*fn)(uint32_t), uint32_t token) {
    if (!g_hwnd_msg) return;
    for (int i = 0; i < MAX_ONESHOT_TIMERS; i++) {
        if (!g_timers[i].active) {
            UINT_PTR id = g_next_timer_id++;
            if (g_next_timer_id > 0x7FFF) g_next_timer_id = ID_TIMER_BASE;
            g_timers[i].timer_id = id;
            g_timers[i].fn = fn;
            g_timers[i].token = token;
            g_timers[i].active = true;
            SetTimer(g_hwnd_msg, id, ms ? ms : 1, NULL);
            return;
        }
    }
}

// ---- Sounds -----------------------------------------------------------------

void sa_play(int kind) {
    if (!g_sounds_enabled) return;
    switch (kind) {
        case 0: Beep(880, 35); break;  // Start listening
        case 1: Beep(1175, 40); break; // Done / pasted
        default: MessageBeep(MB_ICONHAND); break;
    }
}

// ---- Accessibility & Keyboard Simulation ------------------------------------

bool sa_accessibility_trusted(bool prompt) {
    (void)prompt;
    return true;
}

bool sa_modifiers_held(void) {
    return (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 ||
           (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0 ||
           (GetAsyncKeyState(VK_MENU) & 0x8000) != 0 ||
           (GetAsyncKeyState(VK_LWIN) & 0x8000) != 0 ||
           (GetAsyncKeyState(VK_RWIN) & 0x8000) != 0;
}

static void send_ctrl_key(WORD vk) {
    INPUT inputs[4];
    memset(inputs, 0, sizeof(inputs));
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = VK_CONTROL;
    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wVk = vk;
    inputs[2].type = INPUT_KEYBOARD;
    inputs[2].ki.wVk = vk;
    inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
    inputs[3].type = INPUT_KEYBOARD;
    inputs[3].ki.wVk = VK_CONTROL;
    inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(4, inputs, sizeof(INPUT));
}

void sa_send_copy(void) { send_ctrl_key('C'); }
void sa_send_paste(void) { send_ctrl_key('V'); }

// ---- Clipboard Management ---------------------------------------------------

static wchar_t *g_saved_clipboard = NULL;
static bool g_has_saved_clipboard = false;

void sa_pasteboard_stash(void) {
    if (g_has_saved_clipboard) return;
    g_has_saved_clipboard = true;
    free(g_saved_clipboard);
    g_saved_clipboard = NULL;
    if (!OpenClipboard(NULL)) return;
    if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        HANDLE h = GetClipboardData(CF_UNICODETEXT);
        if (h) {
            const wchar_t *src = (const wchar_t *)GlobalLock(h);
            if (src) {
                g_saved_clipboard = _wcsdup(src);
                GlobalUnlock(h);
            }
        }
    }
    CloseClipboard();
}

long sa_pasteboard_change_count(void) {
    return (long)GetClipboardSequenceNumber();
}

size_t sa_pasteboard_read(char *buf, size_t cap) {
    if (!buf || cap == 0) return 0;
    buf[0] = 0;
    if (!OpenClipboard(NULL)) return 0;
    size_t out_len = 0;
    if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        HANDLE h = GetClipboardData(CF_UNICODETEXT);
        if (h) {
            const wchar_t *src = (const wchar_t *)GlobalLock(h);
            if (src) {
                char *u8 = wide_to_utf8(src);
                if (u8) {
                    out_len = strlen(u8);
                    if (out_len >= cap) out_len = cap - 1;
                    memcpy(buf, u8, out_len);
                    buf[out_len] = 0;
                    free(u8);
                }
                GlobalUnlock(h);
            }
        }
    }
    CloseClipboard();
    return out_len;
}

void sa_pasteboard_set(const char *text) {
    if (!text) return;
    wchar_t *w = utf8_to_wide(text);
    if (!w) return;
    size_t bytes = (wcslen(w) + 1) * sizeof(wchar_t);
    if (OpenClipboard(NULL)) {
        EmptyClipboard();
        HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
        if (h) {
            void *dst = GlobalLock(h);
            if (dst) {
                memcpy(dst, w, bytes);
                GlobalUnlock(h);
                SetClipboardData(CF_UNICODETEXT, h);
            } else {
                GlobalFree(h);
            }
        }
        CloseClipboard();
    }
    free(w);
}

void sa_pasteboard_stash_and_set(const char *text) {
    sa_pasteboard_stash();
    sa_pasteboard_set(text);
}

void sa_pasteboard_restore(void) {
    if (!g_has_saved_clipboard) return;
    if (OpenClipboard(NULL)) {
        EmptyClipboard();
        if (g_saved_clipboard) {
            size_t bytes = (wcslen(g_saved_clipboard) + 1) * sizeof(wchar_t);
            HGLOBAL h = GlobalAlloc(GMEM_MOVEABLE, bytes);
            if (h) {
                void *dst = GlobalLock(h);
                if (dst) {
                    memcpy(dst, g_saved_clipboard, bytes);
                    GlobalUnlock(h);
                    SetClipboardData(CF_UNICODETEXT, h);
                } else {
                    GlobalFree(h);
                }
            }
        }
        CloseClipboard();
    }
    free(g_saved_clipboard);
    g_saved_clipboard = NULL;
    g_has_saved_clipboard = false;
}

// ---- Animated Orb: System Tray Icon + Floating Layered Pill -----------------

static HICON create_orb_icon(const OrbAnim *a, int sz) {
    BITMAPV5HEADER bi;
    memset(&bi, 0, sizeof(bi));
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = sz;
    bi.bV5Height = -sz; // top-down
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;

    HDC screen_dc = GetDC(NULL);
    void *bits = NULL;
    HBITMAP hbm_color = CreateDIBSection(screen_dc, (BITMAPINFO *)&bi, DIB_RGB_COLORS, &bits, NULL, 0);
    ReleaseDC(NULL, screen_dc);
    if (!hbm_color || !bits) {
        if (hbm_color) DeleteObject(hbm_color);
        return NULL;
    }

    uint32_t *px = (uint32_t *)bits;
    memset(px, 0, (size_t)(sz * sz * 4));
    orb_render_bgra(a, px, sz, 0, 0, sz, sz, true);
    // Convert to premultiplied alpha for smooth tray icon edges
    for (int i = 0; i < sz * sz; i++) {
        uint32_t c = px[i];
        uint32_t al = (c >> 24) & 0xFF;
        uint32_t r = (((c >> 16) & 0xFF) * al) / 255;
        uint32_t g = (((c >> 8) & 0xFF) * al) / 255;
        uint32_t b = ((c & 0xFF) * al) / 255;
        px[i] = (al << 24) | (r << 16) | (g << 8) | b;
    }

    HBITMAP hbm_mask = CreateBitmap(sz, sz, 1, 1, NULL);
    ICONINFO ii;
    memset(&ii, 0, sizeof(ii));
    ii.fIcon = TRUE;
    ii.hbmMask = hbm_mask;
    ii.hbmColor = hbm_color;
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(hbm_color);
    DeleteObject(hbm_mask);
    return icon;
}

static void update_tray_icon(void) {
    HICON icon = create_orb_icon(&g_anim, 18);
    if (!icon) return;
    if (g_tray_icon) DestroyIcon(g_tray_icon);
    g_tray_icon = icon;
    g_nid.hIcon = g_tray_icon;
    Shell_NotifyIconW(NIM_MODIFY, &g_nid);
}

static void get_mouse_monitor_workarea(RECT *out) {
    POINT pt;
    GetCursorPos(&pt);
    HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi;
    memset(&mi, 0, sizeof(mi));
    mi.cbSize = sizeof(mi);
    if (GetMonitorInfoW(mon, &mi)) {
        *out = mi.rcWork;
    } else {
        SystemParametersInfoW(SPI_GETWORKAREA, 0, out, 0);
    }
}

static void render_pill_window(void) {
    if (!g_hwnd_pill || !g_pill_visible) return;

    const char *label_utf8 = g_text[0] ? g_text
        : (g_notice_active ? "" : (g_target == SA_TRANSCRIBING ? "Transcribing\xE2\x80\xA6" : "Listening\xE2\x80\xA6"));
    wchar_t *wlabel = utf8_to_wide(label_utf8);
    if (!wlabel) return;

    RECT wa;
    get_mouse_monitor_workarea(&wa);
    int screen_w = wa.right - wa.left;
    int max_text_w = (int)(screen_w * 0.55);
    if (max_text_w > 520) max_text_w = 520;

    HDC screen_dc = GetDC(NULL);
    HDC mem_dc = CreateCompatibleDC(screen_dc);
    if (!g_pill_font) {
        g_pill_font = CreateFontW(-15, 0, 0, 0, FW_MEDIUM, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    }
    HFONT old_font = (HFONT)SelectObject(mem_dc, g_pill_font);

    SIZE tsz = {0, 0};
    GetTextExtentPoint32W(mem_dc, wlabel, (int)wcslen(wlabel), &tsz);
    int text_w = tsz.cx + 12;
    if (text_w < 96) text_w = 96;
    if (text_w > max_text_w) text_w = max_text_w;

    int w = kOrbSide + 2 + text_w + 26;
    int h = kPillHeight;

    BITMAPINFO bmi;
    memset(&bmi, 0, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void *bits = NULL;
    HBITMAP hbm = CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!hbm || !bits) {
        SelectObject(mem_dc, old_font);
        DeleteDC(mem_dc);
        ReleaseDC(NULL, screen_dc);
        free(wlabel);
        return;
    }

    HBITMAP old_bm = (HBITMAP)SelectObject(mem_dc, hbm);
    uint32_t *px = (uint32_t *)bits;
    double rad = h * 0.5;

    // 1. Draw rounded pill glass background + border
    for (int y = 0; y < h; y++) {
        uint32_t *row = px + y * w;
        for (int x = 0; x < w; x++) {
            double cx = (x < rad) ? rad : ((x > w - rad) ? (w - rad) : (double)x);
            double cy = rad;
            double dx = (x + 0.5) - cx;
            double dy = (y + 0.5) - cy;
            double dist = sqrt(dx * dx + dy * dy);
            double cov = rad + 0.5 - dist;
            if (cov <= 0.0) {
                row[x] = 0;
            } else {
                if (cov > 1.0) cov = 1.0;
                double border = 1.0 - fabs(dist - (rad - 0.5));
                double r = 0.08, g = 0.08, b = 0.11, a = 0.88 * cov;
                if (border > 0.0) {
                    double ba = border * 0.16 * cov;
                    r = r * (1.0 - ba) + 1.0 * ba;
                    g = g * (1.0 - ba) + 1.0 * ba;
                    b = b * (1.0 - ba) + 1.0 * ba;
                }
                uint8_t oa = (uint8_t)(a * 255.0 + 0.5);
                uint8_t or_ = (uint8_t)(r * 255.0 + 0.5);
                uint8_t og = (uint8_t)(g * 255.0 + 0.5);
                uint8_t ob = (uint8_t)(b * 255.0 + 0.5);
                row[x] = ((uint32_t)oa << 24) | ((uint32_t)or_ << 16) | ((uint32_t)og << 8) | (uint32_t)ob;
            }
        }
    }

    // 2. Render animated orb on the left side of the pill
    orb_render_bgra(&g_anim, px, w, 0, 0, kOrbSide, kPillHeight, false);

    // 3. Render live caption text using GDI onto a scratch buffer to preserve alpha
    {
        HDC txt_dc = CreateCompatibleDC(screen_dc);
        void *tbits = NULL;
        HBITMAP tbm = CreateDIBSection(txt_dc, &bmi, DIB_RGB_COLORS, &tbits, NULL, 0);
        if (tbm && tbits) {
            HBITMAP told_bm = (HBITMAP)SelectObject(txt_dc, tbm);
            HFONT told_fn = (HFONT)SelectObject(txt_dc, g_pill_font);
            memset(tbits, 0, (size_t)(w * h * 4));
            SetBkMode(txt_dc, TRANSPARENT);
            SetTextColor(txt_dc, RGB(255, 255, 255));
            RECT tr = { kOrbSide + 2, (kPillHeight - 22) / 2, kOrbSide + 2 + text_w, (kPillHeight + 22) / 2 };
            DrawTextW(txt_dc, wlabel, -1, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
            GdiFlush();

            uint32_t *tpx = (uint32_t *)tbits;
            for (int y = tr.top; y < tr.bottom; y++) {
                if (y < 0 || y >= h) continue;
                for (int x = tr.left; x < tr.right; x++) {
                    if (x < 0 || x >= w) continue;
                    uint32_t tc = tpx[y * w + x];
                    uint32_t tr_c = (tc >> 16) & 0xFF;
                    uint32_t tg_c = (tc >> 8) & 0xFF;
                    uint32_t tb_c = tc & 0xFF;
                    uint32_t lum = (tr_c + tg_c * 2 + tb_c) / 4;
                    if (lum > 0) {
                        uint32_t dst = px[y * w + x];
                        double da = ((dst >> 24) & 0xFF) / 255.0;
                        double dr = ((dst >> 16) & 0xFF) / 255.0;
                        double dg = ((dst >> 8) & 0xFF) / 255.0;
                        double db = (dst & 0xFF) / 255.0;
                        double sa = (lum / 255.0) * 0.96;
                        dr = 1.0 * sa + dr * (1.0 - sa);
                        dg = 1.0 * sa + dg * (1.0 - sa);
                        db = 1.0 * sa + db * (1.0 - sa);
                        da = sa + da * (1.0 - sa);
                        px[y * w + x] = ((uint32_t)(da * 255.0) << 24) |
                                        ((uint32_t)(dr * 255.0) << 16) |
                                        ((uint32_t)(dg * 255.0) << 8) |
                                        (uint32_t)(db * 255.0);
                    }
                }
            }
            SelectObject(txt_dc, told_fn);
            SelectObject(txt_dc, told_bm);
            DeleteObject(tbm);
        }
        DeleteDC(txt_dc);
    }

    // 4. Premultiply RGB by alpha for UpdateLayeredWindow (AC_SRC_ALPHA)
    for (int i = 0; i < w * h; i++) {
        uint32_t c = px[i];
        uint32_t al = (c >> 24) & 0xFF;
        uint32_t r = (((c >> 16) & 0xFF) * al) / 255;
        uint32_t g = (((c >> 8) & 0xFF) * al) / 255;
        uint32_t b = ((c & 0xFF) * al) / 255;
        px[i] = (al << 24) | (r << 16) | (g << 8) | b;
    }

    POINT pt_dst = { (wa.left + wa.right - w) / 2, wa.bottom - 56 - h + g_pill_y_offset };
    SIZE sz_wnd = { w, h };
    POINT pt_src = { 0, 0 };
    BLENDFUNCTION bf;
    bf.BlendOp = AC_SRC_OVER;
    bf.BlendFlags = 0;
    bf.SourceConstantAlpha = (BYTE)(g_pill_alpha * 255.0);
    bf.AlphaFormat = AC_SRC_ALPHA;

    UpdateLayeredWindow(g_hwnd_pill, screen_dc, &pt_dst, &sz_wnd, mem_dc, &pt_src, 0, &bf, ULW_ALPHA);

    SelectObject(mem_dc, old_bm);
    SelectObject(mem_dc, old_font);
    DeleteObject(hbm);
    DeleteDC(mem_dc);
    ReleaseDC(NULL, screen_dc);
    free(wlabel);
}

static void schedule_anim_timer(UINT interval_ms) {
    if (!g_hwnd_msg) return;
    if (g_timer_interval == interval_ms && interval_ms != 0) return;
    g_timer_interval = interval_ms;
    if (interval_ms == 0) {
        KillTimer(g_hwnd_msg, ID_TIMER_ANIM);
    } else {
        g_last_tick_ms = sa_now_ms();
        SetTimer(g_hwnd_msg, ID_TIMER_ANIM, interval_ms, NULL);
    }
}

static void on_anim_tick(void) {
    uint64_t now = sa_now_ms();
    double dt = g_last_tick_ms ? (double)(now - g_last_tick_ms) / 1000.0 : (1.0 / 60.0);
    g_last_tick_ms = now;

    float in = g_level_in;
    orb_tick(&g_anim, dt, g_target, in);

    if (g_target != SA_IDLE || g_notice_active) {
        g_pill_alpha += (1.0 - g_pill_alpha) * 0.25;
        if (g_pill_alpha > 0.99) g_pill_alpha = 1.0;
        if (g_pill_y_offset > 0) g_pill_y_offset = (int)(g_pill_y_offset * 0.7);
    } else if (g_pill_visible) {
        g_pill_alpha -= dt * 5.0;
        if (g_pill_alpha <= 0.02) {
            g_pill_alpha = 0.0;
            g_pill_visible = false;
            ShowWindow(g_hwnd_pill, SW_HIDE);
            schedule_anim_timer(100);
        }
    }

    if (g_pill_visible) render_pill_window();

    static unsigned frame = 0;
    if (!g_pill_visible || (++frame % 12) == 0) update_tray_icon();

    if (g_target == SA_IDLE && !g_pill_visible && g_anim.w[0] > 0.999 && g_anim.level < 0.001) {
        schedule_anim_timer(0);
    }
}

static void show_pill(void) {
    if (!g_pill_visible) {
        g_pill_visible = true;
        g_pill_alpha = 0.15;
        g_pill_y_offset = 14;
        ShowWindow(g_hwnd_pill, SW_SHOWNOACTIVATE);
    }
    render_pill_window();
    schedule_anim_timer(16);
}

static void hide_pill(void) {
    schedule_anim_timer(16);
}

void sa_set_state(int state) {
    g_target = state;
    g_notice_gen++;
    g_notice_active = false;
    if (state == SA_IDLE) {
        g_text[0] = 0;
        g_level_in = 0.0f;
        hide_pill();
    } else {
        show_pill();
    }
}

void sa_overlay_set_text(const char *text) {
    strncpy(g_text, text ? text : "", sizeof(g_text) - 1);
    g_text[sizeof(g_text) - 1] = 0;
    if (g_pill_visible) render_pill_window();
}

static void on_notice_timeout(uint32_t gen) {
    if (gen == g_notice_gen && g_target == SA_IDLE) {
        g_notice_active = false;
        g_text[0] = 0;
        hide_pill();
    }
}

void sa_overlay_notice(const char *text) {
    strncpy(g_text, text ? text : "", sizeof(g_text) - 1);
    g_text[sizeof(g_text) - 1] = 0;
    g_notice_active = true;
    uint32_t gen = ++g_notice_gen;
    show_pill();
    sa_after_ms(2500, on_notice_timeout, gen);
}

// ---- Audio Level Metering (WinMM waveIn) & Speech Recognition ---------------

static HWAVEIN g_wave_in = NULL;
static WAVEHDR g_wave_hdrs[4];
static int16_t g_wave_bufs[4][1024];
static volatile bool g_audio_running = false;
static bool g_using_sx = false;
static long g_sx_id = 0;

// Built-in Windows Speech Recognition child process (uses Windows.Media.SpeechRecognition / System.Speech)
static HANDLE g_speech_proc = NULL;
static HANDLE g_speech_stdin_wr = NULL;
static HANDLE g_speech_thread = NULL;
static volatile long g_speech_gen = 0;

typedef struct {
    char *text;
    bool is_final;
    long gen;
} SpeechMsg;

static void sx_text_cb(const char *text, bool is_final, long id) {
    if (id != g_sx_id || !g_hwnd_msg) return;
    SpeechMsg *m = (SpeechMsg *)malloc(sizeof(SpeechMsg));
    if (!m) return;
    m->text = _strdup(text ? text : "");
    m->is_final = is_final;
    m->gen = id;
    PostMessageW(g_hwnd_msg, WM_SA_TEXT, 0, (LPARAM)m);
}

static void CALLBACK wave_in_proc(HWAVEIN hwi, UINT uMsg, DWORD_PTR dwInstance, DWORD_PTR dwParam1, DWORD_PTR dwParam2) {
    (void)dwInstance; (void)dwParam2;
    if (uMsg == WIM_DATA && g_audio_running) {
        WAVEHDR *hdr = (WAVEHDR *)dwParam1;
        int count = (int)(hdr->dwBytesRecorded / sizeof(int16_t));
        const int16_t *samples = (const int16_t *)hdr->lpData;
        if (count > 0) {
            if (g_using_sx && g_sx.append) {
                g_sx.append(samples, count);
            }
            double sum = 0.0;
            for (int i = 0; i < count; i++) {
                double s = samples[i] / 32768.0;
                sum += s * s;
            }
            double rms = sqrt(sum / count);
            double db = 20.0 * log10(rms > 1e-6 ? rms : 1e-6);
            double lvl = (db + 52.0) / 38.0;
            if (lvl < 0.0) lvl = 0.0;
            if (lvl > 1.0) lvl = 1.0;
            g_level_in = (float)lvl;
        }
        if (g_audio_running) {
            waveInAddBuffer(hwi, hdr, sizeof(WAVEHDR));
        }
    }
}

typedef struct {
    HANDLE stdout_rd;
    long gen;
} SpeechReaderCtx;

static DWORD WINAPI speech_reader_thread(LPVOID param) {
    SpeechReaderCtx *ctx = (SpeechReaderCtx *)param;
    char buf[4096];
    size_t len = 0;
    DWORD avail = 0;
    while (ReadFile(ctx->stdout_rd, buf + len, 1, &avail, NULL) && avail == 1) {
        if (buf[len] == '\n') {
            if (len > 0 && buf[len - 1] == '\r') len--;
            buf[len] = 0;
            if (strncmp(buf, "PARTIAL:", 8) == 0) {
                SpeechMsg *m = (SpeechMsg *)malloc(sizeof(SpeechMsg));
                if (m) {
                    m->text = _strdup(buf + 8);
                    m->is_final = false;
                    m->gen = ctx->gen;
                    PostMessageW(g_hwnd_msg, WM_SA_TEXT, 0, (LPARAM)m);
                }
            } else if (strncmp(buf, "FINAL:", 6) == 0) {
                SpeechMsg *m = (SpeechMsg *)malloc(sizeof(SpeechMsg));
                if (m) {
                    m->text = _strdup(buf + 6);
                    m->is_final = true;
                    m->gen = ctx->gen;
                    PostMessageW(g_hwnd_msg, WM_SA_TEXT, 0, (LPARAM)m);
                }
            } else if (strncmp(buf, "ERROR:", 6) == 0) {
                report_error_async(buf + 6);
            }
            len = 0;
        } else if (len < sizeof(buf) - 2) {
            len++;
        }
    }
    CloseHandle(ctx->stdout_rd);
    free(ctx);
    return 0;
}

static bool start_builtin_windows_speech(const char *vocab) {
    SECURITY_ATTRIBUTES sa = { sizeof(SECURITY_ATTRIBUTES), NULL, TRUE };
    HANDLE out_rd = NULL, out_wr = NULL;
    HANDLE in_rd = NULL, in_wr = NULL;
    if (!CreatePipe(&out_rd, &out_wr, &sa, 0)) return false;
    SetHandleInformation(out_rd, HANDLE_FLAG_INHERIT, 0);
    if (!CreatePipe(&in_rd, &in_wr, &sa, 0)) {
        CloseHandle(out_rd); CloseHandle(out_wr);
        return false;
    }
    SetHandleInformation(in_wr, HANDLE_FLAG_INHERIT, 0);

    // Inline PowerShell speech recognizer using built-in System.Speech (SAPI) with DictationGrammar
    // and vocabulary grammar boosting. Emits PARTIAL:<text> and FINAL:<text> in UTF-8.
    wchar_t cmd[2048];
    swprintf(cmd, 2048,
        L"powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command \""
        L"[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
        L"try { "
        L"Add-Type -AssemblyName System.Speech; "
        L"$rec = New-Object System.Speech.Recognition.SpeechRecognitionEngine; "
        L"$rec.SetInputToDefaultAudioDevice(); "
        L"$rec.LoadGrammar((New-Object System.Speech.Recognition.DictationGrammar)); "
        L"$v = $env:SA_VOCAB; if ($v) { $ words = $v -split \\\"`n\\\" | Where-Object { $_ -ne '' }; if ($words.Count -gt 0) { $gb = New-Object System.Speech.Recognition.GrammarBuilder; $gb.Append((New-Object System.Speech.Recognition.Choices(,$words))); $rec.LoadGrammar((New-Object System.Speech.Recognition.Grammar($gb))); } }; "
        L"$sb = New-Object System.Text.StringBuilder; "
        L"Register-ObjectEvent -InputObject $rec -EventName SpeechHypothesized -Action { $p = ($sb.ToString() + ' ' + $EventArgs.Result.Text).Trim(); [Console]::WriteLine('PARTIAL:' + $p); [Console]::Out.Flush() } | Out-Null; "
        L"Register-ObjectEvent -InputObject $rec -EventName SpeechRecognized -Action { if ($EventArgs.Result.Text) { if ($sb.Length -gt 0) { [void]$sb.Append(' ') }; [void]$sb.Append($EventArgs.Result.Text); [Console]::WriteLine('PARTIAL:' + $sb.ToString()); [Console]::Out.Flush() } } | Out-Null; "
        L"$rec.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple); "
        L"[void][Console]::In.ReadLine(); "
        L"$rec.RecognizeAsyncCancel(); "
        L"[Console]::WriteLine('FINAL:' + $sb.ToString()); [Console]::Out.Flush() "
        L"} catch { [Console]::WriteLine('ERROR:' + $_.Exception.Message); [Console]::Out.Flush() }\"");

    if (vocab && *vocab) {
        wchar_t *wvocab = utf8_to_wide(vocab);
        if (wvocab) {
            SetEnvironmentVariableW(L"SA_VOCAB", wvocab);
            free(wvocab);
        }
    } else {
        SetEnvironmentVariableW(L"SA_VOCAB", NULL);
    }

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    memset(&si, 0, sizeof(si));
    memset(&pi, 0, sizeof(pi));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    si.hStdInput = in_rd;
    si.hStdOutput = out_wr;
    si.hStdError = out_wr;

    BOOL ok = CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    CloseHandle(in_rd);
    CloseHandle(out_wr);
    if (!ok) {
        CloseHandle(out_rd);
        CloseHandle(in_wr);
        return false;
    }
    CloseHandle(pi.hThread);
    g_speech_proc = pi.hProcess;
    g_speech_stdin_wr = in_wr;
    long gen = ++g_speech_gen;

    SpeechReaderCtx *ctx = (SpeechReaderCtx *)malloc(sizeof(SpeechReaderCtx));
    ctx->stdout_rd = out_rd;
    ctx->gen = gen;
    g_speech_thread = CreateThread(NULL, 0, speech_reader_thread, ctx, 0, NULL);
    return true;
}

bool sa_begin_listening(void) {
    WAVEFORMATEX wfx;
    memset(&wfx, 0, sizeof(wfx));
    wfx.wFormatTag = WAVE_FORMAT_PCM;
    wfx.nChannels = 1;
    wfx.nSamplesPerSec = 16000;
    wfx.wBitsPerSample = 16;
    wfx.nBlockAlign = 2;
    wfx.nAvgBytesPerSec = 32000;

    MMRESULT mm = waveInOpen(&g_wave_in, WAVE_MAPPER, &wfx, (DWORD_PTR)wave_in_proc, 0, CALLBACK_FUNCTION);
    if (mm != MMSYSERR_NOERROR) {
        report_error_async("No audio input (check Windows Microphone permission).");
        return false;
    }

    char *vocab = read_vocabulary_terms();
    bool use_sx = false;
    if (g_sx.ready && g_sx.ready() && g_sx.start) {
        g_sx_id = g_sx.start(vocab, sx_text_cb);
        use_sx = (g_sx_id != 0);
    }
    g_using_sx = use_sx;

    if (!use_sx) {
        if (!start_builtin_windows_speech(vocab)) {
            free(vocab);
            waveInClose(g_wave_in);
            g_wave_in = NULL;
            report_error_async("Speech recognizer unavailable (check Windows Speech settings).");
            return false;
        }
    }
    free(vocab);

    g_audio_running = true;
    for (int i = 0; i < 4; i++) {
        memset(&g_wave_hdrs[i], 0, sizeof(WAVEHDR));
        g_wave_hdrs[i].lpData = (LPSTR)g_wave_bufs[i];
        g_wave_hdrs[i].dwBufferLength = sizeof(g_wave_bufs[i]);
        waveInPrepareHeader(g_wave_in, &g_wave_hdrs[i], sizeof(WAVEHDR));
        waveInAddBuffer(g_wave_in, &g_wave_hdrs[i], sizeof(WAVEHDR));
    }
    waveInStart(g_wave_in);
    return true;
}

void sa_stop_listening(void) {
    if (g_audio_running && g_wave_in) {
        g_audio_running = false;
        waveInStop(g_wave_in);
        waveInReset(g_wave_in);
        for (int i = 0; i < 4; i++) {
            waveInUnprepareHeader(g_wave_in, &g_wave_hdrs[i], sizeof(WAVEHDR));
        }
        waveInClose(g_wave_in);
        g_wave_in = NULL;
    }
    g_level_in = 0.0f;

    if (g_using_sx) {
        g_using_sx = false;
        if (g_sx.finish) g_sx.finish();
    } else if (g_speech_stdin_wr) {
        DWORD wr = 0;
        WriteFile(g_speech_stdin_wr, "\n", 1, &wr, NULL);
        CloseHandle(g_speech_stdin_wr);
        g_speech_stdin_wr = NULL;
        if (g_speech_proc) {
            CloseHandle(g_speech_proc);
            g_speech_proc = NULL;
        }
        if (g_speech_thread) {
            CloseHandle(g_speech_thread);
            g_speech_thread = NULL;
        }
    }
}

// ---- Built-in Windows Copilot / Windows AI Runtime Enhancement & Rewriting --

static void (*g_enhance_done_cb)(const char *) = NULL;
static void (*g_rewrite_done_cb)(const char *) = NULL;

typedef struct {
    bool is_rewrite;
    char *text;
    char *instruction;
    char *style;
    char *vocab;
} CopilotJob;

static void dll_enhance_done(const char *res) {
    if (g_hwnd_msg) PostMessageW(g_hwnd_msg, WM_SA_ENH_DONE, 0, (LPARAM)(res ? _strdup(res) : NULL));
}

static void dll_rewrite_done(const char *res) {
    if (g_hwnd_msg) PostMessageW(g_hwnd_msg, WM_SA_RW_DONE, 0, (LPARAM)(res ? _strdup(res) : NULL));
}

static DWORD WINAPI copilot_bridge_thread(LPVOID param) {
    CopilotJob *job = (CopilotJob *)param;
    wchar_t exe_dir[MAX_PATH];
    get_exe_dir(exe_dir, MAX_PATH);

    wchar_t script_path[MAX_PATH];
    swprintf(script_path, MAX_PATH, L"%ls\\scripts\\copilot_bridge.ps1", exe_dir);
    if (GetFileAttributesW(script_path) == INVALID_FILE_ATTRIBUTES) {
        swprintf(script_path, MAX_PATH, L"%ls\\copilot_bridge.ps1", exe_dir);
    }

    char *result = NULL;
    if (GetFileAttributesW(script_path) != INVALID_FILE_ATTRIBUTES) {
        SECURITY_ATTRIBUTES sa = { sizeof(SECURITY_ATTRIBUTES), NULL, TRUE };
        HANDLE out_rd = NULL, out_wr = NULL;
        if (CreatePipe(&out_rd, &out_wr, &sa, 0)) {
            SetHandleInformation(out_rd, HANDLE_FLAG_INHERIT, 0);

            wchar_t *wtext = utf8_to_wide(job->text);
            wchar_t *winstr = utf8_to_wide(job->instruction);
            wchar_t *wstyle = utf8_to_wide(job->style);
            wchar_t *wvocab = utf8_to_wide(job->vocab);

            SetEnvironmentVariableW(L"SA_MODE", job->is_rewrite ? L"rewrite" : L"enhance");
            SetEnvironmentVariableW(L"SA_TEXT", wtext ? wtext : L"");
            SetEnvironmentVariableW(L"SA_INSTRUCTION", winstr ? winstr : L"");
            SetEnvironmentVariableW(L"SA_STYLE", wstyle ? wstyle : L"clean");
            SetEnvironmentVariableW(L"SA_VOCAB", wvocab ? wvocab : L"");

            free(wtext); free(winstr); free(wstyle); free(wvocab);

            wchar_t cmd[1024];
            swprintf(cmd, 1024, L"powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%ls\"", script_path);

            STARTUPINFOW si;
            PROCESS_INFORMATION pi;
            memset(&si, 0, sizeof(si));
            memset(&pi, 0, sizeof(pi));
            si.cb = sizeof(si);
            si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
            si.wShowWindow = SW_HIDE;
            si.hStdOutput = out_wr;
            si.hStdError = out_wr;

            if (CreateProcessW(NULL, cmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
                CloseHandle(out_wr);
                out_wr = NULL;
                char buf[16384];
                size_t total = 0;
                DWORD rd = 0;
                while (total < sizeof(buf) - 1 && ReadFile(out_rd, buf + total, (DWORD)(sizeof(buf) - 1 - total), &rd, NULL) && rd > 0) {
                    total += rd;
                }
                buf[total] = 0;
                WaitForSingleObject(pi.hProcess, 7500);
                DWORD exit_code = 1;
                GetExitCodeProcess(pi.hProcess, &exit_code);
                CloseHandle(pi.hProcess);
                CloseHandle(pi.hThread);
                while (total > 0 && (buf[total - 1] == '\r' || buf[total - 1] == '\n' || buf[total - 1] == ' ')) {
                    buf[--total] = 0;
                }
                if (exit_code == 0 && total > 0) {
                    result = _strdup(buf);
                }
            }
            if (out_wr) CloseHandle(out_wr);
            CloseHandle(out_rd);
        }
    }

    PostMessageW(g_hwnd_msg, job->is_rewrite ? WM_SA_RW_DONE : WM_SA_ENH_DONE, 0, (LPARAM)result);
    free(job->text);
    free(job->instruction);
    free(job->style);
    free(job->vocab);
    free(job);
    return 0;
}

void sa_enhance(const char *text, void (*done)(const char *)) {
    g_enhance_done_cb = done;
    char *vocab = read_vocabulary_terms();
    const char *style = kStyleKeys[g_current_style];
    if (g_sx.enhance) {
        g_sx.enhance(text, style, vocab, dll_enhance_done);
        free(vocab);
        return;
    }
    CopilotJob *job = (CopilotJob *)calloc(1, sizeof(CopilotJob));
    if (!job) { free(vocab); done(NULL); return; }
    job->is_rewrite = false;
    job->text = _strdup(text ? text : "");
    job->style = _strdup(style);
    job->vocab = vocab;
    HANDLE th = CreateThread(NULL, 0, copilot_bridge_thread, job, 0, NULL);
    if (th) CloseHandle(th);
    else { free(job->text); free(job->style); free(job->vocab); free(job); done(NULL); }
}

void sa_rewrite(const char *text, const char *instruction, void (*done)(const char *)) {
    g_rewrite_done_cb = done;
    char *vocab = read_vocabulary_terms();
    if (g_sx.rewrite) {
        g_sx.rewrite(text, instruction, vocab, dll_rewrite_done);
        free(vocab);
        return;
    }
    CopilotJob *job = (CopilotJob *)calloc(1, sizeof(CopilotJob));
    if (!job) { free(vocab); done(NULL); return; }
    job->is_rewrite = true;
    job->text = _strdup(text ? text : "");
    job->instruction = _strdup(instruction ? instruction : "");
    job->style = _strdup(kStyleKeys[g_current_style]);
    job->vocab = vocab;
    HANDLE th = CreateThread(NULL, 0, copilot_bridge_thread, job, 0, NULL);
    if (th) CloseHandle(th);
    else { free(job->text); free(job->instruction); free(job->style); free(job->vocab); free(job); done(NULL); }
}

// ---- Global Push-to-Talk Hotkeys (Ctrl+Shift+R / E / T) ---------------------

static int g_active_hotkey = 0;

static LRESULT CALLBACK low_level_kb_proc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode == HC_ACTION) {
        const KBDLLHOOKSTRUCT *kb = (const KBDLLHOOKSTRUCT *)lParam;
        bool down = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
        bool up = (wParam == WM_KEYUP || wParam == WM_SYSKEYUP);

        if (down && g_active_hotkey == 0) {
            bool ctrl = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
            bool shift = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
            bool alt = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
            if (ctrl && shift && !alt) {
                int which = 0;
                if (kb->vkCode == 'R') which = 1;
                else if (kb->vkCode == 'E') which = 2;
                else if (kb->vkCode == 'T') which = 3;
                if (which != 0) {
                    g_active_hotkey = which;
                    PostMessageW(g_hwnd_msg, WM_SA_HOTKEY, (WPARAM)which, 1);
                    return 1; // swallow hotkey so it doesn't type into focused window
                }
            }
        } else if (down && g_active_hotkey != 0) {
            if ((g_active_hotkey == 1 && kb->vkCode == 'R') ||
                (g_active_hotkey == 2 && kb->vkCode == 'E') ||
                (g_active_hotkey == 3 && kb->vkCode == 'T')) {
                return 1; // swallow key auto-repeat while held
            }
        } else if (up && g_active_hotkey != 0) {
            bool released = false;
            if (g_active_hotkey == 1 && kb->vkCode == 'R') released = true;
            else if (g_active_hotkey == 2 && kb->vkCode == 'E') released = true;
            else if (g_active_hotkey == 3 && kb->vkCode == 'T') released = true;
            else if (kb->vkCode == VK_LCONTROL || kb->vkCode == VK_RCONTROL || kb->vkCode == VK_CONTROL ||
                     kb->vkCode == VK_LSHIFT || kb->vkCode == VK_RSHIFT || kb->vkCode == VK_SHIFT) {
                released = true;
            }
            if (released) {
                int which = g_active_hotkey;
                g_active_hotkey = 0;
                PostMessageW(g_hwnd_msg, WM_SA_HOTKEY, (WPARAM)which, 0);
            }
        }
    }
    return CallNextHookEx(g_kb_hook, nCode, wParam, lParam);
}

// ---- System Tray Context Menu & Message Window ------------------------------

static void show_tray_menu(HWND hwnd) {
    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING, CMD_TOGGLE_PLAIN, L"Start / stop dictation (hold Ctrl+Shift+R)");
    AppendMenuW(menu, MF_STRING, CMD_TOGGLE_ENHANCE, L"Start / stop dictation + enhance (hold Ctrl+Shift+E)");
    AppendMenuW(menu, MF_STRING, CMD_TOGGLE_REWRITE, L"Start / stop rewrite selection (hold Ctrl+Shift+T)");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);

    HMENU style_menu = CreatePopupMenu();
    for (int i = 0; i < 5; i++) {
        UINT flags = MF_STRING | (i == g_current_style ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(style_menu, flags, CMD_STYLE_BASE + i, kStyleTitles[i]);
    }
    AppendMenuW(menu, MF_POPUP, (UINT_PTR)style_menu, L"Enhance style");
    AppendMenuW(menu, MF_STRING | (g_sounds_enabled ? MF_CHECKED : MF_UNCHECKED), CMD_SOUNDS, L"Sounds");
    AppendMenuW(menu, MF_STRING, CMD_VOCAB, L"Edit vocabulary\x2026");
    AppendMenuW(menu, MF_SEPARATOR, 0, NULL);
    AppendMenuW(menu, MF_STRING, CMD_QUIT, L"Quit");

    POINT pt;
    GetCursorPos(&pt);
    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0, hwnd, NULL);
    PostMessageW(hwnd, WM_NULL, 0, 0);
    DestroyMenu(menu);
}

static void open_vocabulary_editor(void) {
    wchar_t path[MAX_PATH];
    get_vocabulary_path(path, MAX_PATH);
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) {
        FILE *f = _wfopen(path, L"wb");
        if (f) {
            const char *hdr = "# One name or term per line (people, products, jargon) to recognise accurately.\r\n";
            fwrite(hdr, 1, strlen(hdr), f);
            fclose(f);
        }
    }
    ShellExecuteW(NULL, L"open", L"notepad.exe", path, NULL, SW_SHOWNORMAL);
}

static LRESULT CALLBACK msg_wnd_proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case WM_TIMER:
            if (wParam == ID_TIMER_ANIM) {
                on_anim_tick();
            } else {
                for (int i = 0; i < MAX_ONESHOT_TIMERS; i++) {
                    if (g_timers[i].active && g_timers[i].timer_id == wParam) {
                        KillTimer(hwnd, wParam);
                        g_timers[i].active = false;
                        g_timers[i].fn(g_timers[i].token);
                        break;
                    }
                }
            }
            return 0;

        case WM_SA_HOTKEY:
            if (g_cb.on_hotkey) g_cb.on_hotkey((int)wParam, lParam != 0);
            return 0;

        case WM_SA_TOGGLE:
            if (g_cb.on_toggle) g_cb.on_toggle((int)wParam);
            return 0;

        case WM_SA_TEXT: {
            SpeechMsg *m = (SpeechMsg *)lParam;
            if (m) {
                if (m->is_final && (!m->text || !*m->text)) {
                    if (g_cb.on_error) g_cb.on_error("No speech detected");
                } else if (g_cb.on_text) {
                    g_cb.on_text(m->text ? m->text : "", m->is_final);
                }
                free(m->text);
                free(m);
            }
            return 0;
        }

        case WM_SA_ERROR: {
            char *err = (char *)lParam;
            if (err) {
                if (g_cb.on_error) g_cb.on_error(err);
                free(err);
            }
            return 0;
        }

        case WM_SA_ENH_DONE: {
            char *res = (char *)lParam;
            if (g_enhance_done_cb) g_enhance_done_cb(res);
            free(res);
            return 0;
        }

        case WM_SA_RW_DONE: {
            char *res = (char *)lParam;
            if (g_rewrite_done_cb) g_rewrite_done_cb(res);
            free(res);
            return 0;
        }

        case WM_SA_TRAY:
            if (lParam == WM_RBUTTONUP || lParam == WM_CONTEXTMENU) {
                show_tray_menu(hwnd);
            } else if (lParam == WM_LBUTTONUP) {
                if (g_cb.on_toggle) g_cb.on_toggle(1);
            }
            return 0;

        case WM_COMMAND: {
            int id = LOWORD(wParam);
            if (id == CMD_TOGGLE_PLAIN) g_cb.on_toggle(1);
            else if (id == CMD_TOGGLE_ENHANCE) g_cb.on_toggle(2);
            else if (id == CMD_TOGGLE_REWRITE) g_cb.on_toggle(3);
            else if (id >= CMD_STYLE_BASE && id < CMD_STYLE_BASE + 5) {
                g_current_style = id - CMD_STYLE_BASE;
                save_settings();
            } else if (id == CMD_SOUNDS) {
                g_sounds_enabled = !g_sounds_enabled;
                save_settings();
            } else if (id == CMD_VOCAB) {
                open_vocabulary_editor();
            } else if (id == CMD_QUIT) {
                Shell_NotifyIconW(NIM_DELETE, &g_nid);
                PostQuitMessage(0);
            }
            return 0;
        }

        case WM_DESTROY:
            Shell_NotifyIconW(NIM_DELETE, &g_nid);
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

void sa_run(const sa_callbacks *cb) {
    g_cb = *cb;
    g_hinst = GetModuleHandleW(NULL);
    SetProcessDPIAware();
    load_settings();
    load_enhance_dll();
    if (g_sx.prepare) g_sx.prepare();
    if (g_sx.prewarm) g_sx.prewarm();

    WNDCLASSEXW wc;
    memset(&wc, 0, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = msg_wnd_proc;
    wc.hInstance = g_hinst;
    wc.lpszClassName = L"FreeVoiceTranscribeMsgWnd";
    RegisterClassExW(&wc);

    g_hwnd_msg = CreateWindowExW(0, L"FreeVoiceTranscribeMsgWnd", L"FreeVoiceTranscribe", 0,
                                 0, 0, 0, 0, NULL, NULL, g_hinst, NULL);

    WNDCLASSEXW pwc;
    memset(&pwc, 0, sizeof(pwc));
    pwc.cbSize = sizeof(pwc);
    pwc.lpfnWndProc = DefWindowProcW;
    pwc.hInstance = g_hinst;
    pwc.lpszClassName = L"FreeVoiceTranscribePillWnd";
    RegisterClassExW(&pwc);

    g_hwnd_pill = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        L"FreeVoiceTranscribePillWnd", L"", WS_POPUP,
        0, 0, 200, kPillHeight, NULL, NULL, g_hinst, NULL);

    orb_init(&g_anim);
    g_tray_icon = create_orb_icon(&g_anim, 18);

    memset(&g_nid, 0, sizeof(g_nid));
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = g_hwnd_msg;
    g_nid.uID = 1;
    g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    g_nid.uCallbackMessage = WM_SA_TRAY;
    g_nid.hIcon = g_tray_icon;
    wcscpy_s(g_nid.szTip, sizeof(g_nid.szTip) / sizeof(wchar_t), L"FreeVoiceTranscribe (Ctrl+Shift+R)");
    Shell_NotifyIconW(NIM_ADD, &g_nid);

    schedule_anim_timer(100);

    g_kb_hook = SetWindowsHookExW(WH_KEYBOARD_LL, low_level_kb_proc, g_hinst, 0);
    if (!g_kb_hook) {
        report_error_async("Could not install keyboard hook for Ctrl+Shift+R/E/T.");
    }

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (g_kb_hook) UnhookWindowsHookEx(g_kb_hook);
}
