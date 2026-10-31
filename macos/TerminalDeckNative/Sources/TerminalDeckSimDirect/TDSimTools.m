#import "TDSimDirect.h"
#import "TDSimShared.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <libproc.h>
#import <mach/mach.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <string.h>

// Terminal Deck's own reading of an iOS Simulator's screen contents and its rotation (28 Oct 2026: the bundled
// third-party device engine was removed; Asad: "remove it completely and build our setup instead").
//
// What is on screen comes from Apple's accessibility translation, the same path macOS uses to show a simulated app's
// accessibility to the Mac (AccessibilityPlatformTranslation's AXPTranslator, fed by CoreSimulator's
// `-[SimDevice sendAccessibilityRequestAsync:completionQueue:completionHandler:]`). Interfaces read from the frameworks
// on this Mac (Xcode 27.1, macOS 27): the translator takes a "bridge token delegate" that hands it one callback per
// token; each callback turns a translator request into the device's answer. The translator's Mac elements
// (AXPMacPlatformElement, an NSAccessibilityElement) answer the usual AX attributes; every element carries the token in
// its translation object, so its own requests reach the same device.
//
// Rotation is the GraphicsServices "device orientation changed" event (type 50) sent to the simulator's
// PurpleWorkspacePort, the way a device's own orientation change arrives: a 108-byte Mach message, id 123, carrying the
// UIDeviceOrientation (1 portrait, 2 upside down, 3 landscape left, 4 landscape right).
//
// Both run in the helper process only (`--sim-ax`, `--sim-rotate`): private frameworks never load in the app.

static const int64_t TDAXRequestNs = 3 * NSEC_PER_SEC;     // one translator request
static const double TDAXWalkSeconds = 25;                 // a whole tree; past it the tree says truncated
static const int TDAXDepth = 120;

static void emit(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) data = [@"{\"error\":\"The answer could not be written.\"}" dataUsingEncoding:NSUTF8StringEncoding];
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static int refuse(NSString *words) {
    emit(@{@"error": words ?: @"unknown"});
    return 3;
}

/// A refusal that still says which app is in front, so the app can turn that app's accessibility on and ask again.
static int refuseFor(NSString *words, NSDictionary *app) {
    emit(@{@"error": words ?: @"unknown", @"app": app ?: @{}});
    return 3;
}

static id emptyResponse(void) {
    Class response = NSClassFromString(@"AXPTranslatorResponse");
    SEL empty = NSSelectorFromString(@"emptyResponse");
    return response && [response respondsToSelector:empty] ? ((id (*)(id, SEL))objc_msgSend)(response, empty) : nil;
}

/// Answers the translator's requests from one simulator.
@interface TDAXBridge : NSObject
@property (nonatomic, strong) id device;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (atomic) int lateAnswers;
@end

@implementation TDAXBridge
- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
    (void)token;
    __weak TDAXBridge *weakSelf = self;
    return [^id(id request) {
        TDAXBridge *bridge = weakSelf;
        if (!bridge || !request) return emptyResponse();
        __block id answer = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        SEL send = NSSelectorFromString(@"sendAccessibilityRequestAsync:completionQueue:completionHandler:");
        @try {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(bridge.device, send, request, bridge.queue, ^(id response) {
                answer = response;
                dispatch_semaphore_signal(done);
            });
        } @catch (NSException *exception) { return emptyResponse(); }
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, TDAXRequestNs)) != 0) {
            bridge.lateAnswers++;
            return emptyResponse();
        }
        return answer ?: emptyResponse();
    } copy];
}

- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)rect withToken:(NSString *)token {
    (void)token;
    return rect;
}

- (id)accessibilityTranslationRootParentWithToken:(NSString *)token {
    (void)token;
    return nil;
}
@end

/// One walk of the tree: what was read, under a node and time budget.
typedef struct {
    int nodes;
    int maxNodes;
    BOOL truncated;
    CFAbsoluteTime deadline;
    CGRect screen;
} TDAXWalk;

