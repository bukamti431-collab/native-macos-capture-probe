// Native observation and explicit Telegram-only window placement. No screenshots/UI drawing.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include <unistd.h>

static NSArray *NativeRectArray(CGRect r) { return @[@(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height)]; }
static int Emit(NSDictionary *value, int code) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); }
    return code;
}
static int Fail(NSString *reason) { return Emit(@{@"status": @"failed", @"error": reason}, 2); }
static NSScreen *Screen(CGDirectDisplayID displayID) {
    for (NSScreen *screen in NSScreen.screens) {
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) return screen;
    }
    return nil;
}
static BOOL ParseID(const char *value, uint32_t *result) {
    if (!value || !*value) return NO;
    for (const char *p = value; *p; p++) if (*p < '0' || *p > '9') return NO;
    char *end = NULL; unsigned long long number = strtoull(value, &end, 10);
    if (*end || number == 0 || number > UINT32_MAX) return NO;
    *result = (uint32_t)number; return YES;
}
static NSArray *Windows(pid_t pid) {
    NSArray *all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *window in all) {
        CGRect bounds = CGRectZero;
        if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue] == pid && [window[(__bridge NSString *)kCGWindowLayer] intValue] == 0 &&
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds) &&
            bounds.size.width >= 200 && bounds.size.height >= 160) [result addObject:window];
    }
    return result;
}
static CGRect WindowBounds(NSDictionary *window) {
    CGRect bounds = CGRectZero;
    CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)window[(__bridge NSString *)kCGWindowBounds], &bounds);
    return bounds;
}
static BOOL Near(CGRect a, CGRect b, double tolerance) {
    return fabs(a.origin.x - b.origin.x) <= tolerance && fabs(a.origin.y - b.origin.y) <= tolerance &&
        fabs(a.size.width - b.size.width) <= tolerance && fabs(a.size.height - b.size.height) <= tolerance;
}
static BOOL AXBounds(AXUIElementRef window, CGRect *bounds) {
    CFTypeRef position = NULL, size = NULL;
    AXError p = AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &position);
    AXError s = AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &size);
    CGPoint point; CGSize dimensions;
    BOOL valid = p == kAXErrorSuccess && s == kAXErrorSuccess && position && size &&
        CFGetTypeID(position) == AXValueGetTypeID() && CFGetTypeID(size) == AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)position, kAXValueCGPointType, &point) &&
        AXValueGetValue((AXValueRef)size, kAXValueCGSizeType, &dimensions);
    if (valid) *bounds = (CGRect){point, dimensions};
    if (position) CFRelease(position); if (size) CFRelease(size);
    return valid;
}
static int Probe(void) {
    CGDirectDisplayID ids[32]; uint32_t count = 0;
    if (CGGetOnlineDisplayList(32, ids, &count) != kCGErrorSuccess) return Fail(@"display_list_unavailable");
    NSMutableArray *displays = [NSMutableArray array];
    for (uint32_t index = 0; index < count; index++) {
        CGDirectDisplayID displayID = ids[index];
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(displayID);
        NSScreen *screen = Screen(displayID);
        NSMutableDictionary *item = [@{
            @"display_id": @(displayID), @"model_number": @(CGDisplayModelNumber(displayID)),
            @"vendor_number": @(CGDisplayVendorNumber(displayID)),
            @"online": @(CGDisplayIsOnline(displayID) != 0), @"active": @(CGDisplayIsActive(displayID) != 0),
            @"mirrored": @(CGDisplayIsInMirrorSet(displayID) != 0),
            @"bounds_points": NativeRectArray(CGDisplayBounds(displayID)),
            @"framebuffer_pixels": @[@(CGDisplayPixelsWide(displayID)), @(CGDisplayPixelsHigh(displayID))]
        } mutableCopy];
        if (mode) {
            item[@"mode_points"] = @[@(CGDisplayModeGetWidth(mode)), @(CGDisplayModeGetHeight(mode))];
            item[@"mode_pixels"] = @[@(CGDisplayModeGetPixelWidth(mode)), @(CGDisplayModeGetPixelHeight(mode))];
            item[@"refresh_hz"] = @(CGDisplayModeGetRefreshRate(mode)); CFRelease(mode);
        }
        if (screen) {
            item[@"screen_frame_points"] = NativeRectArray(NSRectToCGRect(screen.frame));
            item[@"visible_frame_points"] = NativeRectArray(NSRectToCGRect(screen.visibleFrame));
            item[@"backing_scale_factor"] = @(screen.backingScaleFactor);
        }
        [displays addObject:item];
    }
    return Emit(@{@"schema_version": @1, @"status": @"observed", @"probe_pid": @(getpid()),
        @"screen_capture_preflight": @(CGPreflightScreenCaptureAccess()),
        @"accessibility_trusted": @(AXIsProcessTrusted()), @"displays": displays}, 0);
}

