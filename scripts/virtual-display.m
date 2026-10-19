// An invisible second display for the isolated tests: the app's windows go there while the
// person keeps working on their own screen. It touches the main display only at the
// bottom-right corner, so the mouse does not wander into it. Lives until killed.
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics scripts/virtual-display.m -o .build/virtual-display
// Uses CoreGraphics' CGVirtualDisplay (private, the one display tools use); test-only.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain) dispatch_queue_t queue;
@property (retain) NSString *name;
@property unsigned int maxPixelsWide, maxPixelsHigh, productID, vendorID, serialNum;
@property CGSize sizeInMillimeters;
@property (copy) void (^terminationHandler)(id, id);
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property (retain) NSArray *modes;
@property unsigned int hiDPI;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly) unsigned int displayID;
@end

static void stop(int sig) { _exit(0); }

int main(void) {
    @autoreleasepool {
        signal(SIGTERM, stop);
        signal(SIGINT, stop);
        CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
        d.queue = dispatch_get_main_queue();
        d.name = @"Screenshots Tests";
        d.maxPixelsWide = 2880;
        d.maxPixelsHigh = 1800;
        d.sizeInMillimeters = CGSizeMake(330, 206);
        d.productID = 0x5343; d.vendorID = 0x5343; d.serialNum = 1;
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
        s.hiDPI = 1;
        s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:1440 height:900 refreshRate:60]];
        if (!display || ![display applySettings:s]) { fprintf(stderr, "no virtual display\n"); return 1; }
        CGDirectDisplayID id = display.displayID;
        // Wait for it to come up, then park it diagonally off the main display's corner.
        for (int i = 0; i < 50 && CGDisplayPixelsWide(id) == 0; i++) usleep(100000);
        CGDisplayConfigRef cfg;
        if (CGBeginDisplayConfiguration(&cfg) == kCGErrorSuccess) {
            CGRect main = CGDisplayBounds(CGMainDisplayID());
            CGConfigureDisplayOrigin(cfg, id, (int32_t)CGRectGetMaxX(main), (int32_t)CGRectGetMaxY(main));
            CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
        }
        printf("%u\n", id);
        fflush(stdout);
        // Never outlive the test: gone when the script that started it is gone, and after
        // 15 minutes whatever happens.
        pid_t parent = getppid();
        dispatch_source_t watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(watch, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
        __block int ticks = 0;
        dispatch_source_set_event_handler(watch, ^{
            if (getppid() != parent || kill(parent, 0) != 0 || ++ticks > 1800) _exit(0);
        });
        dispatch_resume(watch);
        CFRunLoopRun();
        (void)display;
    }
    return 0;
}
