//! Voice dictation: hold Cmd+Shift+R (macOS) / Ctrl+Shift+R (Windows) and speak; on release the
//! transcript is pasted into whatever text field currently has focus. Cmd/Ctrl+Shift+E enhances it
//! first; Cmd/Ctrl+Shift+T rewrites the selected text following your spoken instruction.
const std = @import("std");
const builtin = @import("builtin");

const Callbacks = extern struct {
    on_hotkey: *const fn (c_int, bool) callconv(.c) void,
    on_toggle: *const fn (c_int) callconv(.c) void,
    on_text: *const fn ([*:0]const u8, bool) callconv(.c) void,
    on_error: *const fn ([*:0]const u8) callconv(.c) void,
};

extern fn sa_run(cb: *const Callbacks) void;
extern fn sa_begin_listening() bool;
extern fn sa_stop_listening() void;
extern fn sa_set_state(state: c_int) void;
extern fn sa_overlay_set_text(text: [*:0]const u8) void;
extern fn sa_overlay_notice(text: [*:0]const u8) void;
extern fn sa_enhance(text: [*:0]const u8, done: *const fn (?[*:0]const u8) callconv(.c) void) void;
extern fn sa_rewrite(text: [*:0]const u8, instruction: [*:0]const u8, done: *const fn (?[*:0]const u8) callconv(.c) void) void;
extern fn sa_pasteboard_stash() void;
extern fn sa_pasteboard_change_count() c_long;
extern fn sa_pasteboard_read(buf: [*]u8, cap: usize) usize;
extern fn sa_play(kind: c_int) void;
extern fn sa_now_ms() u64;
extern fn sa_after_ms(ms: u32, f: *const fn (u32) callconv(.c) void, token: u32) void;
extern fn sa_pasteboard_stash_and_set(text: [*:0]const u8) void;
extern fn sa_pasteboard_set(text: [*:0]const u8) void;
extern fn sa_pasteboard_restore() void;
extern fn sa_accessibility_trusted(prompt: bool) bool;
extern fn sa_modifiers_held() bool;
extern fn sa_send_copy() void;
extern fn sa_send_paste() void;

/// Give up waiting for the hotkey's modifiers to be released after this many 40 ms polls.
const max_modifier_waits = 25;

/// How long to wait for the recognizer's final result after audio ends.
const final_timeout_ms = 2500;
/// Give the target app time to read the pasteboard before restoring it.
const restore_delay_ms = 400;

/// Stop on our own if no new words arrive for this long, so the pill can never get stuck.
const quiet_timeout_ms = 6000;

/// How long to wait for the on-device model before pasting the raw transcript.
const enhance_timeout_ms = 8000;

/// How long to wait for the app to put the selection on the clipboard after Cmd/Ctrl+C.
const copy_wait_ms = 180;
/// How long to wait for the on-device model to rewrite the selection.
const rewrite_timeout_ms = 12000;
/// Longer selections than this overflow the small on-device model.
const max_selection_bytes = 6000;

const State = enum { idle, listening, finishing, enhancing, rewriting };
/// What the current dictation is for; matches the hotkey ids.
const Mode = enum(c_int) { plain = 1, enhance = 2, rewrite = 3 };

var state: State = .idle;
var epoch: u32 = 0;
var text_buf: [16384]u8 = undefined;
var text_len: usize = 0;
var activity: u32 = 0;
var press_started: bool = false;
var mode: Mode = .plain;
var instr_buf: [4096]u8 = undefined;
var instr_len: usize = 0;
var sel_buf: [max_selection_bytes + 1]u8 = undefined;
var change_count0: c_long = 0;

const idle: c_int = 0;
const listening: c_int = 1;
const transcribing: c_int = 2;

fn onError(msg: [*:0]const u8) callconv(.c) void {
    std.debug.print("error: {s}\n", .{msg});
    if (state != .idle) {
        sa_stop_listening();
        state = .idle;
        epoch +%= 1;
    }
    sa_overlay_notice(msg);
    sa_play(2);
}

fn startListening(from_key: bool, new_mode: Mode) void {
    text_len = 0;
    mode = new_mode;
    epoch +%= 1;
    // On failure sa_begin_listening reports through onError, which shows the notice.
    if (sa_begin_listening()) {
        state = .listening;
        press_started = from_key;
        sa_overlay_set_text(if (new_mode == .rewrite) "Say how to change the selected text…" else "");
        sa_set_state(listening);
        sa_play(0);
        bumpActivity();
    }
}

