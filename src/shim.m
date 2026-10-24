// Thin Objective-C layer over the Apple frameworks Zig can't call comfortably.
// All logic lives in main.zig; this file only exposes Speech, AVAudioEngine,
// NSPasteboard, the global hotkey and the menu bar item as plain C functions.
#import <Cocoa/Cocoa.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include "shim.h"
#import "orb.h"
#import "orbview.h"
#import <QuartzCore/QuartzCore.h>

static sa_callbacks g_cb;
static NSStatusItem *g_status;
static AVAudioEngine *g_engine;
static SFSpeechRecognizer *g_recognizer;
static SFSpeechAudioBufferRecognitionRequest *g_request;
static SFSpeechRecognitionTask *g_task;
static NSUInteger g_generation;
static NSArray<NSPasteboardItem *> *g_saved_items;

static void report_error(NSString *msg) {
    if (g_cb.on_error) g_cb.on_error(msg.UTF8String);
}

static NSString *vocabulary_path(void);
static NSArray<NSString *> *enhance_styles(void);
static NSString *g_style_key;

@interface SAMenuTarget : NSObject
- (void)toggle:(id)sender;
- (void)quit:(id)sender;
@end
@implementation SAMenuTarget
- (void)toggle:(id)sender { g_cb.on_toggle(1); }
- (void)toggleEnhance:(id)sender { g_cb.on_toggle(2); }
- (void)toggleRewrite:(id)sender { g_cb.on_toggle(3); }
- (void)editVocabulary:(id)sender {
    NSString *path = vocabulary_path();
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [@"# One name or term per line (people, products, jargon) to recognise accurately.\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    [NSWorkspace.sharedWorkspace openFile:path withApplication:@"TextEdit"];
}
- (void)selectStyle:(NSMenuItem *)sender {
    [NSUserDefaults.standardUserDefaults setObject:enhance_styles()[sender.tag] forKey:g_style_key];
    for (NSMenuItem *item in sender.menu.itemArray) item.state = item == sender ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)toggleSounds:(NSMenuItem *)sender {
    BOOL on = sender.state != NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"sounds"];
    sender.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end
static SAMenuTarget *g_menu_target;

static OSStatus hotkey_handler(EventHandlerCallRef next, EventRef event, void *ctx) {
    EventHotKeyID id;
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof id, NULL, &id);
    g_cb.on_hotkey((int)id.id, GetEventKind(event) == kEventHotKeyPressed);
    return noErr;
}

// Swift-only features (SpeechAnalyzer, FoundationModels) live in libenhance.dylib, loaded at runtime.
static struct {
    void (*enhance)(const char *, const char *, const char *, void (*)(const char *));
    void (*prewarm)(void);
    void (*rewrite)(const char *, const char *, const char *, void (*)(const char *));
    void (*prepare)(void);
    bool (*ready)(void);
    long (*start)(const char *, void (*)(const char *, bool, long));
    void (*append)(const void *);
    void (*finish)(void);
} g_sx;

static void load_swift(void) {
    NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/libenhance.dylib"];
    void *h = dlopen(path.UTF8String, RTLD_NOW);
    if (!h) {
        NSLog(@"swift library: %s", dlerror());
        return;
    }
    g_sx.enhance = dlsym(h, "sa_enhance_async");
    g_sx.prewarm = dlsym(h, "sa_enhance_prewarm");
    g_sx.rewrite = dlsym(h, "sa_rewrite_async");
    g_sx.prepare = dlsym(h, "sa_sx_prepare");
    g_sx.ready = dlsym(h, "sa_sx_ready");
    g_sx.start = dlsym(h, "sa_sx_start");
    g_sx.append = dlsym(h, "sa_sx_append");
    g_sx.finish = dlsym(h, "sa_sx_finish");
}

static NSArray<NSString *> *vocabulary_terms(void);

static NSArray<NSString *> *enhance_styles(void) { return @[ @"clean", @"formal", @"concise", @"prompt", @"notes" ]; }
static NSString *g_style_key = @"enhanceStyle";

void sa_rewrite(const char *text, const char *instruction, void (*done)(const char *)) {
    if (!g_sx.rewrite) return done(NULL);
    NSString *vocab = [vocabulary_terms() componentsJoinedByString:@"\n"];
    g_sx.rewrite(text, instruction, vocab.UTF8String, done);
}

void sa_enhance(const char *text, void (*done)(const char *)) {
    if (!g_sx.enhance) return done(NULL);
    NSString *style = [NSUserDefaults.standardUserDefaults stringForKey:g_style_key] ?: @"clean";
    NSString *vocab = [vocabulary_terms() componentsJoinedByString:@"\n"];
    g_sx.enhance(text, style.UTF8String, vocab.UTF8String, done);
}

