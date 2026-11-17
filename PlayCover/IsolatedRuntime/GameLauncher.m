#import <AppKit/AppKit.h>

// Indexed game entries always return to PlayCover for settings and preparation.
int main(void) {
    @autoreleasepool {
        NSBundle *bundle = NSBundle.mainBundle;
        NSString *identifier = [bundle objectForInfoDictionaryKey:@"PlayCoverGuestIdentifier"];
        NSString *hostPath = [bundle objectForInfoDictionaryKey:@"PlayCoverHostPath"];
        if (!identifier.length || !hostPath.length) { return 1; }
        NSURL *host = [NSURL fileURLWithPath:hostPath];
        if (![NSFileManager.defaultManager fileExistsAtPath:host.path]) {
            host = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"io.playcover.PlayCover"];
        }
        if (!host) { return 1; }
        NSURLComponents *url = [NSURLComponents new];
        url.scheme = @"playcoverapp";
        url.host = @"app";
        url.queryItems = @[[NSURLQueryItem queryItemWithName:@"action" value:@"open"],
                           [NSURLQueryItem queryItemWithName:@"bundleid" value:identifier]];
        NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
        [NSWorkspace.sharedWorkspace openURLs:@[url.URL] withApplicationAtURL:host configuration:configuration
                           completionHandler:^(NSRunningApplication *application, NSError *error) {
            exit(error ? 1 : 0);
        }];
    }
    dispatch_main();
}