fn stopListening() void {
    sa_stop_listening();
    state = .finishing;
    sa_set_state(transcribing);
    sa_after_ms(final_timeout_ms, onFinalTimeout, epoch);
}

fn bumpActivity() void {
    activity +%= 1;
    sa_after_ms(quiet_timeout_ms, onQuiet, activity);
}

fn onQuiet(token: u32) callconv(.c) void {
    if (token == activity and state == .listening) {
        std.debug.print("no speech for {d} ms, stopping\n", .{quiet_timeout_ms});
        stopListening();
    }
}

fn onHotkey(which: c_int, pressed: bool) callconv(.c) void {
    std.debug.print("hotkey {d} {s} in state {s}\n", .{ which, if (pressed) "down" else "up", @tagName(state) });
    if (pressed) {
        if (state == .idle) startListening(true, @enumFromInt(which));
    } else if (press_started and state == .listening) {
        stopListening();
    }
}

/// Menu item / test signals: start or stop without holding the key.
fn onToggle(which: c_int) callconv(.c) void {
    switch (state) {
        .idle => startListening(false, @enumFromInt(which)),
        .listening => stopListening(),
        .finishing, .enhancing, .rewriting => {},
    }
}

fn onText(text: [*:0]const u8, is_final: bool) callconv(.c) void {
    if (state == .idle or state == .enhancing or state == .rewriting) return;
    const s = std.mem.span(text);
    text_len = @min(s.len, text_buf.len - 1);
    @memcpy(text_buf[0..text_len], s[0..text_len]);
    text_buf[text_len] = 0;
    sa_overlay_set_text(@ptrCast(&text_buf));
    if (state == .listening) bumpActivity();
    if (is_final) {
        // The recognizer can end on its own (e.g. its duration limit) while listening.
        if (state == .listening) sa_stop_listening();
        finish();
    }
}

fn onFinalTimeout(token: u32) callconv(.c) void {
    if (token == epoch and state == .finishing) finish();
}

/// The transcript is complete: enhance it first if this dictation asked for that.
fn finish() void {
    if (text_len == 0) return deliver();
    switch (mode) {
        .plain => return deliver(),
        .enhance => {},
        .rewrite => return beginRewrite(),
    }
    state = .enhancing;
    epoch +%= 1;
    sa_overlay_set_text("Enhancing…");
    text_buf[text_len] = 0;
    sa_after_ms(enhance_timeout_ms, onEnhanceTimeout, epoch);
    sa_enhance(@ptrCast(&text_buf), onEnhanced);
}

/// The transcript is the spoken instruction: grab the selection (Cmd/Ctrl+C), have the model apply
/// the instruction to it, then paste the result over the still-selected text.
fn beginRewrite() void {
    state = .rewriting;
    epoch +%= 1;
    instr_len = text_len;
    @memcpy(instr_buf[0..instr_len], text_buf[0..instr_len]);
    instr_buf[instr_len] = 0;
    sa_overlay_set_text("Rewriting…");
    if (!sa_accessibility_trusted(false)) return abortRewrite("Turn on Accessibility for FreeVoiceTranscribe to rewrite text");
    sa_pasteboard_stash();
    sa_after_ms(rewrite_timeout_ms, onRewriteTimeout, epoch);
    copySelection(0);
}

fn copySelection(waits: u32) callconv(.c) void {
    if (state != .rewriting) return;
    if (sa_modifiers_held() and waits < max_modifier_waits) {
        sa_after_ms(40, copySelection, waits + 1);
        return;
    }
    change_count0 = sa_pasteboard_change_count();
    sa_send_copy();
    sa_after_ms(copy_wait_ms, onCopied, epoch);
}