void sa_play(int kind) {
    if ([NSUserDefaults.standardUserDefaults objectForKey:@"sounds"] && ![NSUserDefaults.standardUserDefaults boolForKey:@"sounds"]) return;
    static NSString *names[3] = {@"Tink", @"Pop", @"Basso"};
    NSSound *snd = [NSSound soundNamed:names[kind]];
    snd.volume = 0.5;
    [snd play];
    [NSHapticFeedbackManager.defaultPerformer performFeedbackPattern:NSHapticFeedbackPatternAlignment
                                                    performanceTime:NSHapticFeedbackPerformanceTimeNow];
}

uint64_t sa_now_ms(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC) / NSEC_PER_MSEC;
}


// ---- Animated orb: menu bar icon + floating pill ----------------------------

static const CGFloat kPillHeight = 56;
static const CGFloat kOrbSide = 56;

static OrbAnim g_anim;
static volatile float g_level_in; // written on the audio thread
static int g_target = SA_IDLE;
static NSTimer *g_timer;
static CFTimeInterval g_last_tick;
static NSPanel *g_panel;
static NSTextField *g_label;
static NSString *g_text = @"";
static NSUInteger g_notice_gen;
static BOOL g_notice_active;

static OrbLayerView *g_orb_view;

static NSScreen *screen_with_mouse(void) {
    NSPoint m = NSEvent.mouseLocation;
    for (NSScreen *s in NSScreen.screens)
        if (NSPointInRect(m, s.frame)) return s;
    return NSScreen.mainScreen;
}

static void layout_pill(BOOL animate) {
    NSScreen *screen = screen_with_mouse();
    NSString *label = g_text.length ? g_text
        : (g_notice_active ? @"" : (g_target == SA_TRANSCRIBING ? @"Transcribing…" : @"Listening…"));
    g_label.stringValue = label;
    CGFloat maxText = MIN(520, screen.visibleFrame.size.width * 0.55);
    CGFloat textW = ceil([label sizeWithAttributes:@{NSFontAttributeName : g_label.font}].width);
    textW = MAX(96, MIN(maxText, textW + 10)); // label cell adds its own padding
    CGFloat w = kOrbSide + 2 + textW + 26;
    NSRect vf = screen.visibleFrame;
    NSRect f = NSMakeRect(NSMidX(vf) - w / 2, NSMinY(vf) + 56, w, kPillHeight);
    g_label.frame = NSMakeRect(kOrbSide + 2, (kPillHeight - 20) / 2, textW, 20);
    if (animate && g_panel.isVisible) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.14;
            [g_panel.animator setFrame:f display:YES];
        }];
    } else {
        [g_panel setFrame:f display:YES];
    }
}

static void build_pill(void) {
    NSRect r = NSMakeRect(0, 0, 200, kPillHeight);
    g_panel = [[NSPanel alloc] initWithContentRect:r
                                         styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    g_panel.opaque = NO;
    g_panel.backgroundColor = NSColor.clearColor;
    g_panel.level = NSStatusWindowLevel;
    g_panel.hasShadow = YES;
    g_panel.ignoresMouseEvents = YES;
    g_panel.hidesOnDeactivate = NO;
    g_panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSVisualEffectView *fx = [[NSVisualEffectView alloc] initWithFrame:r];
    fx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    fx.material = NSVisualEffectMaterialHUDWindow;
    fx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    fx.state = NSVisualEffectStateActive;
    fx.wantsLayer = YES;
    fx.layer.cornerRadius = kPillHeight / 2;
    fx.layer.masksToBounds = YES;
    fx.layer.borderWidth = 0.5;
    fx.layer.borderColor = [NSColor colorWithWhite:1 alpha:0.14].CGColor;
    g_panel.contentView = fx;

    g_orb_view = [[OrbLayerView alloc] initWithFrame:NSMakeRect(0, 0, kOrbSide, kPillHeight)];
    [fx addSubview:g_orb_view];
    g_label = [NSTextField labelWithString:@""];
    g_label.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
    g_label.textColor = NSColor.whiteColor;
    g_label.lineBreakMode = NSLineBreakByTruncatingHead;
    g_label.maximumNumberOfLines = 1;
    [fx addSubview:g_label];
}

static void update_menu_icon(void) {
    OrbAnim snap = g_anim;
    g_status.button.image = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        orb_draw(&snap, NSGraphicsContext.currentContext.CGContext, rect, true);
        return YES;
    }];
}