static id attribute(id element, NSString *name) {
    SEL sel = NSSelectorFromString(@"accessibilityAttributeValue:");
    if (![element respondsToSelector:sel]) return nil;
    @try { return ((id (*)(id, SEL, id))objc_msgSend)(element, sel, name); }
    @catch (NSException *exception) { return nil; }
}

static NSString *text(id value) {
    if (!value || value == (id)kCFNull) return nil;
    if ([value isKindOfClass:NSString.class]) return [(NSString *)value length] ? value : nil;
    if ([value isKindOfClass:NSAttributedString.class]) { NSString *s = [(NSAttributedString *)value string]; return s.length ? s : nil; }
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value stringValue];
    return nil;
}

static void tag(id element, NSString *token) {
    id translation = td_sim_send0(element, @"translation");
    SEL set = NSSelectorFromString(@"setBridgeDelegateToken:");
    if ([translation respondsToSelector:set]) ((void (*)(id, SEL, id))objc_msgSend)(translation, set, token);
}

static CGRect frameOf(id element) {
    SEL sel = NSSelectorFromString(@"accessibilityFrame");
    if (![element respondsToSelector:sel]) return CGRectNull;
    @try { return ((CGRect (*)(id, SEL))objc_msgSend)(element, sel); }
    @catch (NSException *exception) { return CGRectNull; }
}

static NSDictionary *normalized(CGRect frame, CGRect screen) {
    if (CGRectIsNull(frame) || screen.size.width <= 0 || screen.size.height <= 0) return nil;
    return @{@"normalized": @{
        @"x": @((frame.origin.x - screen.origin.x) / screen.size.width),
        @"y": @((frame.origin.y - screen.origin.y) / screen.size.height),
        @"width": @(frame.size.width / screen.size.width),
        @"height": @(frame.size.height / screen.size.height)}};
}

/// One element's own fields (no children).
static NSMutableDictionary *fields(id element, NSString *token, CGRect screen, NSString *ref) {
    tag(element, token);
    NSMutableDictionary *node = [NSMutableDictionary dictionaryWithObject:ref forKey:@"ref"];
    NSString *role = nil;
    SEL roleSel = NSSelectorFromString(@"accessibilityRole");
    if ([element respondsToSelector:roleSel]) { @try { role = text(((id (*)(id, SEL))objc_msgSend)(element, roleSel)); } @catch (NSException *e) {} }
    if (role) node[@"role"] = role;
    NSString *label = nil;
    SEL labelSel = NSSelectorFromString(@"accessibilityLabel");
    if ([element respondsToSelector:labelSel]) { @try { label = text(((id (*)(id, SEL))objc_msgSend)(element, labelSel)); } @catch (NSException *e) {} }
    if (label) node[@"label"] = label;
    NSString *value = text(attribute(element, @"AXValue"));
    if (value) node[@"value"] = value;
    NSString *identifier = text(attribute(element, @"AXIdentifier"));
    if (identifier) node[@"identifier"] = identifier;
    NSString *title = text(attribute(element, @"AXTitle"));
    if (title && ![title isEqualToString:label ?: @""]) node[@"title"] = title;
    NSString *placeholder = text(attribute(element, @"AXPlaceholderValue"));
    if (placeholder) node[@"placeholder"] = placeholder;
    id enabled = attribute(element, @"AXEnabled");
    if ([enabled isKindOfClass:NSNumber.class]) node[@"enabled"] = @([enabled boolValue]);
    id focused = attribute(element, @"AXFocused");
    if ([focused isKindOfClass:NSNumber.class] && [focused boolValue]) node[@"focused"] = @YES;
    NSString *subrole = text(attribute(element, @"AXSubrole"));
    if ([subrole isEqualToString:@"AXSecureTextField"]) { node[@"valueRedacted"] = @YES; [node removeObjectForKey:@"value"]; }
    NSDictionary *frame = normalized(frameOf(element), screen);
    if (frame) node[@"frame"] = frame;
    return node;
}

