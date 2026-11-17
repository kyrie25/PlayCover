#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Dock labels use LaunchServices metadata, independently of NSProcessInfo and icons.
static void PlayCoverSetApplicationName(NSString *name) {
    CFBundleRef services = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.LaunchServices"));
    if (!services) { return; }
    CFTypeRef (*getASN)(void) = (void *)CFBundleGetFunctionPointerForName(
        services, CFSTR("_LSGetCurrentApplicationASN"));
    OSStatus (*setInformation)(int, CFTypeRef, CFStringRef, CFStringRef, CFDictionaryRef *) =
        (void *)CFBundleGetFunctionPointerForName(services, CFSTR("_LSSetApplicationInformationItem"));
    if (name.length && getASN && setInformation) {
        CFTypeRef asn = getASN();
        if (asn) {
            OSStatus status = setInformation(-2, asn, CFSTR("LSDisplayName"),
                                            (__bridge CFStringRef)name, NULL);
            if (status) { NSLog(@"[PlayCover] Could not update Dock name (%d)", (int)status); }
        }
    }
}

// Catalyst repeatedly restores its compatibility viewport during native layout.
// Keep that viewport equal to PlayTools' fixed surface, with aspect fitting.
static void PlayCoverConfigureSceneView(CGSize size) {
    Class sceneClass = NSClassFromString(@"UINSSceneView");
    SEL sizeSelector = NSSelectorFromString(@"setSceneSize:");
    SEL scaleSelector = NSSelectorFromString(@"setFixedSceneToSceneViewScaleFactor:");
    Method sizeMethod = class_getInstanceMethod(sceneClass, sizeSelector);
    Method scaleMethod = class_getInstanceMethod(sceneClass, scaleSelector);
    if (!sizeMethod || !scaleMethod) { return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        IMP setSize = method_getImplementation(sizeMethod);
        IMP setScale = method_getImplementation(scaleMethod);
        method_setImplementation(sizeMethod, imp_implementationWithBlock(^(id view, CGSize requested) {
            ((void (*)(id, SEL, CGSize))setSize)(view, sizeSelector, size);
        }));
        method_setImplementation(scaleMethod, imp_implementationWithBlock(^(id view, double requested) {
            CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(view, @selector(bounds));
            double fit = MIN(bounds.size.width / size.width, bounds.size.height / size.height);
            ((void (*)(id, SEL, double))setScale)(view, scaleSelector, fit > 0 ? fit : (requested > 0 ? requested : 1));
        }));
    });
}

static void PlayCoverConfigureFullScreen(id window, CGSize size) {
    id delegate = [window valueForKey:@"delegate"];
    if (!delegate) { return; }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SEL selector = NSSelectorFromString(@"window:willUseFullScreenContentSize:");
        Class controller = object_getClass(delegate);
        IMP implementation = imp_implementationWithBlock(^CGSize(id object, id nativeWindow, CGSize proposed) {
            double scale = MIN(proposed.width / size.width, proposed.height / size.height);
            return CGSizeMake(size.width * scale, size.height * scale);
        });
        if (!class_addMethod(controller, selector, implementation, "{CGSize=dd}@:@{CGSize=dd}")) {
            method_setImplementation(class_getInstanceMethod(controller, selector), implementation);
        }
    });
}

