//
//  main.m
//  BaseiOSApp
//
//  Created by Venti on 22/2/26.
//

#import <UIKit/UIKit.h>
#import "LCDyld.h"
#import "hooks.h"
#import "../../PlayCoverRuntime.h"
#import "utils.h"
#import "Keychain.h"
#import <dlfcn.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/file.h>
#import "GroupContainer.h"
#import "PlayCoverIncoming.h"

@import MachO;

// NSProcessInfo's private arguments setter, for giving the guest a clean argv.
@interface NSProcessInfo (PrivateArguments)
- (void)setArguments:(NSArray<NSString *> *)arguments;
@end

uint32_t appMainImageIndex = 0;
void* appExecutableHandle;

static void *getAppEntryPoint(void *handle) {
    uint64_t entryoff = 0;
    const struct mach_header_64 *header = (struct mach_header_64 *)getGuestAppHeader();
    uint8_t *imageHeaderPtr = (uint8_t*)header + sizeof(struct mach_header_64);
    struct load_command *command = (struct load_command *)imageHeaderPtr;
    for(int i = 0; i < header->ncmds; ++i) {
        if(command->cmd == LC_MAIN) {
            struct entry_point_command ucmd = *(struct entry_point_command *)imageHeaderPtr;
            entryoff = ucmd.entryoff;
            break;
        }
        imageHeaderPtr += command->cmdsize;
        command = (struct load_command *)imageHeaderPtr;
    }
    assert(entryoff > 0);
    return (void *)header + entryoff;
}

static NSString *appToLaunchFromArgv(int argc, char *argv[]) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--launch-app") == 0) {
            return [NSString stringWithUTF8String:argv[i + 1]];
        }
    }
    return nil;
}

// Host-assigned keychain slot (--keychain-slot); -1 when missing or invalid.
static int keychainSlotFromArgv(int argc, char *argv[]) {
    for (int i = 1; i + 1 < argc; i++) {
        if (strcmp(argv[i], "--keychain-slot") == 0) {
            int slot = atoi(argv[i + 1]);
            return (slot >= 0 && slot <= 127) ? slot : -1;
        }
    }
    return -1;
}