static void schedule_timer(double interval);
static void on_tick(void) {
    CFTimeInterval now = CACurrentMediaTime();
    double dt = g_last_tick ? now - g_last_tick : 1.0 / 60;
    g_last_tick = now;
    float in = g_level_in;
    orb_tick(&g_anim, dt, g_target, in);
    if (g_panel.isVisible) [g_orb_view applyAnim:&g_anim];
    // AppKit re-snapshots the status item on every image change, which dominates CPU. The pill
    // shows the full animation, so while it is visible the menu icon only refreshes at ~5 fps.
    static unsigned frame;
    if (!g_panel.isVisible || ++frame % 12 == 0) update_menu_icon();
    // Fully idle with the pill hidden: nothing moves, so stop ticking until the next state change.
    if (g_target == SA_IDLE && !g_panel.isVisible && g_anim.w[0] > 0.999 && g_anim.level < 0.001) {
        [g_timer invalidate];
        g_timer = nil;
    }
}

static void schedule_timer(double interval) {
    [g_timer invalidate];
    g_last_tick = 0;
    g_timer = [NSTimer timerWithTimeInterval:interval repeats:YES block:^(NSTimer *t) { on_tick(); }];
    [NSRunLoop.mainRunLoop addTimer:g_timer forMode:NSRunLoopCommonModes];
}

static void show_pill(void) {
    layout_pill(NO);
    NSRect target = g_panel.frame;
    BOOL entering = !g_panel.isVisible;
    if (entering) {
        // Slide up from slightly below while fading in.
        g_panel.alphaValue = 0;
        [g_panel setFrame:NSOffsetRect(target, 0, -14) display:NO];
        [g_panel orderFrontRegardless];
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = entering ? 0.28 : 0.15;
        ctx.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.25 :1.0];
        g_panel.animator.alphaValue = 1;
        if (entering) [g_panel.animator setFrame:target display:YES];
    }];
    schedule_timer(1.0 / 60);
}

static void hide_pill(void) {
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.2;
        g_panel.animator.alphaValue = 0;
    } completionHandler:^{
        if (g_panel.alphaValue == 0) {
            [g_panel orderOut:nil];
            if (g_target == SA_IDLE) schedule_timer(1.0 / 10);
        }
    }];
}

void sa_set_state(int state) {
    g_target = state;
    g_notice_gen++; // cancels any pending notice hide
    g_notice_active = NO;
    if (state == SA_IDLE) {
        g_text = @"";
        g_level_in = 0;
        hide_pill();
    } else {
        show_pill();
    }
}

void sa_overlay_set_text(const char *text) {
    g_text = [NSString stringWithUTF8String:text] ?: @"";
    if (g_panel.isVisible) layout_pill(YES);
}

void sa_overlay_notice(const char *text) {
    g_text = [NSString stringWithUTF8String:text] ?: @"";
    g_notice_active = YES;
    NSUInteger gen = ++g_notice_gen;
    show_pill();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (gen == g_notice_gen && g_target == SA_IDLE) {
            g_notice_active = NO;
            g_text = @"";
            hide_pill();
        }
    });
}

void sa_after_ms(uint32_t ms, void (*fn)(uint32_t), uint32_t token) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ fn(token); });
}

bool sa_accessibility_trusted(bool prompt) {
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt : @(prompt)};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

void sa_pasteboard_set(const char *text) {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:[NSString stringWithUTF8String:text] forType:NSPasteboardTypeString];
}

void sa_pasteboard_stash(void) {
    if (g_saved_items) return; // already holding the user's original clipboard
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSMutableArray *copies = [NSMutableArray array];
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        NSPasteboardItem *copy = [NSPasteboardItem new];
        for (NSPasteboardType type in item.types) {
            NSData *data = [item dataForType:type];
            if (data) [copy setData:data forType:type];
        }
        [copies addObject:copy];
    }
    g_saved_items = copies;
}

long sa_pasteboard_change_count(void) { return NSPasteboard.generalPasteboard.changeCount; }

size_t sa_pasteboard_read(char *buf, size_t cap) {
    NSString *str = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (!str.length) return 0;
    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
    size_t n = MIN(data.length, cap - 1);
    memcpy(buf, data.bytes, n);
    buf[n] = 0;
    return n;
}

void sa_pasteboard_stash_and_set(const char *text) {
    sa_pasteboard_stash();
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:[NSString stringWithUTF8String:text] forType:NSPasteboardTypeString];
}

