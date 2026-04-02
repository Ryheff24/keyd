#import <Foundation/Foundation.h>
#import <Security/Security.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT SecIdentityRef _Nullable KeydPKCS12ImportCopyIdentity(
    NSData *pkcs12Data,
    NSString *passphrase,
    OSStatus * _Nullable statusOut
) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
