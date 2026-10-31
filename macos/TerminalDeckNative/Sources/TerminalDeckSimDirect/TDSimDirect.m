#import "TDSimDirect.h"
#import "TDDirectMach.h"
#import "TDSimShared.h"

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <signal.h>
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import <xpc/xpc.h>

// What was measured on this Mac (Xcode 27.1, CoreSimulator of 22 Oct 2026) and is relied on here:
//  - the main screen is the `com.apple.framebuffer.display` port whose descriptor's state says
//    displayClass 0; its `framebufferSurface` is the live BGRA IOSurface the simulator draws into;
//  - `registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:
//    propertiesChangedCallback:` calls the frame block once per drawn picture and never while the
//    screen is still, and the surfaces block at once and whenever the surface is replaced;
//  - SimulatorKit's Indigo messages: a touch from IndigoHIDMessageForMouseNSEvent has one payload
//    of 0xA0 bytes per finger after a leading one, each with its x and y ratio (doubles) at +0x1C
//    and +0x24; a finger that is down and moves is another "down" at the new place;
//    IndigoHIDMessageForKeyboardArbitrary(usage, 1 down | 2 up); IndigoHIDMessageForButton
//    (source 0 home | 1 lock, 1 down | 2 up, target 0x33); IndigoHIDMessageForHIDArbitrary for the volume and Action
//    buttons (see TDArbitraryMessage). Anything else is refused, never guessed.
//
// Apple's newer touchscreen (Xcode 27; measured 22 Oct 2026 on an iPhone 18 Pro and an iPhone 17e, iOS 27):
// inside the simulator, CoreDevice's HID daemon `dtuhidd` is started on demand by a client (Device Hub
// attaches to every booted simulator while it is open; Xcode) and sets the Darwin state
// `com.apple.coredevice.dtuhidd.active` to 1 while it runs (0 when it ends). SimulatorHID
// then turns its Indigo digitizer into an external accessory and backboardd takes the screen's touches
// from dtuhidd's "CoreDevice touchscreen": Indigo touches and buttons are accepted and silently dropped.
// So the helper reads that state (what the device reports, never its name) at each new gesture and
// button press, and while it is 1 speaks dtuhidd's own messages: an XPC dictionary {featureIdentifier,
// messageType, payload} sent one way to the simulator's mach service
// `com.apple.coredevice.feature.remote.hid.<digitizer|button|keyboard>` (looked up through CoreSimulator,
// the connection marked sim-to-host or dtuhidd never reads a message), payload as CoreDevice encodes it
// (learned by decoding CoreDeviceUtilities' own Codable types, not copied):
//    IndigoDigitizerEvent       {pointOne {x y} 0...1 from top left, pointTwo?, eventType 0 start | 1 move
//                                | 2 end, edge 0 none, target 0 main screen}
//    IndigoButtonEvent          {usagePage, usageCode, state 1 down | 2 up}
//    IndigoKeyboardButtonEvent  {usageCode (keyboard page), state 1 | 2}
// The helper never starts dtuhidd itself: while the state is 0 the Indigo path (which works then) stays.
// It never holds on to dtuhidd either: each connection is a dtuhidd client (a session with its own touchscreen,
// keyboard and buttons), so the connections close after 5 s without input. Measured 22 Oct 2026: dtuhidd itself
// stays running (state 1) after its last client leaves, until the simulator shuts down or launchd ends it, so a
// simulator Device Hub once attached to keeps CoreDevice's touchscreen; this helper sends there then.

typedef void *(*TDMouseMessage)(CGPoint *, CGPoint *, uint32_t, unsigned long, BOOL);
typedef void *(*TDKeyboardMessage)(uint32_t, uint32_t);
typedef void *(*TDButtonMessage)(uint32_t, uint32_t, uint32_t);
// IndigoHIDMessageForHIDArbitrary(IndigoHIDTarget, uint32_t usage page, uint32_t usage, IndigoHIDButtonOp), as SimulatorKit's own
// assertion names it. Measured 28 Oct 2026 (Xcode 27.1): SimulatorKit's screen sends the consumer-page buttons it has no
// button code for (volume 0xE9 / 0xEA) and other pages' buttons (telephony 0x0B Action 0x2D) this way, to the screen's
// button target (0x33), 1 down | 2 up.
typedef void *(*TDArbitraryMessage)(uint32_t, uint32_t, uint32_t, uint32_t);

