#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Copies an HLS stream into a local MP4 without re-encoding it.
FOUNDATION_EXPORT BOOL WOSRemuxHLS(NSURL *inputURL, NSURL *outputURL, NSString *referer, NSString *requestHeaders, NSString * _Nullable * _Nullable errorMessage);

NS_ASSUME_NONNULL_END