static int Place(int argc, const char *argv[]) {
    uint32_t displayID = 0, windowID = 0;
    BOOL largest = argc == 5 && strcmp(argv[4], "--largest") == 0;
    BOOL explicitID = argc == 6 && strcmp(argv[4], "--window-id") == 0 && ParseID(argv[5], &windowID);
    if ((!largest && !explicitID) || !ParseID(argv[3], &displayID)) return Fail(@"invalid_placement_arguments");
    NSString *supplied = [NSString stringWithUTF8String:argv[2]];
    if (!supplied.isAbsolutePath || ![supplied.pathExtension isEqualToString:@"app"]) return Fail(@"expected_absolute_app_path");
    NSString *expected = supplied.stringByResolvingSymlinksInPath;
    NSMutableArray *apps = [NSMutableArray array];
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"ru.keepcoder.Telegram"]) {
        if ([app.bundleURL.path.stringByResolvingSymlinksInPath isEqualToString:expected]) [apps addObject:app];
    }
    if (apps.count != 1) return Fail(@"expected_telegram_process_not_unique");
    NSRunningApplication *app = apps.firstObject;
    NSScreen *screen = Screen(displayID), *main = Screen(CGMainDisplayID());
    if (!screen || !main || !CGDisplayIsOnline(displayID) || !CGDisplayIsActive(displayID) || CGDisplayIsInMirrorSet(displayID)) return Fail(@"target_display_unavailable");
    if (!AXIsProcessTrusted()) return Fail(@"accessibility_permission_missing"); // Never prompt or alter TCC.
    NSArray *candidates = Windows(app.processIdentifier);
    NSDictionary *chosen = nil; double largestArea = 0; BOOL tied = NO;
    for (NSDictionary *window in candidates) {
        if (explicitID && [window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue] == windowID) chosen = window;
        if (largest) {
            CGRect bounds = WindowBounds(window); double area = bounds.size.width * bounds.size.height;
            if (area > largestArea) { chosen = window; largestArea = area; tied = NO; }
            else if (area == largestArea) tied = YES;
        }
    }
    if (!chosen || tied) return Fail(@"target_window_not_unique");
    windowID = [chosen[(__bridge NSString *)kCGWindowNumber] unsignedIntValue];
    CGRect before = WindowBounds(chosen);
    AXUIElementRef axApp = AXUIElementCreateApplication(app.processIdentifier);
    CFTypeRef rawWindows = NULL;
    AXError copied = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute, &rawWindows);
    CFRelease(axApp);
    if (copied != kAXErrorSuccess || !rawWindows || CFGetTypeID(rawWindows) != CFArrayGetTypeID()) {
        if (rawWindows) CFRelease(rawWindows); return Fail(@"telegram_ax_windows_unavailable");
    }
    AXUIElementRef axWindow = NULL; NSUInteger matches = 0;
    for (id value in (__bridge NSArray *)rawWindows) {
        CGRect bounds;
        if (CFGetTypeID((__bridge CFTypeRef)value) == AXUIElementGetTypeID() && AXBounds((__bridge AXUIElementRef)value, &bounds) && Near(bounds, before, 2)) {
            axWindow = (__bridge AXUIElementRef)value; matches++;
        }
    }
    if (matches != 1) { CFRelease(rawWindows); return Fail(@"telegram_ax_window_ambiguous"); }
    Boolean movable = false, resizable = false;
    AXUIElementIsAttributeSettable(axWindow, kAXPositionAttribute, &movable);
    AXUIElementIsAttributeSettable(axWindow, kAXSizeAttribute, &resizable);
    if (!movable || !resizable) { CFRelease(rawWindows); return Fail(@"telegram_window_not_resizable"); }
    // AppKit uses bottom-left screen coordinates; AX and CGWindow use top-left.
    NSRect visible = screen.visibleFrame;
    CGRect requested = CGRectMake(visible.origin.x + 8, NSMaxY(main.frame) - NSMaxY(visible) + 8,
                                   visible.size.width - 16, visible.size.height - 16);
    if (requested.size.width < 400 || requested.size.height < 400) { CFRelease(rawWindows); return Fail(@"target_display_too_small"); }
    CGPoint point = requested.origin; CGSize size = requested.size;
    AXValueRef positionValue = AXValueCreate(kAXValueCGPointType, &point), sizeValue = AXValueCreate(kAXValueCGSizeType, &size);
    AXError moved = AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute, positionValue);
    AXError resized = moved == kAXErrorSuccess ? AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute, sizeValue) : moved;
    AXError movedAgain = resized == kAXErrorSuccess ? AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute, positionValue) : resized;
    CFRelease(positionValue); CFRelease(sizeValue); CFRelease(rawWindows);
    CGRect actual = CGRectZero; BOOL verified = NO;
    if (movedAgain == kAXErrorSuccess) {
        for (int attempt = 0; attempt < 20 && !verified; attempt++) {
            for (NSDictionary *window in Windows(app.processIdentifier)) {
                if ([window[(__bridge NSString *)kCGWindowNumber] unsignedIntValue] == windowID) {
                    actual = WindowBounds(window); verified = Near(actual, requested, 8);
                }
            }
            if (!verified) [NSThread sleepForTimeInterval:0.1];
        }
    }
    return Emit(@{@"status": verified ? @"placed" : @"placement_unverified", @"target_pid": @(app.processIdentifier),
        @"window_id": @(windowID), @"display_id": @(displayID), @"selector": largest ? @"explicit_largest" : @"explicit_window_id",
        @"before_bounds_points": NativeRectArray(before), @"requested_bounds_points": NativeRectArray(requested), @"actual_bounds_points": NativeRectArray(actual),
        @"verified": @(verified)}, verified ? 0 : 2);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (argc == 2 && strcmp(argv[1], "probe") == 0) return Probe();
        if (argc >= 5 && strcmp(argv[1], "place-telegram") == 0) return Place(argc, argv);
        fputs("Usage: native-display probe | place-telegram /absolute/Telegram.app DISPLAY_ID --largest | --window-id WINDOW_ID\n", stderr);
        return 64;
    }
}