// Flock held for the process lifetime; the host probes it (non-blocking)
// before migrating a guest. Kernel-released on process death.
//
// Returns 0 on success, 2 for an already-running guest, or 1 for another failure.
static int acquireGuestLock(NSString *guestHomeDir) {
    int home = PCOpenRealDirectory(guestHomeDir);
    if (home < 0) {
        NSLog(@"[runtime] Could not open guest home %@: %s", guestHomeDir, strerror(errno));
        return 1;
    }
    int fd = openat(home, ".guest.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    int openError = errno;
    close(home);
    if (fd < 0) {
        NSLog(@"[runtime] Could not open guest lock for %@: %s", guestHomeDir, strerror(openError));
        return 1;
    }
    struct stat lock;
    if (fstat(fd, &lock) != 0 || !S_ISREG(lock.st_mode)) {
        NSLog(@"[runtime] Guest lock is not a regular file");
        close(fd);
        return 1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int lockError = errno;
        close(fd);
        if (lockError == EWOULDBLOCK || lockError == EAGAIN) {
            NSLog(@"[runtime] Guest %@ already running", guestHomeDir.lastPathComponent);
            return 2;
        }
        NSLog(@"[runtime] Could not lock guest %@: %s", guestHomeDir.lastPathComponent, strerror(lockError));
        return 1;
    }
    // Deliberately never closed: the lock must last until the process exits.
    return 0;
}

int main(int argc, char * argv[]) {

    NSString *appBundleName = appToLaunchFromArgv(argc, argv);
    int keychainSlot = keychainSlotFromArgv(argc, argv);
    NSString *incomingToken = nil;
    if (!PCReadIncomingToken(argc, argv, &incomingToken)) {
        NSLog(@"[runtime] Invalid --playcover-incoming; refusing to launch");
        return 1;
    }

    // Headless runtime: no selection UI, the host app is the only launcher.
    if (appBundleName.length == 0 || [appBundleName hasPrefix:@"."] ||
        ![appBundleName isEqualToString:appBundleName.lastPathComponent]) {
        NSLog(@"[runtime] No valid launch request (--launch-app <installName>); exiting");
        return 1;
    }

    // Access-group base is shared across flavors (Info.plist
    // KeychainAccessGroupBase); capture the bundle ID before the guest
    // rewrites them below.
    NSString *hostAppIdentifier = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"KeychainAccessGroupBase"];
    if (hostAppIdentifier.length == 0) {
        hostAppIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    }

    // Fail closed: without the hooks the guest would use the shared default access group.
    if (keychainSlot < 0) {
        NSLog(@"[runtime] Missing or invalid --keychain-slot; refusing to launch");
        return 3;
    }

    NSString *homeDir = NSHomeDirectory();
    NSString *appsDir = [homeDir stringByAppendingPathComponent:@"apps.noindex"];
    NSString *appBundlePath = [appsDir stringByAppendingPathComponent:appBundleName];
    NSBundle *appBundle = incomingToken ? nil : [NSBundle bundleWithPath:appBundlePath];
    NSString *identifier = incomingToken ? appBundleName.stringByDeletingPathExtension : appBundle.bundleIdentifier;
    if (incomingToken && (![appBundleName.pathExtension isEqualToString:@"app"] || !PCValidGuestIdentifier(identifier))) {
        NSLog(@"[runtime] Invalid bundle identifier for --playcover-incoming");
        return 1;
    }
    if (identifier.length == 0 || [identifier hasPrefix:@"."] ||
        ![identifier isEqualToString:identifier.lastPathComponent]) {
        NSLog(@"[runtime] Requested app bundle is missing a valid identifier at %@", appBundlePath);
        return 1;
    }

    // Keep the guest locked while loading it and for the rest of its lifetime.
    NSString *guestHomeDir = [homeDir stringByAppendingPathComponent:identifier];
    if (mkdir(guestHomeDir.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
        NSLog(@"[runtime] Could not create guest home %@: %s", guestHomeDir, strerror(errno));
        return 1;
    }
    int guestLockStatus = acquireGuestLock(guestHomeDir);
    if (guestLockStatus != 0) {
        return guestLockStatus;
    }
    if (incomingToken) {
        appBundlePath = PCIncomingGuestPath(incomingToken, identifier, appBundleName);
        if (!appBundlePath) {
            return 1;
        }
        appBundle = [NSBundle bundleWithPath:appBundlePath];
        // Resolve the staged URL's bookmark before PlayTools initializes AppKit
        // under dyld's initializer lock. LaunchServices may need FileProvider.
        [appBundle.bundleURL bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil
                                        relativeToURL:nil error:NULL];
    }
    if (!appBundle.executablePath.length) {
        NSLog(@"[runtime] Requested app bundle is missing its executable at %@", appBundlePath);
        return 1;
    }

    NSLog(@"%@", [NSString stringWithFormat:@"Bundle loaded %@", appBundle.bundleIdentifier]);
    init_bypassDyldLibValidation();

    const char **path = _CFGetProcessPath();
    const char *appExecPath = appBundle.executablePath.fileSystemRepresentation;
    *path = appExecPath;
    overwriteExecPath(appExecPath);

    setenv("HOME", guestHomeDir.UTF8String, 1);
    setenv("CFFIXED_USER_HOME", guestHomeDir.UTF8String, 1);
    // Per-guest temp dir: the container's Data/tmp is shared by every guest.
    setenv("TMPDIR", [guestHomeDir stringByAppendingPathComponent:@"tmp/"].UTF8String, 1);

    NSArray *dirList = @[@"Library/Caches", @"Library/Cookies", @"Documents", @"SystemData", @"tmp"];
    for (NSString *dir in dirList) {
        NSString *dirPath = [guestHomeDir stringByAppendingPathComponent:dir];
        if (![[NSFileManager defaultManager] fileExistsAtPath:dirPath]) {
            NSError *error = nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&error];
            if (error) {
                NSLog(@"Failed to create directory %@: %@", dir, error);
            } else {
                NSLog(@"Successfully created directory at %@", dirPath);
            }
        }
    }

    overwriteMainNSBundle(appBundle);
    overwriteMainCFBundle();
    PlayCoverRuntimeInit(appBundle);

    NSMutableArray<NSString *> *objcArgv = NSProcessInfo.processInfo.arguments.mutableCopy;
    // Strip the host's private options so the guest sees a clean argument list.
    for (NSString *flag in @[@"--launch-app", @"--keychain-slot", @"--playcover-incoming"]) {
        NSUInteger flagIdx = [objcArgv indexOfObject:flag];
        if (flagIdx != NSNotFound) {
            NSUInteger len = MIN((NSUInteger)2, objcArgv.count - flagIdx);
            [objcArgv removeObjectsInRange:NSMakeRange(flagIdx, len)];
        }
    }
    objcArgv[0] = appBundle.executablePath;
    [NSProcessInfo.processInfo setArguments:objcArgv];
    NSProcessInfo.processInfo.processName = appBundle.infoDictionary[@"CFBundleExecutable"];
    *_CFGetProgname() = NSProcessInfo.processInfo.processName.UTF8String;
    Class swiftNSProcessInfo = NSClassFromString(@"_NSSwiftProcessInfo");
    if(swiftNSProcessInfo) {
        // Swizzle the arguments method to return the ObjC arguments
        SEL selector = @selector(arguments);
        method_setImplementation(class_getInstanceMethod(swiftNSProcessInfo, selector), class_getMethodImplementation(NSProcessInfo.class, selector));
    }

    if (appBundle) {
        NSLog(@"Successfully loaded app bundle");
        // dlopen app's main executable
        NSString *executablePath = [appBundle executablePath];
        if (executablePath) {
            appMainImageIndex = _dyld_image_count();
            hook_init(); // dyld-validation bypass is always needed to load the guest
            GroupContainerHooksInit();
            // Fail closed: unhooked, the guest would share the default
            // access group with every other guest.
            if (!SecItemGuestHooksInit(hostAppIdentifier, keychainSlot)) {
                return 3;
            }
            void *handle = dlopen(executablePath.UTF8String, RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST);
            appExecutableHandle = handle;
            if (handle) {
                int (*appMain)(int, char **) = (int (*)(int, char **))getAppEntryPoint(handle);
                NSLog(@"Successfully dlopened app's executable");
                GuestCryptidPatchInit();
                if (incomingToken) {
                    PCRemovePreviousGuestCopies(homeDir, appBundleName, identifier);
                }
                char *guestArgv[] = { (char *)[executablePath UTF8String], NULL };
                int retcode = appMain(1, guestArgv);
                NSLog(@"App exited with code %d", retcode);
                return retcode;
            } else {
                NSLog(@"Failed to dlopen app's executable: %s", dlerror());
            }
        } else {
            NSLog(@"Failed to load app bundle");
        }
    }
    NSLog(@"Failed to launch app");
    return 1;
}
