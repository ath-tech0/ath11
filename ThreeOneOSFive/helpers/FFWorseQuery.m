#import "FFWorseQuery.h"
#import "FFWorseQueryPolicy.h"
#import "vendor/worse_query/worse_query.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static NSRecursiveLock *FFWQLock;
static NSMutableDictionary<NSString *, NSNumber *> *FFWQHandles;
static NSString *FFWQGroup;
static NSString *FFWQLibrary;
static NSString *FFWQFailure;
static BOOL FFWQAttempted;
static BOOL FFWQActive;

static void FFWQInitialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        FFWQLock = [NSRecursiveLock new];
        FFWQHandles = [NSMutableDictionary dictionary];
    });
}

BOOL FFWorseQuerySupported(void) {
    NSOperatingSystemVersion v = NSProcessInfo.processInfo.operatingSystemVersion;
    char build[128] = {0};
    size_t size = sizeof(build) - 1;
    sysctlbyname("kern.osversion", build, &size, NULL, 0);
    return FFWorseQueryVersionSupported(v.majorVersion, v.minorVersion, v.patchVersion, build);
}

static NSArray<NSString *> *FFWQAppGroups(void) {
    NSMutableOrderedSet<NSString *> *groups = [NSMutableOrderedSet orderedSet];
    id configured = [NSBundle.mainBundle objectForInfoDictionaryKey:@"FFWorseQueryAppGroup"];
    if ([configured isKindOfClass:NSString.class] && [configured hasPrefix:@"group."])
        [groups addObject:configured];
    // Resolve at runtime so older builder SDKs need no private Security header.
    CFTypeRef (*createTask)(CFAllocatorRef) = dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*copyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *) =
        dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    CFTypeRef task = createTask ? createTask(kCFAllocatorDefault) : NULL;
    if (task && copyEntitlement) {
        CFTypeRef value = copyEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL);
        if (value) {
            if (CFGetTypeID(value) == CFArrayGetTypeID()) {
                for (id group in (__bridge NSArray *)value)
                    if ([group isKindOfClass:NSString.class] && [group hasPrefix:@"group."])
                        [groups addObject:group];
            }
            CFRelease(value);
        }
    }
    if (task) CFRelease(task);
    return groups.array;
}

static BOOL FFWQPathExists(NSString *path) {
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0;
}

// The upstream primitive temporarily replaces App Group Library/Caches.
// Preserve existing caches and recover them after an interrupted previous query.
static BOOL FFWQRestoreCaches(NSString *caches, NSString *backup) {
    if (!FFWQPathExists(backup)) return YES;
    struct stat st;
    if (lstat(caches.fileSystemRepresentation, &st) == 0) {
        int removed = S_ISLNK(st.st_mode) ? unlink(caches.fileSystemRepresentation)
                                        : rmdir(caches.fileSystemRepresentation);
        if (removed != 0) {
            FFWQFailure = @"App Group cache recovery is blocked. Existing files were preserved.";
            return NO;
        }
    }
    NSError *error = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:backup toPath:caches error:&error]) {
        FFWQFailure = [@"App Group cache restore failed: " stringByAppendingString:error.localizedDescription ?: @"unknown"];
        return NO;
    }
    return YES;
}

BOOL FFWorseQueryPrepare(void) {
    if (!FFWorseQuerySupported()) return NO;
    FFWQInitialize();
    [FFWQLock lock];
    @try {
        if (FFWQAttempted) return FFWQGroup.length > 0;
        FFWQAttempted = YES;
        NSFileManager *files = NSFileManager.defaultManager;
        for (NSString *group in FFWQAppGroups()) {
            NSURL *root = [files containerURLForSecurityApplicationGroupIdentifier:group];
            if (!root) continue; // An Info.plist value alone does not grant an entitlement.
            NSString *library = [root.path stringByAppendingPathComponent:@"Library"];
            if (![files createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:nil]) continue;
            NSString *caches = [library stringByAppendingPathComponent:@"Caches"];
            NSString *backup = [library stringByAppendingPathComponent:@".ffcachemanager-wq-caches-backup"];
            if (!FFWQRestoreCaches(caches, backup)) return NO;
            FFWQGroup = group;
            FFWQLibrary = library;
            FFWQFailure = nil;
            return YES;
        }
        FFWQFailure = @"worse_query needs a provisioned App Group. Enable App Groups for this app, then sign it with a matching profile; adding the entitlement text alone is insufficient.";
        return NO;
    } @finally {
        [FFWQLock unlock];
    }
}

static BOOL FFWQCanOpen(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    close(fd);
    return YES;
}