static NSDictionary *walk(id element, NSString *token, TDAXWalk *state, int depth) {
    if (state->nodes >= state->maxNodes || CFAbsoluteTimeGetCurrent() > state->deadline) { state->truncated = YES; return nil; }
    state->nodes++;
    NSMutableDictionary *node = fields(element, token, state->screen, [NSString stringWithFormat:@"e%d", state->nodes]);
    if (depth >= TDAXDepth) { state->truncated = YES; return node; }
    id children = attribute(element, @"AXChildren");
    if ([children isKindOfClass:NSArray.class] && [(NSArray *)children count]) {
        NSMutableArray *kids = [NSMutableArray array];
        for (id child in (NSArray *)children) {
            NSDictionary *read = walk(child, token, state, depth + 1);
            if (read) [kids addObject:read];
            if (state->truncated && state->nodes >= state->maxNodes) break;
        }
        if (kids.count) node[@"children"] = kids;
    }
    return node;
}

/// The app bundle a simulated process runs from: its id and name, read from the app's own Info.plist.
static NSDictionary *appOf(pid_t pid) {
    if (pid <= 0) return @{};
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return @{@"pid": @(pid)};
    NSString *walkPath = @(path);
    while (walkPath.length > 1) {
        if ([walkPath.pathExtension isEqualToString:@"app"]) {
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[walkPath stringByAppendingPathComponent:@"Info.plist"]];
            NSMutableDictionary *app = [NSMutableDictionary dictionaryWithObject:@(pid) forKey:@"pid"];
            if ([info[@"CFBundleIdentifier"] isKindOfClass:NSString.class]) app[@"bundleId"] = info[@"CFBundleIdentifier"];
            NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
            if ([name isKindOfClass:NSString.class]) app[@"name"] = name;
            return app;
        }
        walkPath = walkPath.stringByDeletingLastPathComponent;
    }
    return @{@"pid": @(pid)};
}

static double number(const char *value, BOOL *ok) {
    if (!value || !*value) { *ok = NO; return 0; }
    char *end = NULL;
    double read = strtod(value, &end);
    *ok = end && *end == 0 && read == read;
    return read;
}