static const uint32_t TDTouchTarget = 0x32;
static const uint32_t TDButtonTarget = 0x33;
static const unsigned long TDMouseDown = 1;  // NSEventTypeLeftMouseDown
static const unsigned long TDMouseUp = 2;    // NSEventTypeLeftMouseUp
static const size_t TDPayloadStart = 0x20;
static const size_t TDPayloadStride = 0xA0;
static const size_t TDPayloadX = 0x1C;
static const size_t TDPayloadY = 0x24;

static TDMouseMessage tdMouse;
static TDKeyboardMessage tdKeyboard;
static TDButtonMessage tdButton;
static TDArbitraryMessage tdArbitrary;
static id tdHID;
static dispatch_queue_t tdHIDQueue;
static mach_port_t tdApp = MACH_PORT_NULL;
static int tdInputOnly = 0;                    // AI device tools with no panel: no screen, no frame notices
static volatile int tdPaused = 0;
static volatile int tdHIDFailed = 0;

typedef xpc_endpoint_t (*TDEndpointForSimPort)(mach_port_t);
typedef void (*TDSimToHost)(xpc_connection_t);
enum { TDCoreDigitizer, TDCoreButton, TDCoreKeyboard, TDCoreCount };
static const char *const TDCoreServices[TDCoreCount] = {
    "com.apple.coredevice.feature.remote.hid.digitizer",
    "com.apple.coredevice.feature.remote.hid.button",
    "com.apple.coredevice.feature.remote.hid.keyboard",
};
static NSString *const TDCoreActiveState = @"com.apple.coredevice.dtuhidd.active";
static TDEndpointForSimPort tdEndpointForSimPort;
static TDSimToHost tdSimToHost;
static xpc_connection_t tdCore[TDCoreCount];   // only touched on tdCoreQueue
static dispatch_queue_t tdCoreQueue;
static id tdDevice;
static int tdCoreAvailable = 0;                // the simulator has dtuhidd's services at all
static volatile int tdCoreState = -1;          // last read: 1 CoreDevice touchscreen, 0 Indigo, -1 not yet
static volatile int tdCoreNotes = 0;
static int tdTouching = 0;                     // a finger is down (main thread only)
static int tdTouchCore = 0;                    // the gesture in progress goes to dtuhidd
static id tdDisplay;                           // the main screen (its orientation is read per AI gesture)
static uint32_t tdGestureUI = 1;               // the app's orientation, read at an AI gesture's first finger
static int tdButtonCore = 0;                   // the button press in progress goes to dtuhidd
static int tdButtonsHeld = 0;                  // buttons this helper holds down (main thread only)
static uint8_t tdKeyHeld[0x10000 / 8];         // keys this helper holds down, by usage (main thread only)
static int tdKeysHeld = 0;
static int tdKeysCore = 0;                     // the keys held now go to dtuhidd
static volatile int tdHolding = 0;             // a finger, key or button is down: connections stay open
static volatile int tdMissNotes = 0;
static dispatch_source_t tdCoreIdle;           // closes dtuhidd's connections after a quiet spell
static const int64_t TDCoreIdleNs = 5 * NSEC_PER_SEC;
static volatile uint64_t tdCoreReadAt = 0;     // when the touchscreen state was last read (uptime ns)
// A key burst trusts a state read this recently. Typing read it once per character before, a CoreSimulator call
// each, and long AI typing fell behind the app's writes (review 22 Oct 2026). Touches and buttons read it fresh.
static const uint64_t TDKeyStateFreshNs = 250 * NSEC_PER_MSEC;