fn onCopied(token: u32) callconv(.c) void {
    if (token != epoch or state != .rewriting) return;
    const n = sa_pasteboard_read(&sel_buf, sel_buf.len);
    if (sa_pasteboard_change_count() == change_count0 or n == 0) {
        // Nothing was selected, so treat what was said as ordinary dictation.
        std.debug.print("no selection, dictating the instruction\n", .{});
        sa_pasteboard_restore();
        return deliver();
    }
    if (n >= max_selection_bytes) return abortRewrite("Selection is too long to rewrite");
    std.debug.print("rewriting {d} bytes: \"{s}\"\n", .{ n, instr_buf[0..instr_len] });
    sa_rewrite(@ptrCast(&sel_buf), @ptrCast(&instr_buf), onRewritten);
}

fn onRewritten(result: ?[*:0]const u8) callconv(.c) void {
    if (state != .rewriting) return;
    const r = result orelse return abortRewrite("Couldn't rewrite, text left unchanged");
    const s = std.mem.span(r);
    text_len = @min(s.len, text_buf.len - 1);
    @memcpy(text_buf[0..text_len], s[0..text_len]);
    std.debug.print("rewritten -> {s}\n", .{s});
    deliver(); // pastes over the selection and restores the original clipboard
}

fn onRewriteTimeout(token: u32) callconv(.c) void {
    if (token == epoch and state == .rewriting) abortRewrite("Rewrite took too long, text left unchanged");
}

fn abortRewrite(msg: [*:0]const u8) void {
    std.debug.print("rewrite aborted: {s}\n", .{msg});
    state = .idle;
    epoch +%= 1;
    sa_pasteboard_restore();
    sa_set_state(idle);
    sa_overlay_notice(msg);
    sa_play(2);
}

fn onEnhanced(result: ?[*:0]const u8) callconv(.c) void {
    if (state != .enhancing) return;
    if (result) |r| {
        const s = std.mem.span(r);
        text_len = @min(s.len, text_buf.len - 1);
        @memcpy(text_buf[0..text_len], s[0..text_len]);
        std.debug.print("enhanced -> {s}\n", .{s});
    } else {
        std.debug.print("enhance unavailable, pasting the raw transcript\n", .{});
    }
    deliver();
}

fn onEnhanceTimeout(token: u32) callconv(.c) void {
    if (token == epoch and state == .enhancing) {
        std.debug.print("enhance timed out, pasting the raw transcript\n", .{});
        deliver();
    }
}

fn deliver() void {
    std.debug.print("deliver len={d} trusted={}\n", .{ text_len, sa_accessibility_trusted(false) });
    state = .idle;
    epoch +%= 1;
    sa_set_state(idle);
    if (text_len == 0) return;
    text_buf[text_len] = 0;
    std.debug.print("pasting: {s}\n", .{text_buf[0..text_len]});
    if (!sa_accessibility_trusted(false)) {
        // Can't send Cmd+V without Accessibility access; leave the text on the clipboard instead.
        std.debug.print("Accessibility not granted: transcript copied to clipboard, paste it manually.\n", .{});
        sa_pasteboard_set(@ptrCast(&text_buf));
        sa_overlay_notice("Turn on Accessibility for FreeVoiceTranscribe to auto-paste");
        return;
    }
    sa_play(1);
    sa_pasteboard_stash_and_set(@ptrCast(&text_buf));
    tryPaste(0);
}

/// Cmd/Ctrl+V sent while the user still holds the hotkey modifiers would arrive with extra modifiers,
/// so wait until the physical modifiers are up.
fn tryPaste(waits: u32) callconv(.c) void {
    if (sa_modifiers_held() and waits < max_modifier_waits) {
        sa_after_ms(40, tryPaste, waits + 1);
        return;
    }
    sa_send_paste();
    sa_after_ms(restore_delay_ms, onRestore, 0);
}

fn onRestore(_: u32) callconv(.c) void {
    sa_pasteboard_restore();
}

pub fn main() void {
    if (!sa_accessibility_trusted(true)) {
        std.debug.print("Grant Accessibility access so the transcript can be pasted (System Settings > Privacy & Security).\n", .{});
    }
    const mod_str = if (builtin.os.tag == .windows) "Ctrl+Shift" else "Cmd+Shift";
    std.debug.print("Ready. hold {s}+R to dictate, {s}+E to dictate + enhance; release to paste.\n", .{ mod_str, mod_str });
    const cb: Callbacks = .{ .on_hotkey = onHotkey, .on_toggle = onToggle, .on_text = onText, .on_error = onError };
    sa_run(&cb);
}
