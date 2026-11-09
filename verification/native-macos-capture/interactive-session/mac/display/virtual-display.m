// Copyright 2022 The Chromium Authors
// Adapted from ui/display/mac/test/virtual_display_util_mac.mm (BSD-3-Clause).
// See CHROMIUM-LICENSE.md and provenance.json. The Apple API is private.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <signal.h>
#include <unistd.h>

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property(strong, nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong, nonatomic) id queue;
@property(copy, nonatomic) id terminationHandler;
@end
@interface CGVirtualDisplayMode : NSObject
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(strong, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI, rotation;
@end

static volatile sig_atomic_t stopping = 0;
static void Stop(int signalNumber) { (void)signalNumber; stopping = 1; }
static void Emit(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2 || strcmp(argv[1], "create") != 0) {
            fputs("Usage: virtual-display create\n", stderr); return 64;
        }
        // Keep this process as a direct background child of a live job shell.
        const pid_t parentPID = getppid();
        if (parentPID <= 1) { Emit(@{@"status": @"failed", @"error": @"missing_owner_parent"}); return 2; }
        signal(SIGTERM, Stop); signal(SIGINT, Stop); signal(SIGHUP, Stop);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        if (!displayClass || !descriptorClass || !modeClass || !settingsClass) {
            Emit(@{@"status": @"failed", @"error": @"virtual_display_api_unavailable"}); return 2;
        }
        __block CGVirtualDisplay *display = nil; // Strong reference holds the real display.
        __block BOOL attempted = NO;
        __block BOOL failed = NO;
        // Create after the main run loop begins; do not change modes or mirror displays.
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
                descriptor.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
                descriptor.name = @"Native presentation HiDPI";
                descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
                descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
                descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
                descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
                descriptor.maxPixelsWide = 3840; descriptor.maxPixelsHigh = 2160;
                descriptor.sizeInMillimeters = CGSizeMake(25.4 * 3840 / 218, 25.4 * 2160 / 218);
                unsigned int serial = arc4random_uniform(0x7ffffffe) + 1;
                descriptor.serialNum = serial; descriptor.serialNumber = serial;
                descriptor.vendorID = 505; descriptor.productID = 0;
                descriptor.terminationHandler = nil;
                display = [[displayClass alloc] initWithDescriptor:descriptor];
                CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
                settings.hiDPI = 1; settings.rotation = 0;
                settings.modes = @[[[modeClass alloc] initWithWidth:1920 height:1080 refreshRate:60]];
                if (!display || ![display applySettings:settings] || display.displayID == 0) {
                    display = nil; failed = YES;
                    Emit(@{@"status": @"failed", @"error": @"virtual_display_creation_failed"});
                } else {
                    // This is a requested mode, NOT proof of actual 4K or readiness.
                    Emit(@{@"schema_version": @1, @"status": @"created_unverified",
                           @"helper_pid": @(getpid()), @"display_id": @(display.displayID),
                           @"requested_pixels": @[@3840, @2160], @"requested_points": @[@1920, @1080],
                           @"requested_scale": @2, @"maximum_lifetime_seconds": @900});
                }
            } @catch (NSException *exception) {
                (void)exception; display = nil; failed = YES;
                Emit(@{@"status": @"failed", @"error": @"virtual_display_api_rejected"});
            }
            attempted = YES;
        });
        const CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 900;
        while (!stopping && !failed && getppid() == parentPID && kill(parentPID, 0) == 0 && CFAbsoluteTimeGetCurrent() < deadline) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
        }
        BOOL created = attempted && display != nil;
        display = nil; // Deallocate only our CGVirtualDisplay; no global display reset.
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        return created ? 0 : 2;
    }
}