static int64_t FFWQQueryPreservingCaches(NSString *path, BOOL alternate, BOOL allowMissing) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *caches = [FFWQLibrary stringByAppendingPathComponent:@"Caches"];
    NSString *backup = [FFWQLibrary stringByAppendingPathComponent:@".ffcachemanager-wq-caches-backup"];
    if (!FFWQRestoreCaches(caches, backup)) return -9;
    BOOL saved = FFWQPathExists(caches);
    if (saved && ![files moveItemAtPath:caches toPath:backup error:nil]) {
        FFWQFailure = @"Could not preserve App Group caches; query was cancelled.";
        return -9;
    }
    __block int64_t handle = -1;
    @try {
        handle = worse_query(path, FFWQGroup, alternate, allowMissing);
    } @finally {
        // upstream also cleans up on success; cover its early-return paths.
        struct stat st;
        if (lstat(caches.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode))
            unlink(caches.fileSystemRepresentation);
        if (saved && !FFWQRestoreCaches(caches, backup)) {
            worse_query_release(handle);
            handle = -9;
        }
    }
    return handle;
}

int64_t FFWorseQueryGrantPath(NSString *rawPath, BOOL allowMissing) {
    if (!rawPath.length || !rawPath.isAbsolutePath || !FFWorseQueryPrepare()) return -1;
    NSString *path = rawPath.stringByStandardizingPath;
    if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
    FFWQInitialize();
    [FFWQLock lock];
    @try {
        NSNumber *cached = FFWQHandles[path];
        if (cached && FFWQCanOpen(path)) return cached.longLongValue;
        if (cached) {
            worse_query_release(cached.longLongValue);
            [FFWQHandles removeObjectForKey:path];
        }
        // Reuse a recursive grant only after opening the requested descendant.
        for (NSString *ancestor in FFWQHandles) {
            if ([path hasPrefix:[ancestor stringByAppendingString:@"/"]] && FFWQCanOpen(path))
                return FFWQHandles[ancestor].longLongValue;
        }
        BOOL alternate = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26;
        int64_t handle = FFWQQueryPreservingCaches(path, alternate, allowMissing);
        if (handle >= 0 && FFWQPathExists(path) && !FFWQCanOpen(path)) {
            worse_query_release(handle);
            handle = -8;
        }
        if (handle < 0 && handle != -1 && handle != -2 && handle != -9) {
            handle = FFWQQueryPreservingCaches(path, !alternate, allowMissing);
            if (handle >= 0 && FFWQPathExists(path) && !FFWQCanOpen(path)) {
                worse_query_release(handle);
                handle = -8;
            }
        }
        if (handle >= 0) {
            FFWQHandles[path] = @(handle);
            FFWQActive = FFWQActive || FFWQCanOpen(path);
        } else if (handle != -9) {
            FFWQFailure = [NSString stringWithFormat:@"worse_query could not grant this path (code %lld). Target access must pass the read/write check before Apply.", (long long)handle];
        }
        return handle;
    } @finally {
        [FFWQLock unlock];
    }
}

BOOL FFWorseQueryHasSandboxAccess(void) {
    FFWQInitialize();
    [FFWQLock lock];
    BOOL result = FFWQActive;
    [FFWQLock unlock];
    return result;
}

NSString *FFWorseQueryStatusText(void) {
    if (!FFWorseQuerySupported()) return @"WQ UNSUPPORTED IOS/BUILD";
    FFWQInitialize();
    [FFWQLock lock];
    NSString *result = !FFWQAttempted ? @"WQ IDLE" : !FFWQGroup.length ? @"WQ SETUP FAILED"
        : FFWQActive ? @"WQ GRANTS ACTIVE" : @"WQ READY TO QUERY";
    [FFWQLock unlock];
    return result;
}

NSString *FFWorseQueryFailureReason(void) {
    FFWQInitialize();
    [FFWQLock lock];
    NSString *result = FFWQFailure ?: @"worse_query did not provide verified access to the selected container.";
    [FFWQLock unlock];
    return result;
}

NSString *FFWorseQueryDataContainerCandidate(NSString *identifier) {
    if (!identifier.length || !FFWorseQueryPrepare()) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
        dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    });
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL lookup = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (![proxyClass respondsToSelector:lookup]) return nil;
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, lookup, identifier);
    SEL dataURL = NSSelectorFromString(@"dataContainerURL");
    if (![proxy respondsToSelector:dataURL]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(proxy, dataURL);
    if (![value isKindOfClass:NSURL.class] || ![(NSURL *)value isFileURL]) return nil;
    NSString *path = [(NSURL *)value path].stringByStandardizingPath;
    if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
    if (![path.stringByDeletingLastPathComponent isEqualToString:@"/private/var/mobile/Containers/Data/Application"] ||
        ![[NSUUID alloc] initWithUUIDString:path.lastPathComponent]) return nil;
    return path;
}
