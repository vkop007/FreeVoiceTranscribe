#ifndef SHIM_H
#define SHIM_H
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    void (*on_hotkey)(int which, bool pressed); // push-to-talk key down / up; which: 1 = plain, 2 = enhance, 3 = rewrite selection
    void (*on_toggle)(int mode);                // menu items and test signals: start or stop without the key (1/2/3 as above)
    void (*on_text)(const char *text, bool is_final);
    void (*on_error)(const char *message);
} sa_callbacks;

enum { SA_IDLE = 0, SA_LISTENING = 1, SA_TRANSCRIBING = 2 };

// Sets up the menu bar item, hotkey and permissions, then runs the app loop. Never returns.
void sa_run(const sa_callbacks *cb);
bool sa_begin_listening(void);
void sa_stop_listening(void);
// Drives the animated orb (menu bar icon + floating pill). Idle hides the pill.
void sa_set_state(int state);
// Live caption shown in the pill; empty string shows the state's default label.
void sa_overlay_set_text(const char *text);
// Shows a short message in the pill for a couple of seconds.
void sa_overlay_notice(const char *text);
// Rewrites `text` with the on-device model. `done` runs on the main queue with the result, or NULL on failure.
void sa_enhance(const char *text, void (*done)(const char *result));
// Short system sound plus a trackpad tick: 0 = start, 1 = done, 2 = error. Respects the menu's Sounds setting.
void sa_play(int kind);
// Monotonic milliseconds.
uint64_t sa_now_ms(void);
void sa_after_ms(uint32_t ms, void (*fn)(uint32_t), uint32_t token);
// Applies the spoken `instruction` to `text` with the on-device model. `done` runs on the main queue, NULL on failure.
void sa_rewrite(const char *text, const char *instruction, void (*done)(const char *result));
// Saves the clipboard (unless already saved) so sa_pasteboard_restore can bring it back.
void sa_pasteboard_stash(void);
long sa_pasteboard_change_count(void);
// Copies the clipboard's text into buf (NUL-terminated); returns its length, 0 if none.
size_t sa_pasteboard_read(char *buf, size_t cap);
// Replaces the clipboard with `text`, keeping nothing.
void sa_pasteboard_set(const char *text);
// Saves the current clipboard, then puts `text` on it.
void sa_pasteboard_stash_and_set(const char *text);
void sa_pasteboard_restore(void);
// Prompts for Accessibility access (needed to send Cmd+V) if not yet granted.
bool sa_accessibility_trusted(bool prompt);
#endif
