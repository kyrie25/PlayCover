#pragma once

#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <pwd.h>
#import <stdio.h>
#import <sys/stat.h>
#import <unistd.h>

static BOOL PCValidGuestIdentifier(NSString *identifier) {
    if (identifier.length == 0 || identifier.length > 251 || [identifier hasPrefix:@"."]) {
        return NO;
    }
    NSCharacterSet *allowed = [NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"];
    if ([identifier rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
        return NO;
    }
    NSArray *reserved = @[@"apps", @"apps.noindex", @"free_list", @"library", @"documents", @"tmp", @"provisioning",
                         @"applications", @"desktop", @"downloads", @"movies", @"music", @"pictures", @"public",
                         @"systemdata"];
    return ![reserved containsObject:identifier.lowercaseString];
}

static BOOL PCReadIncomingToken(int argc, char *argv[], NSString **token) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--playcover-incoming") != 0) {
            continue;
        }
        if (*token != nil || i + 1 >= argc) {
            return NO;
        }
        NSString *value = [NSString stringWithUTF8String:argv[++i]];
        NSUUID *uuid = value ? [[NSUUID alloc] initWithUUIDString:value] : nil;
        if (!uuid || [uuid.UUIDString caseInsensitiveCompare:value] != NSOrderedSame) {
            return NO;
        }
        *token = value;
    }
    return YES;
}

static int PCOpenRealDirectory(NSString *path) {
    return open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC);
}

static NSDictionary *PCReadBundlePlist(int bundle, const char *name) {
    int fd = openat(bundle, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        return nil;
    }
    struct stat file;
    const NSUInteger maxSize = 1024 * 1024;
    if (fstat(fd, &file) != 0 || !S_ISREG(file.st_mode) || file.st_size <= 0 || file.st_size > (off_t)maxSize) {
        close(fd);
        return nil;
    }
    NSFileHandle *handle = [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
    NSData *data = [handle readDataUpToLength:maxSize + 1 error:NULL];
    if (data.length == 0 || data.length > maxSize) {
        return nil;
    }
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
}

static BOOL PCCheckGuestBundle(int parent, const char *name, NSString *identifier, BOOL requireExecutable) {
    int bundle = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (bundle < 0) {
        return NO;
    }
    NSDictionary *info = PCReadBundlePlist(bundle, "Info.plist");
    BOOL valid = [identifier isEqual:info[@"CFBundleIdentifier"]];
    if (valid && requireExecutable) {
        NSString *executable = info[@"CFBundleExecutable"];
        NSCharacterSet *nul = [NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)];
        struct stat file;
        valid = [executable isKindOfClass:[NSString class]] && executable.length > 0
            && ![executable containsString:@"/"] && [executable rangeOfCharacterFromSet:nul].location == NSNotFound
            && fstatat(bundle, executable.fileSystemRepresentation, &file, AT_SYMLINK_NOFOLLOW) == 0
            && S_ISREG(file.st_mode) && (file.st_mode & S_IXUSR) != 0;
    }
    close(bundle);
    return valid;
}

static void PCRemoveLegacyGuest(NSString *home, NSString *name, NSString *identifier) {
    NSString *legacyApps = [home stringByAppendingPathComponent:@"apps"];
    int apps = PCOpenRealDirectory(legacyApps);
    if (apps < 0) {
        return;
    }
    int bundle = openat(apps, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (bundle >= 0) {
        NSDictionary *features = PCReadBundlePlist(bundle, "RunnerFeatures.plist");
        NSDictionary *info = PCReadBundlePlist(bundle, "Info.plist");
        close(bundle);
        if (features[@"playCoverWidth"] && [identifier isEqual:info[@"CFBundleIdentifier"]]) {
            NSError *error = nil;
            if (![NSFileManager.defaultManager removeItemAtPath:[legacyApps stringByAppendingPathComponent:name]
                                                         error:&error]) {
                NSLog(@"[runtime] Could not clean up the previous prepared bundle: %@", error);
            }
        }
    }
    close(apps);
}

// The signed helper owns the destination container. The host supplies only the unique incoming token.
static BOOL PCInstallIncomingGuest(NSString *token, NSString *identifier, NSString *name, NSString *home) {
    struct passwd *user = getpwuid(getuid());
    if (!user || !user->pw_dir) {
        NSLog(@"[runtime] Could not identify the user's home for the prepared bundle");
        return NO;
    }
    NSString *userHome = [NSString stringWithUTF8String:user->pw_dir];
    NSString *root = [userHome stringByAppendingPathComponent:
        @"Library/Containers/io.playcover.PlayCover/IsolatedRuntime/Incoming.noindex"];
    NSString *staging = [root stringByAppendingPathComponent:[token stringByAppendingString:@".noindex"]];
    int source = PCOpenRealDirectory(staging);
    const char *bundleName = name.fileSystemRepresentation;
    if (source < 0 || !PCCheckGuestBundle(source, bundleName, identifier, YES)) {
        if (source >= 0) {
            close(source);
        }
        NSLog(@"[runtime] Incoming bundle is missing or does not match %@", identifier);
        return NO;
    }

    NSString *appsPath = [home stringByAppendingPathComponent:@"apps.noindex"];
    if (mkdir(appsPath.fileSystemRepresentation, 0700) != 0 && errno != EEXIST) {
        NSLog(@"[runtime] Could not create the prepared-app directory: %s", strerror(errno));
        close(source);
        return NO;
    }
    int target = PCOpenRealDirectory(appsPath);
    if (target < 0) {
        NSLog(@"[runtime] Could not open the prepared-app directory: %s", strerror(errno));
        close(source);
        return NO;
    }

    int moved = renameatx_np(source, bundleName, target, bundleName, RENAME_EXCL);
    if (moved != 0 && errno == EEXIST && PCCheckGuestBundle(target, bundleName, identifier, NO)) {
        // The previous copy lands in the unique staging folder after the swap.
        moved = renameatx_np(source, bundleName, target, bundleName, RENAME_SWAP);
    }
    int moveError = errno;
    close(target);
    close(source);
    if (moved != 0) {
        NSLog(@"[runtime] Could not install the prepared bundle for %@: %s", identifier, strerror(moveError));
        return NO;
    }
    NSError *cleanupError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:staging error:&cleanupError] &&
        !([cleanupError.domain isEqualToString:NSCocoaErrorDomain] && cleanupError.code == NSFileNoSuchFileError)) {
        NSLog(@"[runtime] Could not clean up the incoming request: %@", cleanupError);
    }
    PCRemoveLegacyGuest(home, name, identifier);
    return YES;
}