void sa_pasteboard_restore(void) {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    if (g_saved_items.count) [pb writeObjects:g_saved_items];
    g_saved_items = nil;
}

// One term per line (names, jargon) the recognizer should favour. Edited from the menu bar.
static NSString *vocabulary_path(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"SiriAssistant"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"vocabulary.txt"];
}

static NSArray<NSString *> *vocabulary_terms(void) {
    NSString *text = [NSString stringWithContentsOfFile:vocabulary_path() encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray *terms = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (t.length && ![t hasPrefix:@"#"]) [terms addObject:t];
    }
    return terms;
}

static bool g_using_sx;
static long g_sx_id;

static void sx_text(const char *text, bool is_final, long id) {
    if (id != g_sx_id) return; // a previous session finishing late
    if (is_final && !*text) report_error(@"No speech detected");
    else g_cb.on_text(text, is_final);
}

bool sa_begin_listening(void) {
    AVAudioInputNode *input = g_engine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    if (fmt.sampleRate <= 0) {
        report_error(@"No audio input (check Microphone permission).");
        return false;
    }
    NSArray<NSString *> *terms = vocabulary_terms();

    // Prefer SpeechAnalyzer (more accurate, no time limit); fall back to SFSpeechRecognizer.
    bool use_sx = false;
    if (g_sx.ready && g_sx.ready()) {
        g_sx_id = g_sx.start([terms componentsJoinedByString:@"\n"].UTF8String, sx_text);
        use_sx = g_sx_id != 0;
    }
    SFSpeechAudioBufferRecognitionRequest *req = nil;
    if (!use_sx) {
        if (!g_recognizer || !g_recognizer.isAvailable) {
            report_error(@"Speech recognizer unavailable (check Speech Recognition permission and language).");
            return false;
        }
        req = [SFSpeechAudioBufferRecognitionRequest new];
        req.shouldReportPartialResults = YES;
        req.addsPunctuation = YES;
        req.taskHint = SFSpeechRecognitionTaskHintDictation;
        if (terms.count) req.contextualStrings = terms;
        if (g_recognizer.supportsOnDeviceRecognition) req.requiresOnDeviceRecognition = YES;
    }
    g_request = req;
    g_using_sx = use_sx;

    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        if (use_sx) g_sx.append((__bridge const void *)buf);
        else [req appendAudioPCMBuffer:buf];
        if (buf.floatChannelData) {
            const float *d = buf.floatChannelData[0];
            double sum = 0;
            for (AVAudioFrameCount i = 0; i < buf.frameLength; i++) sum += d[i] * d[i];
            double rms = buf.frameLength ? sqrt(sum / buf.frameLength) : 0;
            double db = 20 * log10(fmax(rms, 1e-6));
            g_level_in = (float)fmin(1.0, fmax(0.0, (db + 52) / 38));
        }
    }];
    [g_engine prepare];
    NSError *err = nil;
    if (![g_engine startAndReturnError:&err]) {
        [input removeTapOnBus:0];
        if (use_sx) { g_sx.finish(); g_sx_id = 0; }
        g_request = nil;
        report_error([NSString stringWithFormat:@"Audio engine failed: %@", err.localizedDescription]);
        return false;
    }

    if (!use_sx) {
        NSUInteger gen = ++g_generation;
        g_task = [g_recognizer recognitionTaskWithRequest:req resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != g_generation) return;
                if (result) {
                    g_cb.on_text(result.bestTranscription.formattedString.UTF8String, result.isFinal);
                } else if (error) {
                    report_error(error.localizedDescription);
                }
            });
        }];
    }
    return true;
}

void sa_stop_listening(void) {
    if (g_engine.isRunning) {
        [g_engine stop];
        [g_engine.inputNode removeTapOnBus:0];
    }
    g_level_in = 0;
    if (g_using_sx) {
        g_using_sx = false; // keep g_sx_id so the final text from this session is still accepted
        g_sx.finish();
    } else {
        [g_request endAudio];
    }
    g_request = nil;
}

