#import <UIKit/UIKit.h>
#import <objc/message.h>

// Runtime-only integration. PlayTools keeps ownership of its screen/input hooks.
static void PlayCoverRuntimeInit(NSBundle *guest) {
    NSDictionary *features = [NSDictionary dictionaryWithContentsOfFile:
        [guest.bundlePath stringByAppendingPathComponent:@"RunnerFeatures.plist"]];
    CGSize size = CGSizeMake([features[@"playCoverWidth"] doubleValue],
                             [features[@"playCoverHeight"] doubleValue]);
    BOOL resizable = [features[@"playCoverResizable"] boolValue];
    NSString *iconPath = [guest.bundlePath stringByAppendingPathComponent:@".playcover-icon.tiff"];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeKeyNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        UIWindow *window = note.object;
        if (![window isKindOfClass:UIWindow.class]) { return; }
        if (size.width > 0 && size.height > 0 && !resizable) {
            // Catalyst otherwise lets the native window grow independently of
            // PlayTools' fixed guest viewport, leaving a blank strip after resize.
            window.windowScene.sizeRestrictions.minimumSize = size;
            window.windowScene.sizeRestrictions.maximumSize = size;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            id application = ((id (*)(id, SEL))objc_msgSend)(
                NSClassFromString(@"NSApplication"), NSSelectorFromString(@"sharedApplication"));
            id image = ((id (*)(id, SEL, id))objc_msgSend)(
                [NSClassFromString(@"NSImage") alloc], NSSelectorFromString(@"initWithContentsOfFile:"), iconPath);
            if (image) {
                ((void (*)(id, SEL, id))objc_msgSend)(application,
                    NSSelectorFromString(@"setApplicationIconImage:"), image);
            }
        });
    }];
}
