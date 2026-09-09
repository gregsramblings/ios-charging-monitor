#import "SmartCharge.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

int64_t SmartChargeNotificationState(void) {
    static int token = -1;
    if (token < 0 && notify_register_check("com.apple.powerui.smartchargestatuschanged", &token) != NOTIFY_STATUS_OK) {
        token = -1;
        return -1;
    }
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return -1;
    return (int64_t)state;
}

@implementation SmartChargeStatus
- (instancetype)init {
    self = [super init];
    if (self) {
        _obcEnabled = _mclEnabled = _deocEnabled = -1;
        _mclLimit = _currentChargeLimit = _recommendedChargeLimit = -1;
        _obcEngaged = _engagedChargeLimit = _chargingOverrideAllowed = _uiState = -1;
        _callErrors = @[];
    }
    return self;
}
@end

@interface SmartChargeReader ()
@property (nonatomic, strong) id client;
@end

static void recordError(NSMutableArray<NSString *> *errors, const char *selector, NSString *message) {
    [errors addObject:[NSString stringWithFormat:@"%s: %@", selector, message]];
}

/// Calls `-(BOOL)selector` with no arguments.
static BOOL callBool(id target, const char *selectorName) {
    SEL selector = sel_registerName(selectorName);
    if (![target respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
    } @catch (NSException *exception) {
        return NO;
    }
}

/// Calls `-(unsigned long)selector:(NSError **)error`.
static NSInteger callUnsigned(id target, const char *selectorName, NSMutableArray<NSString *> *errors) {
    SEL selector = sel_registerName(selectorName);
    if (![target respondsToSelector:selector]) { recordError(errors, selectorName, @"not implemented"); return -1; }
    NSError *error = nil;
    @try {
        unsigned long value = ((unsigned long (*)(id, SEL, NSError **))objc_msgSend)(target, selector, &error);
        if (error) { recordError(errors, selectorName, error.localizedDescription); return -1; }
        return (NSInteger)value;
    } @catch (NSException *exception) {
        recordError(errors, selectorName, exception.reason ?: @"exception");
        return -1;
    }
}

/// Calls `-(unsigned char)selector:(NSError **)error`.
static NSInteger callByte(id target, const char *selectorName, NSMutableArray<NSString *> *errors) {
    SEL selector = sel_registerName(selectorName);
    if (![target respondsToSelector:selector]) { recordError(errors, selectorName, @"not implemented"); return -1; }
    NSError *error = nil;
    @try {
        unsigned char value = ((unsigned char (*)(id, SEL, NSError **))objc_msgSend)(target, selector, &error);
        if (error) { recordError(errors, selectorName, error.localizedDescription); return -1; }
        return value;
    } @catch (NSException *exception) {
        recordError(errors, selectorName, exception.reason ?: @"exception");
        return -1;
    }
}

/// Calls `-(id)selector:(NSError **)error`.
static id callObject(id target, const char *selectorName, NSMutableArray<NSString *> *errors) {
    SEL selector = sel_registerName(selectorName);
    if (![target respondsToSelector:selector]) { recordError(errors, selectorName, @"not implemented"); return nil; }
    NSError *error = nil;
    @try {
        id value = ((id (*)(id, SEL, NSError **))objc_msgSend)(target, selector, &error);
        if (error) { recordError(errors, selectorName, error.localizedDescription); return nil; }
        return value;
    } @catch (NSException *exception) {
        recordError(errors, selectorName, exception.reason ?: @"exception");
        return nil;
    }
}

@implementation SmartChargeReader

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    void *handle = dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW);
    Class clientClass = objc_getClass("PowerUISmartChargeClient");
    if (!handle || !clientClass) return nil;
    SEL initSelector = sel_registerName("initWithClientName:");
    if (![clientClass instancesRespondToSelector:initSelector]) return nil;
    id instance = [clientClass alloc];
    _client = ((id (*)(id, SEL, id))objc_msgSend)(instance, initSelector, @"ChargeSpeed");
    return _client ? self : nil;
}

