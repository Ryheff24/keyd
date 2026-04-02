#import "PKCS12ImportHelper.h"

SecIdentityRef _Nullable KeydPKCS12ImportCopyIdentity(
    NSData *pkcs12Data,
    NSString *passphrase,
    OSStatus * _Nullable statusOut
) {
    if (statusOut) {
        *statusOut = errSecParam;
    }
    if (!pkcs12Data || !passphrase) {
        return NULL;
    }

    NSMutableDictionary *options = [@{
        (__bridge id)kSecImportExportPassphrase: passphrase,
    } mutableCopy];
    if (@available(iOS 18.0, *)) {
        options[(__bridge id)kSecImportToMemoryOnly] = @YES;
    }

    CFArrayRef items = NULL;
    OSStatus status = errSecInternalError;
    @try {
        status = SecPKCS12Import((__bridge CFDataRef)pkcs12Data,
                                 (__bridge CFDictionaryRef)options,
                                 &items);
    } @catch (__unused NSException *exception) {
        if (items) {
            CFRelease(items);
        }
        if (statusOut) {
            *statusOut = errSecDecode;
        }
        return NULL;
    }

    SecIdentityRef identity = NULL;
    if (items && CFArrayGetCount(items) > 0) {
        NSDictionary *item = (__bridge NSDictionary *)CFArrayGetValueAtIndex(items, 0);
        id identityObject = item[(__bridge id)kSecImportItemIdentity];
        if (identityObject) {
            identity = (SecIdentityRef)CFRetain((__bridge SecIdentityRef)identityObject);
        }
    }

    if (items) {
        CFRelease(items);
    }
    if (statusOut) {
        *statusOut = status;
    }
    return identity;
}
