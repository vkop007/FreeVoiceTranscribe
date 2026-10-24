// Portable C11 implementation of the FreeVoiceTranscribe core state machine (mirrors src/main.zig).
// Used when building with a standard C compiler (clang / gcc / MSVC cl.exe) without Zig installed.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "shim.h"

#define MAX_MODIFIER_WAITS 25
#define FINAL_TIMEOUT_MS   2500
#define RESTORE_DELAY_MS   400
#define QUIET_TIMEOUT_MS   6000
#define ENHANCE_TIMEOUT_MS 8000
#define COPY_WAIT_MS       180
#define REWRITE_TIMEOUT_MS 12000
#define MAX_SELECTION_BYTES 6000

typedef enum {
    STATE_IDLE = 0,
    STATE_LISTENING,
    STATE_FINISHING,
    STATE_ENHANCING,
    STATE_REWRITING,
} AppState;

typedef enum {
    MODE_PLAIN = 1,
    MODE_ENHANCE = 2,
    MODE_REWRITE = 3,
} DictationMode;

static AppState g_state = STATE_IDLE;
static uint32_t g_epoch = 0;
static char g_text_buf[16384];
static size_t g_text_len = 0;
static uint32_t g_activity = 0;
static bool g_press_started = false;
static DictationMode g_mode = MODE_PLAIN;
static char g_instr_buf[4096];
static size_t g_instr_len = 0;
static char g_sel_buf[MAX_SELECTION_BYTES + 1];
static long g_change_count0 = 0;

static void stop_listening(void);
static void finish(void);
static void deliver(void);
static void begin_rewrite(void);
static void copy_selection(uint32_t waits);
static void on_copied(uint32_t token);
static void on_rewritten(const char *result);
static void on_rewrite_timeout(uint32_t token);
static void abort_rewrite(const char *msg);
static void on_enhanced(const char *result);
static void on_enhance_timeout(uint32_t token);
static void try_paste(uint32_t waits);
static void on_restore(uint32_t token);
static void on_quiet(uint32_t token);
static void on_final_timeout(uint32_t token);

static const char *state_name(AppState s) {
    switch (s) {
        case STATE_IDLE: return "idle";
        case STATE_LISTENING: return "listening";
        case STATE_FINISHING: return "finishing";
        case STATE_ENHANCING: return "enhancing";
        case STATE_REWRITING: return "rewriting";
        default: return "unknown";
    }
}

static void bump_activity(void) {
    g_activity++;
    sa_after_ms(QUIET_TIMEOUT_MS, on_quiet, g_activity);
}

static void on_quiet(uint32_t token) {
    if (token == g_activity && g_state == STATE_LISTENING) {
        fprintf(stderr, "no speech for %d ms, stopping\n", QUIET_TIMEOUT_MS);
        stop_listening();
    }
}

static void on_error(const char *msg) {
    fprintf(stderr, "error: %s\n", msg);
    if (g_state != STATE_IDLE) {
        sa_stop_listening();
        g_state = STATE_IDLE;
        g_epoch++;
    }
    sa_overlay_notice(msg);
    sa_play(2);
}

static void start_listening(bool from_key, DictationMode new_mode) {
    g_text_len = 0;
    g_mode = new_mode;
    g_epoch++;
    if (sa_begin_listening()) {
        g_state = STATE_LISTENING;
        g_press_started = from_key;
        sa_overlay_set_text(new_mode == MODE_REWRITE ? "Say how to change the selected text\xE2\x80\xA6" : "");
        sa_set_state(SA_LISTENING);
        sa_play(0);
        bump_activity();
    }
}

static void stop_listening(void) {
    sa_stop_listening();
    g_state = STATE_FINISHING;
    sa_set_state(SA_TRANSCRIBING);
    sa_after_ms(FINAL_TIMEOUT_MS, on_final_timeout, g_epoch);
}

