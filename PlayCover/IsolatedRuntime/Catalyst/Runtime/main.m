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
// Returns the held fd, or -1 when the guest is already running.
static int acquireGuestLock(NSString *guestHomeDir) {
    static int lockFD = -1;
    NSString *lockPath = [guestHomeDir stringByAppendingPathComponent:@".guest.lock"];
    int fd = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT, 0644);
    if (fd < 0) {
        NSLog(@"[runtime] could not open guest lock %@: %s", lockPath, strerror(errno));
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        NSLog(@"[runtime] guest %@ is already running; refusing double launch", guestHomeDir.lastPathComponent);
        close(fd);
        return -1;
    }
    // Deliberately never closed: the lock must outlive main().
    lockFD = fd;
    return lockFD;
}

int main(int argc, char * argv[]) {

    NSString *appBundleName = appToLaunchFromArgv(argc, argv);
    int keychainSlot = keychainSlotFromArgv(argc, argv);

    NSString *appBundlePath = nil;
    if (appBundleName.length > 0) {
        NSString *candidate = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"apps.noindex/%@", appBundleName]];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            appBundlePath = candidate;
        } else {
            NSLog(@"[runtime] Requested app bundle missing at %@", candidate);
        }
    }

    // Headless runtime: no selection UI, the host app is the only launcher.
    if (!appBundlePath) {
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

    // Load the App.app bundle from [shared container Data]/apps/[app bundle name]
    NSBundle *appBundle = [NSBundle bundleWithPath:appBundlePath];

    NSLog(@"%@", [NSString stringWithFormat:@"Bundle loaded %@", appBundle.bundleIdentifier]);
    init_bypassDyldLibValidation();

    const char **path = _CFGetProcessPath();
    const char *appExecPath = appBundle.executablePath.fileSystemRepresentation;
    *path = appExecPath;
    overwriteExecPath(appExecPath);

    // Create a new HOME for guest app inside the runtime's shared container
    NSString *homeDir = NSHomeDirectory();
    NSString *guestHomeDir = [homeDir stringByAppendingPathComponent:appBundle.bundleIdentifier];
    if (![[NSFileManager defaultManager] fileExistsAtPath:guestHomeDir]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:guestHomeDir withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            NSLog(@"Failed to create guest home directory: %@", error);
        } else {            NSLog(@"Successfully created guest home directory at %@", guestHomeDir);
        }
    }

    // Single instance per guest (see acquireGuestLock).
    if (acquireGuestLock(guestHomeDir) < 0) {
        return 2;
    }

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
    // Strip the host's private --launch-app <name> and --keychain-slot <N>
    // tokens so the guest sees a clean argument list.
    for (NSString *flag in @[@"--launch-app", @"--keychain-slot"]) {
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