static void PlayCoverScaleGameWindows(id application, CGSize size, BOOL resizable) {
    if (size.width <= 0 || size.height <= 0 || resizable) { return; }
    PlayCoverConfigureSceneView(size);
    for (id nativeWindow in [application valueForKey:@"windows"]) {
        id content = [nativeWindow valueForKey:@"contentView"];
        SEL sceneSelector = NSSelectorFromString(@"sceneView");
        if (![content respondsToSelector:sceneSelector]) { continue; }
        PlayCoverConfigureFullScreen(nativeWindow, size);
        id sceneView = ((id (*)(id, SEL))objc_msgSend)(content, sceneSelector);
        SEL scaleSelector = NSSelectorFromString(@"setFixedSceneToSceneViewScaleFactor:");
        SEL sizeSelector = NSSelectorFromString(@"setSceneCurrentSize:");
        if ([sceneView respondsToSelector:scaleSelector] &&
            [sceneView respondsToSelector:NSSelectorFromString(@"setSceneSize:")] &&
            [content respondsToSelector:sizeSelector] &&
            [content respondsToSelector:NSSelectorFromString(@"setSceneToSceneViewScaleForLayout:")] &&
            [content respondsToSelector:NSSelectorFromString(@"setSceneViewPinned:")]) {
            // Catalyst derives its scene size from a fixed 0.77 scale. PlayTools
            // keeps the guest surface fixed, so fit that surface to the window.
            CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(content, @selector(bounds));
            if (bounds.size.width <= 0 || bounds.size.height <= 0) { continue; }
            double scale = MIN(bounds.size.width / size.width, bounds.size.height / size.height);
            ((void (*)(id, SEL, CGSize))objc_msgSend)(content, sizeSelector, size);
            ((void (*)(id, SEL, double))objc_msgSend)(content,
                NSSelectorFromString(@"setSceneToSceneViewScaleForLayout:"), scale);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(content, NSSelectorFromString(@"setSceneViewPinned:"), YES);
            ((void (*)(id, SEL, double))objc_msgSend)(sceneView, scaleSelector, scale);
            ((void (*)(id, SEL, CGSize))objc_msgSend)(sceneView, NSSelectorFromString(@"setSceneSize:"), size);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(sceneView, NSSelectorFromString(@"setNeedsLayout:"), YES);
            ((void (*)(id, SEL, CGSize))objc_msgSend)(nativeWindow,
                NSSelectorFromString(@"setContentAspectRatio:"), size);
        }
    }
}

// Runtime-only integration. PlayTools keeps ownership of its screen/input hooks.
static void PlayCoverRuntimeInit(NSBundle *guest) {
    NSDictionary *features = [NSDictionary dictionaryWithContentsOfFile:
        [guest.bundlePath stringByAppendingPathComponent:@"RunnerFeatures.plist"]];
    CGSize size = CGSizeMake([features[@"playCoverWidth"] doubleValue],
                             [features[@"playCoverHeight"] doubleValue]);
    BOOL resizable = [features[@"playCoverResizable"] boolValue];
    NSString *name = features[@"playCoverDisplayName"];
    if (!name.length) { name = [guest objectForInfoDictionaryKey:@"CFBundleDisplayName"]; }
    if (!name.length) { name = [guest objectForInfoDictionaryKey:@"CFBundleName"]; }
    // Set the name before AppKit first registers the application's Dock tile.
    PlayCoverSetApplicationName(name);
    NSString *iconPath = [guest.bundlePath stringByAppendingPathComponent:@".playcover-icon.tiff"];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *note) {
        UIWindow *window = note.object;
        if (![window isKindOfClass:UIWindow.class]) { return; }
        window.windowScene.sizeRestrictions.minimumSize = CGSizeZero;
        window.windowScene.sizeRestrictions.maximumSize = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);
    }];
    for (NSString *event in @[@"NSWindowDidBecomeKeyNotification", @"NSWindowDidResizeNotification",
                             @"NSWindowDidEnterFullScreenNotification", @"NSWindowDidExitFullScreenNotification",
                             @"NSApplicationDidFinishLaunchingNotification"]) {
        [center addObserverForName:event object:nil queue:NSOperationQueue.mainQueue
                       usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                id application = ((id (*)(id, SEL))objc_msgSend)(
                    NSClassFromString(@"NSApplication"), NSSelectorFromString(@"sharedApplication"));
                PlayCoverScaleGameWindows(application, size, resizable);
                if ([note.name isEqualToString:@"NSWindowDidResizeNotification"]) { return; }
                PlayCoverSetApplicationName(name);
                id image = ((id (*)(id, SEL, id))objc_msgSend)(
                    [NSClassFromString(@"NSImage") alloc], NSSelectorFromString(@"initWithContentsOfFile:"), iconPath);
                if (image) {
                    ((void (*)(id, SEL, id))objc_msgSend)(application,
                        NSSelectorFromString(@"setApplicationIconImage:"), image);
                }
            });
        }];
    }
}