static void on_hotkey(int which, bool pressed) {
    fprintf(stderr, "hotkey %d %s in state %s\n", which, pressed ? "down" : "up", state_name(g_state));
    if (pressed) {
        if (g_state == STATE_IDLE) start_listening(true, (DictationMode)which);
    } else if (g_press_started && g_state == STATE_LISTENING) {
        stop_listening();
    }
}

static void on_toggle(int which) {
    switch (g_state) {
        case STATE_IDLE:
            start_listening(false, (DictationMode)which);
            break;
        case STATE_LISTENING:
            stop_listening();
            break;
        case STATE_FINISHING:
        case STATE_ENHANCING:
        case STATE_REWRITING:
            break;
    }
}

static void on_text(const char *text, bool is_final) {
    if (g_state == STATE_IDLE || g_state == STATE_ENHANCING || g_state == STATE_REWRITING) return;
    size_t slen = strlen(text);
    g_text_len = slen < (sizeof(g_text_buf) - 1) ? slen : (sizeof(g_text_buf) - 1);
    memcpy(g_text_buf, text, g_text_len);
    g_text_buf[g_text_len] = 0;
    sa_overlay_set_text(g_text_buf);
    if (g_state == STATE_LISTENING) bump_activity();
    if (is_final) {
        if (g_state == STATE_LISTENING) sa_stop_listening();
        finish();
    }
}

static void on_final_timeout(uint32_t token) {
    if (token == g_epoch && g_state == STATE_FINISHING) finish();
}

static void finish(void) {
    if (g_text_len == 0) {
        deliver();
        return;
    }
    if (g_mode == MODE_PLAIN) {
        deliver();
        return;
    }
    if (g_mode == MODE_REWRITE) {
        begin_rewrite();
        return;
    }
    g_state = STATE_ENHANCING;
    g_epoch++;
    sa_overlay_set_text("Enhancing\xE2\x80\xA6");
    g_text_buf[g_text_len] = 0;
    sa_after_ms(ENHANCE_TIMEOUT_MS, on_enhance_timeout, g_epoch);
    sa_enhance(g_text_buf, on_enhanced);
}

static void begin_rewrite(void) {
    g_state = STATE_REWRITING;
    g_epoch++;
    g_instr_len = g_text_len < (sizeof(g_instr_buf) - 1) ? g_text_len : (sizeof(g_instr_buf) - 1);
    memcpy(g_instr_buf, g_text_buf, g_instr_len);
    g_instr_buf[g_instr_len] = 0;
    sa_overlay_set_text("Rewriting\xE2\x80\xA6");
    if (!sa_accessibility_trusted(false)) {
        abort_rewrite("Turn on Accessibility for FreeVoiceTranscribe to rewrite text");
        return;
    }
    sa_pasteboard_stash();
    sa_after_ms(REWRITE_TIMEOUT_MS, on_rewrite_timeout, g_epoch);
    copy_selection(0);
}

static void copy_selection(uint32_t waits) {
    if (g_state != STATE_REWRITING) return;
    if (sa_modifiers_held() && waits < MAX_MODIFIER_WAITS) {
        sa_after_ms(40, copy_selection, waits + 1);
        return;
    }
    g_change_count0 = sa_pasteboard_change_count();
    sa_send_copy();
    sa_after_ms(COPY_WAIT_MS, on_copied, g_epoch);
}

static void on_copied(uint32_t token) {
    if (token != g_epoch || g_state != STATE_REWRITING) return;
    size_t n = sa_pasteboard_read(g_sel_buf, sizeof(g_sel_buf));
    if (sa_pasteboard_change_count() == g_change_count0 || n == 0) {
        fprintf(stderr, "no selection, dictating the instruction\n");
        sa_pasteboard_restore();
        deliver();
        return;
    }
    if (n >= MAX_SELECTION_BYTES) {
        abort_rewrite("Selection is too long to rewrite");
        return;
    }
    fprintf(stderr, "rewriting %zu bytes: \"%.*s\"\n", n, (int)g_instr_len, g_instr_buf);
    sa_rewrite(g_sel_buf, g_instr_buf, on_rewritten);
}