- (SmartChargeStatus *)read {
    SmartChargeStatus *status = [SmartChargeStatus new];
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    id client = self.client;

    status.obcSupported = callBool(client, "isOBCSupported");
    status.mclSupported = callBool(client, "isMCLSupported");
    status.deocSupported = callBool(client, "isDEoCSupported");

    status.obcEnabled = callUnsigned(client, "isSmartChargingCurrentlyEnabled:", errors);
    status.mclEnabled = callUnsigned(client, "isMCLCurrentlyEnabled:", errors);
    status.deocEnabled = callUnsigned(client, "isDEoCCurrentlyEnabled:", errors);
    status.mclLimit = callByte(client, "getMCLLimitWithError:", errors);
    status.currentChargeLimit = callUnsigned(client, "currentChargeLimit:", errors);
    status.recommendedChargeLimit = callUnsigned(client, "currentRecommendedChargeLimitWithError:", errors);

    const char *engagedName = "isOBCEngaged:chargeLimit:chargingOverrideAllowed:withError:";
    SEL engagedSelector = sel_registerName(engagedName);
    if ([client respondsToSelector:engagedSelector]) {
        BOOL engaged = NO, overrideAllowed = NO;
        unsigned long limit = 0;
        NSError *error = nil;
        @try {
            BOOL ok = ((BOOL (*)(id, SEL, BOOL *, unsigned long *, BOOL *, NSError **))objc_msgSend)
                (client, engagedSelector, &engaged, &limit, &overrideAllowed, &error);
            if (ok && !error) {
                status.obcEngaged = engaged;
                status.engagedChargeLimit = (NSInteger)limit;
                status.chargingOverrideAllowed = overrideAllowed;
            } else {
                recordError(errors, engagedName, error.localizedDescription ?: @"returned NO");
            }
        } @catch (NSException *exception) {
            recordError(errors, engagedName, exception.reason ?: @"exception");
        }
    }

    const char *uiName = "smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:";
    SEL uiSelector = sel_registerName(uiName);
    if ([client respondsToSelector:uiSelector]) {
        unsigned long uiState = 0, limit = 0;
        BOOL overrideAllowed = NO;
        NSError *error = nil;
        @try {
            BOOL ok = ((BOOL (*)(id, SEL, unsigned long *, unsigned long *, BOOL *, NSError **))objc_msgSend)
                (client, uiSelector, &uiState, &limit, &overrideAllowed, &error);
            if (ok && !error) {
                status.uiState = (NSInteger)uiState;
                if (status.engagedChargeLimit < 0) status.engagedChargeLimit = (NSInteger)limit;
            } else {
                recordError(errors, uiName, error.localizedDescription ?: @"returned NO");
            }
        } @catch (NSException *exception) {
            recordError(errors, uiName, exception.reason ?: @"exception");
        }
    }

    id deadline = callObject(client, "fullChargeDeadline:", errors);
    if ([deadline isKindOfClass:[NSDate class]] && [(NSDate *)deadline timeIntervalSince1970] > 0) {
        status.fullChargeDeadline = deadline;
    }

    SEL statusSelector = sel_registerName("status");
    if ([client respondsToSelector:statusSelector]) {
        @try {
            id raw = ((id (*)(id, SEL))objc_msgSend)(client, statusSelector);
            if ([raw isKindOfClass:[NSDictionary class]]) status.rawStatus = raw;
        } @catch (NSException *exception) {
            recordError(errors, "status", exception.reason ?: @"exception");
        }
    }

    status.callErrors = errors;
    status.available = status.obcEnabled >= 0 || status.mclEnabled >= 0 || status.obcEngaged >= 0;
    if (!status.available) status.errorMessage = errors.firstObject ?: @"PowerUISmartChargeClient returned nothing";
    return status;
}

@end
