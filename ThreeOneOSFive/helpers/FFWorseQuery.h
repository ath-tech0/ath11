#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL FFWorseQuerySupported(void);
// Resolves a real, provisioned App Group. This is not proof of target access.
BOOL FFWorseQueryPrepare(void);
// Handles are owned by this module and retained for the lifetime of the process.
int64_t FFWorseQueryGrantPath(NSString *path, BOOL allowMissing);
BOOL FFWorseQueryHasSandboxAccess(void);
NSString *FFWorseQueryStatusText(void);
NSString *FFWorseQueryFailureReason(void);
// LaunchServices candidate only; callers must verify the container's identity.
NSString * _Nullable FFWorseQueryDataContainerCandidate(NSString *identifier);

NS_ASSUME_NONNULL_END