static void on_rewritten(const char *result) {
    if (g_state != STATE_REWRITING) return;
    if (!result) {
        abort_rewrite("Couldn't rewrite, text left unchanged");
        return;
    }
    size_t slen = strlen(result);
    g_text_len = slen < (sizeof(g_text_buf) - 1) ? slen : (sizeof(g_text_buf) - 1);
    memcpy(g_text_buf, result, g_text_len);
    fprintf(stderr, "rewritten -> %s\n", result);
    deliver();
}

static void on_rewrite_timeout(uint32_t token) {
    if (token == g_epoch && g_state == STATE_REWRITING) {
        abort_rewrite("Rewrite took too long, text left unchanged");
    }
}

static void abort_rewrite(const char *msg) {
    fprintf(stderr, "rewrite aborted: %s\n", msg);
    g_state = STATE_IDLE;
    g_epoch++;
    sa_pasteboard_restore();
    sa_set_state(SA_IDLE);
    sa_overlay_notice(msg);
    sa_play(2);
}

static void on_enhanced(const char *result) {
    if (g_state != STATE_ENHANCING) return;
    if (result) {
        size_t slen = strlen(result);
        g_text_len = slen < (sizeof(g_text_buf) - 1) ? slen : (sizeof(g_text_buf) - 1);
        memcpy(g_text_buf, result, g_text_len);
        fprintf(stderr, "enhanced -> %s\n", result);
    } else {
        fprintf(stderr, "enhance unavailable, pasting the raw transcript\n");
    }
    deliver();
}

static void on_enhance_timeout(uint32_t token) {
    if (token == g_epoch && g_state == STATE_ENHANCING) {
        fprintf(stderr, "enhance timed out, pasting the raw transcript\n");
        deliver();
    }
}

static void deliver(void) {
    fprintf(stderr, "deliver len=%zu trusted=%d\n", g_text_len, sa_accessibility_trusted(false));
    g_state = STATE_IDLE;
    g_epoch++;
    sa_set_state(SA_IDLE);
    if (g_text_len == 0) return;
    g_text_buf[g_text_len] = 0;
    fprintf(stderr, "pasting: %s\n", g_text_buf);
    if (!sa_accessibility_trusted(false)) {
        fprintf(stderr, "Accessibility not granted: transcript copied to clipboard, paste it manually.\n");
        sa_pasteboard_set(g_text_buf);
        sa_overlay_notice("Turn on Accessibility for FreeVoiceTranscribe to auto-paste");
        return;
    }
    sa_play(1);
    sa_pasteboard_stash_and_set(g_text_buf);
    try_paste(0);
}

static void try_paste(uint32_t waits) {
    if (sa_modifiers_held() && waits < MAX_MODIFIER_WAITS) {
        sa_after_ms(40, try_paste, waits + 1);
        return;
    }
    sa_send_paste();
    sa_after_ms(RESTORE_DELAY_MS, on_restore, 0);
}

static void on_restore(uint32_t token) {
    (void)token;
    sa_pasteboard_restore();
}

int main(void) {
    if (!sa_accessibility_trusted(true)) {
        fprintf(stderr, "Grant Accessibility access so the transcript can be pasted (System Settings > Privacy & Security).\n");
    }
#ifdef _WIN32
    fprintf(stderr, "Ready. hold Ctrl+Shift+R to dictate, Ctrl+Shift+E to dictate + enhance; release to paste.\n");
#else
    fprintf(stderr, "Ready. hold Cmd+Shift+R to dictate, Cmd+Shift+E to dictate + enhance; release to paste.\n");
#endif
    sa_callbacks cb = {
        .on_hotkey = on_hotkey,
        .on_toggle = on_toggle,
        .on_text = on_text,
        .on_error = on_error,
    };
    sa_run(&cb);
    return 0;
}

#ifdef _WIN32
#include <windows.h>
int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow) {
    (void)hInstance;
    (void)hPrevInstance;
    (void)lpCmdLine;
    (void)nCmdShow;
    return main();
}
#endif

