#import "Probes2.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <notify.h>

static void dumpObject(id object, const char *label) {
    Class cls = object_getClass(object);
    printf("  %s <%s>\n", label, class_getName(cls));
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned count = 0;
        objc_property_t *props = class_copyPropertyList(c, &count);
        for (unsigned i = 0; i < count; i++) {
            NSString *name = @(property_getName(props[i]));
            @try {
                id value = [object valueForKey:name];
                printf("    %s = %s\n", name.UTF8String, [[value description] UTF8String] ?: "nil");
            } @catch (NSException *e) {
                printf("    %s = <%s>\n", name.UTF8String, e.reason.UTF8String);
            }
        }
        free(props);
    }
}

static void probeBatteryCenter(void) {
    void *handle = dlopen("/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter", RTLD_NOW);
    Class controllerClass = objc_getClass("BCBatteryDeviceController");
    Class psClass = objc_getClass("_BCPowerSourceController");
    printf("PROBE BatteryCenter handle=%p controller=%p ps=%p\n", handle, controllerClass, psClass);
    if (!controllerClass) return;
    @try {
        id controller = nil;
        if ([controllerClass respondsToSelector:sel_registerName("sharedInstance")]) {
            controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sel_registerName("sharedInstance"));
        } else {
            controller = [[controllerClass alloc] init];
        }
        printf("PROBE BC controller=%s\n", [[controller description] UTF8String]);
        id ps = nil;
        if ([controllerClass respondsToSelector:sel_registerName("_sharedPowerSourceController")]) {
            ps = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sel_registerName("_sharedPowerSourceController"));
        }
        if (ps && [ps respondsToSelector:sel_registerName("_isChargingPaused")]) {
            BOOL paused = ((BOOL (*)(id, SEL))objc_msgSend)(ps, sel_registerName("_isChargingPaused"));
            printf("PROBE BC _isChargingPaused=%d\n", paused);
        } else {
            printf("PROBE BC no _isChargingPaused (ps=%p)\n", ps);
        }
        // Enumerate every method on the power source controller so we can see iOS-only ones.
        if (ps) {
            unsigned n = 0;
            Method *methods = class_copyMethodList(object_getClass(ps), &n);
            printf("PROBE BC _BCPowerSourceController methods:");
            for (unsigned i = 0; i < n; i++) printf(" %s", sel_getName(method_getName(methods[i])));
            printf("\n");
            free(methods);
        }
        id devices = [controller valueForKey:@"connectedDevices"];
        printf("PROBE BC connectedDevices=%lu\n", (unsigned long)[devices count]);
        for (id device in devices) dumpObject(device, "device");
        if ([devices count]) {
            unsigned n = 0;
            Method *methods = class_copyMethodList(object_getClass(devices[0]), &n);
            printf("PROBE BC BCBatteryDevice methods:");
            for (unsigned i = 0; i < n; i++) printf(" %s", sel_getName(method_getName(methods[i])));
            printf("\n");
            free(methods);
        }
    } @catch (NSException *e) {
        printf("PROBE BC exception %s\n", e.reason.UTF8String);
    }
}

static void probeNotify(void) {
    const char *names[] = {
        "com.apple.powerui.smartchargestatuschanged",
        "com.apple.system.powersources.source",
        "com.apple.system.powersources.percent",
        "com.apple.system.powersources.timeremaining",
        "com.apple.system.powermanagement.poweradapter",
        "com.apple.system.powersources.chargelimit",
        "com.apple.powerd.chargelimit",
        "com.apple.smartcharging.chargelimit",
        "com.apple.system.batterysaver",
        "com.apple.system.lowpowermode",
        "com.apple.powerd.charging.policy",
        "com.apple.system.powersources.criticallevel",
        NULL };
    for (int i = 0; names[i]; i++) {
        int token = 0;
        uint32_t status = notify_register_check(names[i], &token);
        uint64_t state = 0;
        uint32_t stateStatus = status == NOTIFY_STATUS_OK ? notify_get_state(token, &state) : 999;
        printf("PROBE NOTIFY %s register=%u state=%llu (status %u)\n", names[i], status, state, stateStatus);
        if (status == NOTIFY_STATUS_OK) notify_cancel(token);
    }
}

static void probeMobileGestalt(void) {
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    CFTypeRef (*MGCopyAnswer)(CFStringRef) = handle ? dlsym(handle, "MGCopyAnswer") : NULL;
    printf("PROBE MG handle=%p fn=%p\n", handle, MGCopyAnswer);
    if (!MGCopyAnswer) return;
    NSArray *keys = @[@"ProductType", @"BatteryCurrentCapacity", @"BatteryIsCharging", @"BatteryIsFullyCharged",
                      @"ExternalPowerSourceConnected", @"BatteryCapacity", @"ChargeLimit", @"BatteryChargeLimit",
                      @"ChargingLimit", @"SmartChargingEnabled", @"OptimizedBatteryCharging", @"DeviceSupportsBatteryChargeLimit",
                      @"battery-capacity", @"RequiredBatteryLevelForSoftwareUpdate"];
    for (NSString *key in keys) {
        CFTypeRef value = MGCopyAnswer((__bridge CFStringRef)key);
        printf("PROBE MG %s = %s\n", key.UTF8String, value ? [[(__bridge id)value description] UTF8String] : "nil");
        if (value) CFRelease(value);
    }
}

void ChargeSpeedRunProbes2(void) {
    probeBatteryCenter();
    probeNotify();
    probeMobileGestalt();
    printf("PROBES2 DONE\n");
}