static void say(NSString *line) {
    NSString *flat = [[line componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    fprintf(stdout, "%s\n", flat.UTF8String);
    fflush(stdout);
}

static int fail(NSString *words) {
    say([@"error " stringByAppendingString:words]);
    return 3;
}

id td_sim_send0(id target, NSString *selector) {
    SEL sel = NSSelectorFromString(selector);
    if (!target || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

NSString *td_sim_developer_directory(void) {
    NSString *fromEnvironment = NSProcessInfo.processInfo.environment[@"DEVELOPER_DIR"];
    if (fromEnvironment.length > 0) return fromEnvironment;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcode-select"];
    task.arguments = @[@"-p"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if ([task launchAndReturnError:nil]) {
        NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        NSString *path = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (task.terminationStatus == 0 && path.length > 0) return path;
    }
    return @"/Applications/Xcode.app/Contents/Developer";
}

id td_sim_find_device(NSString *udid, NSString *developer, NSString **why) {
    Class context = NSClassFromString(@"SimServiceContext");
    SEL shared = NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:");
    if (!context || ![context respondsToSelector:shared]) { *why = @"CoreSimulator has no service context"; return nil; }
    NSError *error = nil;
    id service = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(context, shared, developer, &error);
    SEL setSelector = NSSelectorFromString(@"defaultDeviceSetWithError:");
    if (!service || ![service respondsToSelector:setSelector]) { *why = @"CoreSimulator did not answer"; return nil; }
    id set = ((id (*)(id, SEL, NSError **))objc_msgSend)(service, setSelector, &error);
    NSArray *devices = td_sim_send0(set, @"devices");
    if (![devices isKindOfClass:NSArray.class]) { *why = @"CoreSimulator listed no devices"; return nil; }
    for (id device in devices) {
        NSUUID *identifier = td_sim_send0(device, @"UDID");
        if ([identifier isKindOfClass:NSUUID.class] && [identifier.UUIDString caseInsensitiveCompare:udid] == NSOrderedSame) return device;
    }
    *why = @"that simulator is not on this Mac";
    return nil;
}

long td_sim_device_state(id device) {
    SEL sel = NSSelectorFromString(@"state");
    if (![device respondsToSelector:sel]) return -1;
    return ((long (*)(id, SEL))objc_msgSend)(device, sel);
}

static id mainDisplay(id device) {
    id io = td_sim_send0(device, @"io");
    NSArray *ports = td_sim_send0(io, @"ioPorts");
    if (![ports isKindOfClass:NSArray.class]) return nil;
    for (id port in ports) {
        id identifier = td_sim_send0(port, @"portIdentifier");
        if (![[identifier description] isEqualToString:@"com.apple.framebuffer.display"]) continue;
        id descriptor = td_sim_send0(port, @"descriptor");
        id state = td_sim_send0(descriptor, @"state");
        SEL displayClass = NSSelectorFromString(@"displayClass");
        if (!state || ![state respondsToSelector:displayClass]) continue;
        if (((unsigned short (*)(id, SEL))objc_msgSend)(state, displayClass) == 0) return descriptor;
    }
    return nil;
}

static void handSurface(id surface) {
    if (!surface || CFGetTypeID((__bridge CFTypeRef)surface) != IOSurfaceGetTypeID()) return;
    IOSurfaceRef ref = (__bridge IOSurfaceRef)surface;
    mach_port_t port = IOSurfaceCreateMachPort(ref);
    if (port == MACH_PORT_NULL) return;
    td_direct_send_surface(tdApp, port, (uint32_t)IOSurfaceGetWidth(ref), (uint32_t)IOSurfaceGetHeight(ref));
}

static void sendHID(void *message) {
    if (!message) return;
    SEL sel = NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:");
    ((void (*)(id, SEL, void *, BOOL, id, id))objc_msgSend)(tdHID, sel, message, YES, tdHIDQueue, ^(NSError *error) {
        if (error && !tdHIDFailed) {
            tdHIDFailed = 1;
            say([@"error the simulator refused input: " stringByAppendingString:error.localizedDescription ?: @"unknown"]);
        }
    });
}

static void coreWarm(void);

/// A line the app writes to engine.log; a handful at most, so a failing simulator cannot flood it.
static void coreNote(NSString *words) {
    if (__sync_fetch_and_add(&tdCoreNotes, 1) < 4) say([@"note " stringByAppendingString:words]);
}

/// 1 while the simulator's touchscreen is CoreDevice's (dtuhidd running), else 0. The app hears of
/// every change, so the buttons only dtuhidd can press go this way exactly then.
static int readCoreState(void) {
    int now = 0;
    SEL sel = NSSelectorFromString(@"darwinNotificationGetState:name:error:");
    if (tdCoreAvailable && [tdDevice respondsToSelector:sel]) {
        uint64_t state = 0;
        NSError *error = nil;
        @try {
            if (((BOOL (*)(id, SEL, uint64_t *, id, NSError **))objc_msgSend)(tdDevice, sel, &state, TDCoreActiveState, &error)) now = state != 0;
        } @catch (NSException *exception) { now = 0; }
    }
    tdCoreReadAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int before = __sync_lock_test_and_set(&tdCoreState, now);
    if (before != -1 && before != now) say(now ? @"hid coredevice" : @"hid indigo");
    if (now && before != now) coreWarm();
    return now;
}

/// The touchscreen a key burst goes to: the state read moments ago (the 2 s watch and every touch read it too),
/// else read now.
static int keyCoreState(void) {
    int last = tdCoreState;
    if (last >= 0 && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - tdCoreReadAt < TDKeyStateFreshNs) return last;
    return readCoreState();
}

/// The simulator's mach port for one of dtuhidd's services, or MACH_PORT_NULL. A lookup only: it
/// does not start dtuhidd (launchd starts it when a message arrives).
static mach_port_t coreLookup(const char *service) {
    SEL sel = NSSelectorFromString(@"lookup:error:");
    if (!tdDevice || ![tdDevice respondsToSelector:sel]) return MACH_PORT_NULL;
    NSError *error = nil;
    @try { return ((mach_port_t (*)(id, SEL, id, NSError **))objc_msgSend)(tdDevice, sel, @(service), &error); }
    @catch (NSException *exception) { return MACH_PORT_NULL; }
}

/// A message type as a plain name (letters and digits only), or "unknown": never anything that was typed.
static NSString *plainName(const char *text) {
    if (!text) return @"unknown";
    size_t length = strnlen(text, 65);
    if (length == 0 || length > 64) return @"unknown";
    for (size_t index = 0; index < length; index++) {
        char c = text[index];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return @"unknown";
    }
    return @(text);
}

/// Input that has no way in now: the simulator's touchscreen changed hands since the app last heard
/// (it hears at once: readCoreState said so) and this helper cannot use the new one. Never silent.
static void missed(NSString *what) {
    if (__sync_fetch_and_add(&tdMissNotes, 1) < 4)
        say([NSString stringWithFormat:@"note %@ had no way in: the simulator's %@ input cannot be used here", what,
             tdCoreState == 1 ? @"CoreDevice" : @"Indigo"]);
}

/// Input went to dtuhidd: its connections close again after a quiet spell (on tdCoreQueue only).
static void coreBusy(void) {
    if (tdCoreIdle) dispatch_source_set_timer(tdCoreIdle, dispatch_time(DISPATCH_TIME_NOW, TDCoreIdleNs), DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 4);
}

/// A quiet spell: every connection to dtuhidd closes, so this helper never holds a dtuhidd session (and
/// whatever it keeps running) longer than it types and touches. Not while a finger, key or button is
/// down. The next input opens a new one: its first touch landed 70 ms after it was sent (measured).
static void coreIdle(void) {
    if (tdHolding) { coreBusy(); return; }
    for (int which = 0; which < TDCoreCount; which++) {
        if (!tdCore[which]) continue;
        xpc_connection_cancel(tdCore[which]);
        tdCore[which] = nil;
    }
}

/// The connection to one of dtuhidd's services, made at first use (on tdCoreQueue only).
static xpc_connection_t coreConnection(int which) {
    if (tdCore[which]) return tdCore[which];
    mach_port_t port = coreLookup(TDCoreServices[which]);
    xpc_endpoint_t endpoint = port != MACH_PORT_NULL && tdEndpointForSimPort ? tdEndpointForSimPort(port) : NULL;
    xpc_connection_t connection = endpoint ? xpc_connection_create_from_endpoint(endpoint) : NULL;
    if (!connection) {
        coreNote([NSString stringWithFormat:@"the simulator's %s service could not be reached", TDCoreServices[which]]);
        return NULL;
    }
    void *made = (__bridge void *)connection;
    // Measured 22 Oct 2026: without this the simulator's libxpc takes the connection but drops every
    // message (dtuhidd logs nothing and cancels the peer); CoreSimulator marks its own the same way.
    tdSimToHost(connection);
    xpc_connection_set_target_queue(connection, tdCoreQueue);
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (event == XPC_ERROR_CONNECTION_INVALID) {
            // Gone for good: the next message makes a new one. (Interrupted means dtuhidd ended; the same
            // connection starts it again with the next message.)
            if ((__bridge void *)tdCore[which] == made) tdCore[which] = nil;
        } else if (xpc_get_type(event) == XPC_TYPE_DICTIONARY && !xpc_dictionary_get_bool(event, "isBarrier")) {
            // dtuhidd only writes back when it could not use a message. Its words may repeat what was
            // typed, so only the service and the message type are noted.
            coreNote([NSString stringWithFormat:@"the simulator refused a message on %s (type %@)", TDCoreServices[which],
                      plainName(xpc_dictionary_get_string(event, "messageType"))]);
        }
    });
    xpc_connection_resume(connection);
    tdCore[which] = connection;
    return connection;
}

/// One message to dtuhidd, in order with every other (one serial queue), never waiting for it.
static void coreSend(int which, const char *type, xpc_object_t payload) {
    dispatch_async(tdCoreQueue, ^{
        xpc_connection_t connection = coreConnection(which);
        if (!connection) return;
        xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(message, "featureIdentifier", TDCoreServices[which]);
        xpc_dictionary_set_string(message, "messageType", type);
        xpc_dictionary_set_value(message, "payload", payload);
        xpc_connection_send_message(connection, message);
        coreBusy();
    });
}

/// Opens the digitizer connection ahead of the first finger: dtuhidd sets a client up (its own touchscreen
/// and buttons) when its first message arrives, which takes 0.2-0.4 s. A barrier is that message: dtuhidd
/// only answers it. Only while dtuhidd already runs, so it never starts dtuhidd itself.
static void coreWarm(void) {
    dispatch_async(tdCoreQueue, ^{
        xpc_connection_t connection = coreConnection(TDCoreDigitizer);
        if (!connection) return;
        xpc_object_t barrier = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_string(barrier, "featureIdentifier", TDCoreServices[TDCoreDigitizer]);
        xpc_dictionary_set_bool(barrier, "isBarrier", true);
        xpc_connection_send_message_with_reply(connection, barrier, tdCoreQueue, ^(xpc_object_t reply) { (void)reply; });
        coreBusy();
    });
}

static xpc_object_t corePoint(double x, double y) {
    xpc_object_t point = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_double(point, "x", x);
    xpc_dictionary_set_double(point, "y", y);
    return point;
}

/// phase: 0 the first finger(s) down, 1 moved, 2 lifted.
static void coreTouch(int fingers, uint64_t phase, double x1, double y1, double x2, double y2) {
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(event, "pointOne", corePoint(x1, y1));
    if (fingers == 2) xpc_dictionary_set_value(event, "pointTwo", corePoint(x2, y2));
    xpc_dictionary_set_uint64(event, "eventType", phase);
    xpc_dictionary_set_uint64(event, "edge", 0);
    xpc_dictionary_set_uint64(event, "target", 0);
    coreSend(TDCoreDigitizer, "IndigoDigitizerEvent", event);
}

static void coreKey(unsigned usage, BOOL down) {
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(event, "usageCode", usage);
    xpc_dictionary_set_uint64(event, "state", down ? 1 : 2);
    coreSend(TDCoreKeyboard, "IndigoKeyboardButtonEvent", event);
}

/// The iPhone's buttons as HID usages (the iPhone 18 Pro's own device chrome and CoreDevice's tables):
/// consumer page 0x0C home 0x40, side 0x30, volume 0xE9 / 0xEA; telephony page 0x0B Action 0x2D.
static BOOL coreButton(const char *name, BOOL down) {
    uint64_t page = 0x0C, code;
    if (strcmp(name, "home") == 0) code = 0x40;
    else if (strcmp(name, "lock") == 0) code = 0x30;
    else if (strcmp(name, "volume-up") == 0) code = 0xE9;
    else if (strcmp(name, "volume-down") == 0) code = 0xEA;
    else if (strcmp(name, "action") == 0) { page = 0x0B; code = 0x2D; }
    else return NO;
    xpc_object_t event = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(event, "usagePage", page);
    xpc_dictionary_set_uint64(event, "usageCode", code);
    xpc_dictionary_set_uint64(event, "state", down ? 1 : 2);
    coreSend(TDCoreButton, "IndigoButtonEvent", event);
    return YES;
}

/// A touch message with every finger's place written in, or NULL when its shape is not the one measured.
static void *touchMessage(int fingers, BOOL down, double x1, double y1, double x2, double y2) {
    CGPoint first = CGPointMake(x1, y1), second = CGPointMake(x2, y2);
    uint8_t *message = tdMouse(&first, fingers == 2 ? &second : NULL, TDTouchTarget, down ? TDMouseDown : TDMouseUp, NO);
    if (!message) return NULL;
    uint32_t stride = *(uint32_t *)(message + 0x18);
    uint8_t count = message[0x1C];
    if (stride != TDPayloadStride || count != (uint8_t)(fingers + 1)) { free(message); return NULL; }
    for (uint8_t index = 0; index < count; index++) {
        uint8_t *payload = message + TDPayloadStart + index * TDPayloadStride;
        BOOL secondFinger = fingers == 2 && index == 2;
        double x = secondFinger ? x2 : x1, y = secondFinger ? y2 : y1;
        memcpy(payload + TDPayloadX, &x, sizeof(double));
        memcpy(payload + TDPayloadY, &y, sizeof(double));
    }
    return message;
}

static double unit(double value) { return value < 0 ? 0 : (value > 1 ? 1 : value); }

/// How the app on screen is turned, as the screen reports it (CoreSimulator's screen properties, `uiOrientation`,
/// UIInterfaceOrientation): 1 upright, 2 upside down, 3 and 4 turned. It follows the app, not the device: measured
/// 22 Oct 2026 on an iPhone 17e turned left, 3 with Safari, 1 with the Home Screen and Settings (which stay
/// upright). 1 when it cannot be read.
static uint32_t uiOrientation(void) {
    SEL sel = NSSelectorFromString(@"uiOrientation");
    @try {
        id properties = td_sim_send0(tdDisplay, @"screenProperties");
        if (![properties respondsToSelector:sel]) return 1;
        uint32_t value = ((uint32_t (*)(id, SEL))objc_msgSend)(properties, sel);
        return value >= 1 && value <= 4 ? value : 1;
    } @catch (NSException *exception) { return 1; }
}

/// A point in the turned app's frame (where devices.tree puts things, 0...1 from its top left) as the point on the
/// upright screen, which is where both touchscreens and the screen picture are. Measured 22 Oct 2026 for 3 (Safari
/// turned left: its (x, y) is the upright (y, 1 - x)); 4 and 2 are the other quarter turn and the half turn.
static void upright(uint32_t ui, double *x, double *y) {
    double ax = *x, ay = *y;
    if (ui == 3) { *x = ay; *y = 1 - ax; }
    else if (ui == 4) { *x = 1 - ay; *y = ax; }
    else if (ui == 2) { *x = 1 - ax; *y = 1 - ay; }
}

static void handleLine(char *line) {
    char verb = line[0];
    if (verb == 'P') {
        tdPaused = line[1] == ' ' && line[2] == '1';
        if (!tdPaused && !tdInputOnly) td_direct_send_frame(tdApp);
        return;
    }
    if (verb == 'E') {
        // `E <n>`: every line before this one is taken, its messages queued in order (after dtuhidd's, on their
        // queue). Long AI typing writes its next piece only then, so the input pipe never fills: a short write
        // ends this helper, and a panel's screen with it (review 22 Oct 2026).
        NSString *echo = [NSString stringWithFormat:@"echo %ld", strtol(line + 1, NULL, 10)];
        if (tdCoreQueue) dispatch_async(tdCoreQueue, ^{ say(echo); });
        else say(echo);
        return;
    }
    if (verb == 'T' || verb == 'U' || verb == 't' || verb == 'u') {
        int fingers = 0;
        double x1 = 0, y1 = 0, x2 = 0, y2 = 0;
        int read = sscanf(line + 1, "%d %lf %lf %lf %lf", &fingers, &x1, &y1, &x2, &y2);
        if (!((fingers == 1 && read >= 3) || (fingers == 2 && read == 5))) return;
        BOOL down = verb == 'T' || verb == 't';
        // t/u: AI device tools, whose points are in the app's frame (devices.tree); T/U: the panel, which shows the
        // upright screen. A new gesture: whose touchscreen is it now, and how is the app turned? The whole gesture
        // then goes that one way (review 22 Oct 2026: turned apps got AI taps in the wrong place).
        BOOL appFrame = verb == 't' || verb == 'u';
        if (!tdTouching) {
            tdTouchCore = readCoreState();
            tdGestureUI = appFrame ? uiOrientation() : 1;
        }
        if (appFrame) {
            upright(tdGestureUI, &x1, &y1);
            if (fingers == 2) upright(tdGestureUI, &x2, &y2);
        }
        if (tdTouchCore) {
            coreTouch(fingers, down ? (tdTouching ? 1 : 0) : 2, unit(x1), unit(y1), unit(x2), unit(y2));
        } else {
            void *message = tdHID && tdMouse ? touchMessage(fingers, down, unit(x1), unit(y1), unit(x2), unit(y2)) : NULL;
            if (message) sendHID(message);
            else if (!tdTouching) missed(@"a touch");
        }
        tdTouching = down;
    } else if (verb == 'K') {
        unsigned usage = 0;
        char direction = 0;
        if (sscanf(line + 1, "%u %c", &usage, &direction) != 2 || usage == 0 || usage > 0xFFFF) return;
        BOOL down = direction == 'd';
        uint8_t bit = (uint8_t)(1u << (usage & 7));
        BOOL held = (tdKeyHeld[usage >> 3] & bit) != 0;
        if (down && !held) {
            // The first key of a burst (none held): whose keyboard is it now? Every key until all are up
            // goes that one way, so no key is pressed on one and lifted on the other.
            if (tdKeysHeld == 0) tdKeysCore = keyCoreState();
            tdKeyHeld[usage >> 3] |= bit;
            tdKeysHeld++;
        } else if (!down) {
            if (!held) return;   // not down here: nothing to lift (and no old route that could wake dtuhidd)
            tdKeyHeld[usage >> 3] &= (uint8_t)~bit;
            tdKeysHeld--;
        }
        if (tdKeysCore) coreKey(usage, down);
        else if (tdHID && tdKeyboard) sendHID(tdKeyboard(usage, down ? 1 : 2));
        else if (down) missed(@"a key");
    } else if (verb == 'B') {
        char name[16] = {0};
        char direction = 0;
        if (sscanf(line + 1, "%15s %c", name, &direction) != 2) return;
        BOOL down = direction == 'd';
        if (down) {
            if (tdButtonsHeld == 0) tdButtonCore = readCoreState();
            tdButtonsHeld++;
        } else {
            if (tdButtonsHeld == 0) return;   // not down here: nothing to lift
            tdButtonsHeld--;
        }
        if (tdButtonCore) {
            if (!coreButton(name, down) && down) missed(@"a button");
            return;
        }
        uint32_t source = 2;
        if (strcmp(name, "home") == 0) source = 0;
        else if (strcmp(name, "lock") == 0) source = 1;
        uint32_t page = 0, usage = 0;
        if (strcmp(name, "volume-up") == 0) { page = 0x0C; usage = 0xE9; }
        else if (strcmp(name, "volume-down") == 0) { page = 0x0C; usage = 0xEA; }
        else if (strcmp(name, "action") == 0) { page = 0x0B; usage = 0x2D; }
        if (tdHID && tdButton && source < 2) sendHID(tdButton(source, down ? 1 : 2, TDButtonTarget));
        else if (tdHID && tdArbitrary && page != 0) sendHID(tdArbitrary(TDButtonTarget, page, usage, down ? 1 : 2));
        else if (down) missed(@"a button");
    }
}

/// Every input line, then whether anything is still held down (the quiet-spell closing waits for it).
static void handleInput(char *line) {
    handleLine(line);
    tdHolding = tdTouching || tdKeysHeld > 0 || tdButtonsHeld > 0;
}

int td_sim_direct_run(const char *udidText, const char *serviceText) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        if (!udidText || !serviceText) return fail(@"missing arguments");
        NSString *udid = @(udidText);
        // "-": input only, for AI sessions' device tools while no panel shows this simulator. No screen is
        // registered, so CoreSimulator sends no pictures and nothing runs per frame.
        tdInputOnly = strcmp(serviceText, "-") == 0;
        if (!tdInputOnly && td_direct_connect(serviceText, &tdApp) != KERN_SUCCESS) return fail(@"the app's screen port was not found");

        NSString *developer = td_sim_developer_directory();
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW))
            return fail(@"CoreSimulator could not be loaded");
        NSString *kit = [developer stringByAppendingPathComponent:@"../SharedFrameworks/SimulatorKit.framework/SimulatorKit"];
        void *simulatorKit = dlopen(kit.fileSystemRepresentation, RTLD_NOW);

        id device = nil, display = nil;
        int touch = 0, keys = 0, buttons = 0, side = 0;
        @try {
            NSString *why = nil;
            device = td_sim_find_device(udid, developer, &why);
            if (!device) return fail(why ?: @"simulator not found");
            if (td_sim_device_state(device) != 3) return fail(@"the simulator is not running");
            tdDevice = device;
            display = mainDisplay(device);
            tdDisplay = display;
            if (!display && !tdInputOnly) return fail(@"the simulator's screen was not found");

            if (simulatorKit) {
                tdMouse = (TDMouseMessage)dlsym(simulatorKit, "IndigoHIDMessageForMouseNSEvent");
                tdKeyboard = (TDKeyboardMessage)dlsym(simulatorKit, "IndigoHIDMessageForKeyboardArbitrary");
                tdButton = (TDButtonMessage)dlsym(simulatorKit, "IndigoHIDMessageForButton");
                tdArbitrary = (TDArbitraryMessage)dlsym(simulatorKit, "IndigoHIDMessageForHIDArbitrary");
                Class client = NSClassFromString(@"_TtC12SimulatorKit24SimDeviceLegacyHIDClient");
                SEL make = NSSelectorFromString(@"initWithDevice:error:");
                if (client && [client instancesRespondToSelector:make]) {
                    NSError *error = nil;
                    tdHID = ((id (*)(id, SEL, id, NSError **))objc_msgSend)([client alloc], make, device, &error);
                }
            }
            if (tdHID) {
                tdHIDQueue = dispatch_queue_create("terminaldeck.sim-direct.hid", DISPATCH_QUEUE_SERIAL);
                if (tdMouse) {
                    void *probe = touchMessage(1, YES, 0.5, 0.5, 0, 0);
                    touch = probe != NULL;
                    free(probe);
                }
                keys = tdKeyboard != NULL;
                buttons = tdButton != NULL;
                side = tdArbitrary != NULL;
            }
            tdEndpointForSimPort = (TDEndpointForSimPort)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
            tdSimToHost = (TDSimToHost)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
            tdCoreQueue = dispatch_queue_create("terminaldeck.sim-direct.coredevice",
                dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
            tdCoreAvailable = tdEndpointForSimPort && tdSimToHost && coreLookup(TDCoreServices[TDCoreDigitizer]) != MACH_PORT_NULL;
            tdCoreIdle = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, tdCoreQueue);
            dispatch_source_set_timer(tdCoreIdle, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
            dispatch_source_set_event_handler(tdCoreIdle, ^{ coreIdle(); });
            dispatch_resume(tdCoreIdle);

            if (!tdInputOnly) {
                dispatch_queue_t frames = dispatch_queue_create("terminaldeck.sim-direct.frames",
                    dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
                SEL registerScreen = NSSelectorFromString(@"registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:");
                if (![display respondsToSelector:registerScreen]) return fail(@"this Xcode's screen calls are not the ones known");
                ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(display, registerScreen, [NSUUID UUID], frames,
                    ^{ if (!tdPaused) td_direct_send_frame(tdApp); },
                    ^(id surface, id masked) { (void)masked; handSurface(surface); },
                    ^(id properties) { (void)properties; });
            }
        } @catch (NSException *exception) {
            return fail([@"CoreSimulator threw: " stringByAppendingString:exception.reason ?: exception.name]);
        }

        id surface = display ? td_sim_send0(display, @"framebufferSurface") : nil;
        BOOL hasSurface = surface && CFGetTypeID((__bridge CFTypeRef)surface) == IOSurfaceGetTypeID();
        if (!hasSurface && !tdInputOnly) return fail(@"the simulator's screen has no picture yet");
        // Input only: the size is read once for the ready line (1 x 1 when the screen is not there yet);
        // the surface is never handed over.
        size_t width = hasSurface ? IOSurfaceGetWidth((__bridge IOSurfaceRef)surface) : 1;
        size_t height = hasSurface ? IOSurfaceGetHeight((__bridge IOSurfaceRef)surface) : 1;
        if (!tdInputOnly) handSurface(surface);
        // touch/keys/buttons: what the simulator's own (Indigo) input takes; core: CoreDevice's touchscreen
        // (fingers, keys, every iPhone button) can be reached. The app sends each the way the touchscreen in
        // use now can take, and the engine's way otherwise.
        say([NSString stringWithFormat:@"ready %zu %zu touch=%d keys=%d buttons=%d side=%d core=%d hid=%@",
             width, height, touch, keys, buttons, side, tdCoreAvailable ? 1 : 0,
             readCoreState() ? @"coredevice" : @"indigo"]);

        // The simulator shutting down: say so and leave (its callbacks just stop otherwise).
        dispatch_source_t watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(watch, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(watch, ^{
            @try { if (td_sim_device_state(device) != 3) { say(@"gone"); _exit(0); } } @catch (NSException *exception) { say(@"gone"); _exit(0); }
            readCoreState();   // Device Hub or Xcode starting or ending dtuhidd moves the touchscreen
        });
        dispatch_resume(watch);

        // Input, in order, until the app closes it (it dying closes it too).
        char *line = NULL;
        size_t capacity = 0;
        ssize_t length;
        while ((length = getline(&line, &capacity, stdin)) > 0) {
            if (line[length - 1] == '\n') line[length - 1] = 0;
            if (line[0] == 'Q') break;
            @try { handleInput(line); } @catch (NSException *exception) {
                free(line);
                return fail([@"input threw: " stringByAppendingString:exception.reason ?: exception.name]);
            }
        }
        free(line);
        return 0;
    }
}