int td_sim_ax_run(const char *udidText, const char *verbText, const char *first, const char *second) {
    @autoreleasepool {
        if (!udidText || !verbText) return refuse(@"missing arguments");
        NSString *verb = @(verbText);
        if (![@[@"tree", @"point", @"front"] containsObject:verb]) return refuse(@"unknown request");
        NSString *developer = td_sim_developer_directory();
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW))
            return refuse(@"CoreSimulator could not be loaded");
        if (!dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW))
            return refuse(@"macOS's accessibility translation could not be loaded");
        Class translatorClass = NSClassFromString(@"AXPTranslator");
        Protocol *tokenDelegate = objc_getProtocol("AXPTranslationTokenDelegateHelper");
        if (!translatorClass || !tokenDelegate) return refuse(@"macOS's accessibility translation is not the one known");
        class_addProtocol(TDAXBridge.class, tokenDelegate);

        @try {
            NSString *why = nil;
            id device = td_sim_find_device(@(udidText), developer, &why);
            if (!device) return refuse(why ?: @"simulator not found");
            if (td_sim_device_state(device) != 3) return refuse(@"the simulator is not running");
            SEL send = NSSelectorFromString(@"sendAccessibilityRequestAsync:completionQueue:completionHandler:");
            if (![device respondsToSelector:send]) return refuse(@"this Xcode's simulator does not answer accessibility requests");

            TDAXBridge *bridge = [TDAXBridge new];
            bridge.device = device;
            bridge.queue = dispatch_queue_create("terminaldeck.sim-ax", DISPATCH_QUEUE_SERIAL);
            id translator = ((id (*)(id, SEL))objc_msgSend)(translatorClass, NSSelectorFromString(@"sharedInstance"));
            ((void (*)(id, SEL, id))objc_msgSend)(translator, NSSelectorFromString(@"setBridgeTokenDelegate:"), bridge);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(translator, NSSelectorFromString(@"setSupportsDelegateTokens:"), YES);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(translator, NSSelectorFromString(@"setAccessibilityEnabled:"), YES);
            NSString *token = NSUUID.UUID.UUIDString;

            SEL frontSel = NSSelectorFromString(@"frontmostApplicationWithDisplayId:bridgeDelegateToken:");
            id front = ((id (*)(id, SEL, uint32_t, id))objc_msgSend)(translator, frontSel, 0, token);
            if (!front) return refuse(@"The simulator did not say which app is in front.");
            ((void (*)(id, SEL, id))objc_msgSend)(front, NSSelectorFromString(@"setBridgeDelegateToken:"), token);
            pid_t pid = ((int (*)(id, SEL))objc_msgSend)(front, NSSelectorFromString(@"pid"));
            NSDictionary *app = appOf(pid);
            if ([verb isEqualToString:@"front"]) { emit(@{@"app": app}); return 0; }

            id root = ((id (*)(id, SEL, id))objc_msgSend)(translator, NSSelectorFromString(@"macPlatformElementFromTranslation:"), front);
            if (!root) return refuseFor(@"The app in front gave no accessibility element.", app);
            tag(root, token);
            CGRect screen = frameOf(root);
            // An app that is still starting has no size for a moment; one whose accessibility is off has none at all.
            for (int wait = 0; wait < 3 && (CGRectIsNull(screen) || screen.size.width <= 0 || screen.size.height <= 0); wait++) {
                usleep(300 * 1000);
                screen = frameOf(root);
            }
            if (CGRectIsNull(screen) || screen.size.width <= 0 || screen.size.height <= 0)
                return refuseFor(@"The app in front does not describe itself yet (its accessibility is off).", app);
            NSDictionary *screenSize = @{@"x": @(screen.origin.x), @"y": @(screen.origin.y), @"width": @(screen.size.width), @"height": @(screen.size.height)};

            if ([verb isEqualToString:@"point"]) {
                BOOL okX = NO, okY = NO;
                double x = number(first, &okX), y = number(second, &okY);
                if (!okX || !okY || x < 0 || x > 1 || y < 0 || y > 1) return refuse(@"a point is x and y from 0 to 1");
                CGPoint at = CGPointMake(screen.origin.x + x * screen.size.width, screen.origin.y + y * screen.size.height);
                SEL pointSel = NSSelectorFromString(@"objectAtPoint:displayId:bridgeDelegateToken:");
                id hit = ((id (*)(id, SEL, CGPoint, uint32_t, id))objc_msgSend)(translator, pointSel, at, 0, token);
                if (!hit) { emit(@{@"element": [NSNull null], @"app": app, @"screen": screenSize}); return 0; }
                ((void (*)(id, SEL, id))objc_msgSend)(hit, NSSelectorFromString(@"setBridgeDelegateToken:"), token);
                id element = ((id (*)(id, SEL, id))objc_msgSend)(translator, NSSelectorFromString(@"macPlatformElementFromTranslation:"), hit);
                NSDictionary *node = element ? fields(element, token, screen, @"e1") : (id)[NSNull null];
                emit(@{@"element": node, @"app": app, @"screen": screenSize});
                return 0;
            }

            BOOL okMax = NO;
            double wanted = number(first, &okMax);
            TDAXWalk state = {.nodes = 0, .maxNodes = okMax && wanted >= 1 && wanted <= 5000 ? (int)wanted : 1500, .truncated = NO,
                              .deadline = CFAbsoluteTimeGetCurrent() + TDAXWalkSeconds, .screen = screen};
            NSDictionary *tree = walk(root, token, &state, 0);
            if (!tree) return refuse(@"The screen did not describe itself.");
            BOOL thin = state.nodes <= 1 || [tree[@"children"] count] == 0;
            NSString *when = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
            emit(@{@"source": @"ios-accessibility", @"capturedAt": when, @"root": tree, @"app": app, @"screen": screenSize,
                   @"stats": @{@"nodeCount": @(state.nodes), @"truncated": @(state.truncated), @"quality": thin ? @"degraded" : @"full",
                               @"lateAnswers": @(bridge.lateAnswers)}});
            return 0;
        } @catch (NSException *exception) {
            return refuse([@"the accessibility translation threw: " stringByAppendingString:exception.reason ?: exception.name]);
        }
    }
}