void sa_run(const sa_callbacks *cb) {
    g_cb = *cb;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        load_swift();
        if (g_sx.prepare) g_sx.prepare();
        if (g_sx.prewarm) g_sx.prewarm();
        g_engine = [AVAudioEngine new];
        g_recognizer = [SFSpeechRecognizer new]; // system locale
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus s) {
            if (s != SFSpeechRecognizerAuthorizationStatusAuthorized)
                dispatch_async(dispatch_get_main_queue(), ^{ report_error(@"Speech Recognition permission denied (System Settings > Privacy & Security)."); });
        }];
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL ok) {
            if (!ok) dispatch_async(dispatch_get_main_queue(), ^{ report_error(@"Microphone permission denied (System Settings > Privacy & Security)."); });
        }];

        g_menu_target = [SAMenuTarget new];
        g_status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        orb_init(&g_anim);
        build_pill();
        update_menu_icon();
        schedule_timer(1.0 / 10);
        NSMenu *menu = [NSMenu new];
        NSMenuItem *t = [menu addItemWithTitle:@"Start / stop dictation (hold ⌘⇧R)" action:@selector(toggle:) keyEquivalent:@""];
        t.target = g_menu_target;
        NSMenuItem *e = [menu addItemWithTitle:@"Start / stop dictation + enhance (hold ⌘⇧E)" action:@selector(toggleEnhance:) keyEquivalent:@""];
        e.target = g_menu_target;
        NSMenuItem *rw = [menu addItemWithTitle:@"Start / stop rewrite selection (hold ⌘⇧T)" action:@selector(toggleRewrite:) keyEquivalent:@""];
        rw.target = g_menu_target;
        [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *styleItem = [menu addItemWithTitle:@"Enhance style" action:nil keyEquivalent:@""];
        NSMenu *styleMenu = [NSMenu new];
        NSArray *titles = @[ @"Clean up", @"Formal", @"Concise", @"AI prompt", @"Bullet notes" ];
        NSString *current = [NSUserDefaults.standardUserDefaults stringForKey:g_style_key] ?: @"clean";
        for (NSUInteger i = 0; i < titles.count; i++) {
            NSMenuItem *it = [styleMenu addItemWithTitle:titles[i] action:@selector(selectStyle:) keyEquivalent:@""];
            it.target = g_menu_target;
            it.tag = (NSInteger)i;
            it.state = [enhance_styles()[i] isEqualToString:current] ? NSControlStateValueOn : NSControlStateValueOff;
        }
        styleItem.submenu = styleMenu;
        NSMenuItem *snd = [menu addItemWithTitle:@"Sounds" action:@selector(toggleSounds:) keyEquivalent:@""];
        snd.target = g_menu_target;
        snd.state = ([NSUserDefaults.standardUserDefaults objectForKey:@"sounds"] && ![NSUserDefaults.standardUserDefaults boolForKey:@"sounds"])
                        ? NSControlStateValueOff : NSControlStateValueOn;
        NSMenuItem *v = [menu addItemWithTitle:@"Edit vocabulary…" action:@selector(editVocabulary:) keyEquivalent:@""];
        v.target = g_menu_target;
        NSMenuItem *q = [menu addItemWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
        q.target = g_menu_target;
        g_status.menu = menu;

        EventTypeSpec spec[2] = {{kEventClassKeyboard, kEventHotKeyPressed}, {kEventClassKeyboard, kEventHotKeyReleased}};
        InstallApplicationEventHandler(&hotkey_handler, 2, spec, NULL, NULL);
        static const struct { UInt32 key; UInt32 id; const char *name; } keys[3] = {
            {kVK_ANSI_R, 1, "Cmd+Shift+R"}, {kVK_ANSI_E, 2, "Cmd+Shift+E"}, {kVK_ANSI_T, 3, "Cmd+Shift+T"}};
        for (int i = 0; i < 3; i++) {
            EventHotKeyID hkid = {'SiAs', keys[i].id};
            EventHotKeyRef ref;
            OSStatus st = RegisterEventHotKey(keys[i].key, cmdKey | shiftKey, hkid, GetApplicationEventTarget(), 0, &ref);
            if (st != noErr) report_error([NSString stringWithFormat:@"Could not register %s (another app may own it).", keys[i].name]);
        }

        // `kill -USR1 <pid>` toggles dictation (USR2: with enhance, WINCH: rewrite selection); handy for scripted testing.
        signal(SIGUSR1, SIG_IGN);
        static dispatch_source_t usr1;
        usr1 = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(usr1, ^{ g_cb.on_toggle(1); });
        dispatch_resume(usr1);
        signal(SIGUSR2, SIG_IGN);
        static dispatch_source_t usr2;
        usr2 = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR2, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(usr2, ^{ g_cb.on_toggle(2); });
        dispatch_resume(usr2);
        signal(SIGWINCH, SIG_IGN);
        static dispatch_source_t usr3;
        usr3 = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGWINCH, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(usr3, ^{ g_cb.on_toggle(3); });
        dispatch_resume(usr3);

        [NSApp run];
    }
}