/// UIDeviceOrientation for the names the app uses, 0 for anything else.
static uint32_t orientationNumber(const char *name) {
    if (!name) return 0;
    if (strcmp(name, "portrait") == 0) return 1;
    if (strcmp(name, "portrait-upside-down") == 0) return 2;
    if (strcmp(name, "landscape-left") == 0) return 3;
    if (strcmp(name, "landscape-right") == 0) return 4;
    return 0;
}

int td_sim_rotate_run(const char *udidText, const char *orientationText) {
    @autoreleasepool {
        uint32_t orientation = orientationNumber(orientationText);
        if (!udidText || orientation == 0) { fprintf(stdout, "error an orientation is portrait, portrait-upside-down, landscape-left or landscape-right\n"); return 64; }
        NSString *developer = td_sim_developer_directory();
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW)) {
            fprintf(stdout, "error CoreSimulator could not be loaded\n"); return 3;
        }
        @try {
            NSString *why = nil;
            id device = td_sim_find_device(@(udidText), developer, &why);
            if (!device) { fprintf(stdout, "error %s\n", (why ?: @"simulator not found").UTF8String); return 3; }
            if (td_sim_device_state(device) != 3) { fprintf(stdout, "error the simulator is not running\n"); return 3; }
            SEL lookup = NSSelectorFromString(@"lookup:error:");
            if (![device respondsToSelector:lookup]) { fprintf(stdout, "error this Xcode's simulator has no port lookup\n"); return 3; }
            NSError *error = nil;
            mach_port_t port = ((mach_port_t (*)(id, SEL, id, NSError **))objc_msgSend)(device, lookup, @"PurpleWorkspacePort", &error);
            if (port == MACH_PORT_NULL) { fprintf(stdout, "error the simulator's workspace port was not found\n"); return 3; }
            // The GraphicsServices event, little-endian: Mach header (bits copy-send, size 108, id 123), the event type
            // (50, device orientation changed, with its 0x20000 flag) at 0x18, the event's data size (4) at 0x48 and the
            // orientation itself at 0x4C. Everything else stays zero.
            uint8_t message[112] = {0};
            mach_msg_header_t *header = (mach_msg_header_t *)message;
            header->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
            header->msgh_size = 108;
            header->msgh_remote_port = port;
            header->msgh_local_port = MACH_PORT_NULL;
            header->msgh_id = 123;
            uint32_t type = 50 | 0x20000, size = 4;
            memcpy(message + 0x18, &type, 4);
            memcpy(message + 0x48, &size, 4);
            memcpy(message + 0x4C, &orientation, 4);
            kern_return_t sent = mach_msg_send(header);
            if (sent != KERN_SUCCESS) { fprintf(stdout, "error the simulator did not take the rotation (%d)\n", sent); return 3; }
            fprintf(stdout, "ok %s\n", orientationText);
            fflush(stdout);
            return 0;
        } @catch (NSException *exception) {
            fprintf(stdout, "error CoreSimulator threw: %s\n", (exception.reason ?: exception.name).UTF8String);
            return 3;
        }
    }
}
