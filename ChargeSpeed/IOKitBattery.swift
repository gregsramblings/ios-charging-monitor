import Foundation

/// Reads the `IOPMPowerSource` (AppleSmartBattery) registry entry through IOKit.
///
/// IOKit is a private framework on iOS, so the handful of symbols we need are
/// resolved with `dlsym` at runtime rather than linked. This is fine for a
/// personal development build but will not pass App Store review.
final class IOKitBattery {
    private typealias IOServiceMatchingFn =
        @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFDictionary>?
    private typealias IOServiceGetMatchingServiceFn =
        @convention(c) (mach_port_t, CFDictionary?) -> UInt32
    private typealias IORegistryEntryCreateCFPropertiesFn =
        @convention(c) (UInt32, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?, CFAllocator?, UInt32) -> kern_return_t
    private typealias IOObjectReleaseFn =
        @convention(c) (UInt32) -> kern_return_t
    private typealias IORegistryEntryCreateCFPropertyFn =
        @convention(c) (UInt32, CFString, CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias IOPSCopyPowerSourcesInfoFn =
        @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias IOPSCopyPowerSourcesListFn =
        @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias IOPSGetPowerSourceDescriptionFn =
        @convention(c) (CFTypeRef, CFTypeRef) -> Unmanaged<CFDictionary>?
    private typealias IOPSCopyExternalPowerAdapterDetailsFn =
        @convention(c) () -> Unmanaged<CFDictionary>?
    private typealias IOPSCopyChargeStatusFn =
        @convention(c) (UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> Int32

    private let serviceMatching: IOServiceMatchingFn
    private let getMatchingService: IOServiceGetMatchingServiceFn
    private let createProperties: IORegistryEntryCreateCFPropertiesFn
    private let objectRelease: IOObjectReleaseFn
    private let createProperty: IORegistryEntryCreateCFPropertyFn?
    private let psCopyInfo: IOPSCopyPowerSourcesInfoFn?
    private let psCopyList: IOPSCopyPowerSourcesListFn?
    private let psDescription: IOPSGetPowerSourceDescriptionFn?
    private let psAdapterDetails: IOPSCopyExternalPowerAdapterDetailsFn?
    private let psChargeStatus: IOPSCopyChargeStatusFn?
    /// Last IOReturn from `IOPSCopyChargeStatus` (0xe00002c1 = not privileged).
    private(set) var chargeStatusError: Int32 = 0

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        guard
            let matching = dlsym(handle, "IOServiceMatching"),
            let getService = dlsym(handle, "IOServiceGetMatchingService"),
            let createProps = dlsym(handle, "IORegistryEntryCreateCFProperties"),
            let release = dlsym(handle, "IOObjectRelease")
        else {
            return nil
        }
        serviceMatching = unsafeBitCast(matching, to: IOServiceMatchingFn.self)
        getMatchingService = unsafeBitCast(getService, to: IOServiceGetMatchingServiceFn.self)
        createProperties = unsafeBitCast(createProps, to: IORegistryEntryCreateCFPropertiesFn.self)
        objectRelease = unsafeBitCast(release, to: IOObjectReleaseFn.self)
        createProperty = dlsym(handle, "IORegistryEntryCreateCFProperty").map { unsafeBitCast($0, to: IORegistryEntryCreateCFPropertyFn.self) }
        psCopyInfo = dlsym(handle, "IOPSCopyPowerSourcesInfo").map { unsafeBitCast($0, to: IOPSCopyPowerSourcesInfoFn.self) }
        psCopyList = dlsym(handle, "IOPSCopyPowerSourcesList").map { unsafeBitCast($0, to: IOPSCopyPowerSourcesListFn.self) }
        psDescription = dlsym(handle, "IOPSGetPowerSourceDescription").map { unsafeBitCast($0, to: IOPSGetPowerSourceDescriptionFn.self) }
        psAdapterDetails = dlsym(handle, "IOPSCopyExternalPowerAdapterDetails").map { unsafeBitCast($0, to: IOPSCopyExternalPowerAdapterDetailsFn.self) }
        psChargeStatus = dlsym(handle, "IOPSCopyChargeStatus").map { unsafeBitCast($0, to: IOPSCopyChargeStatusFn.self) }
    }

    /// powerd's charge status (`IOPSCopyChargeStatus`), e.g. `chargeStatus = "Charging On Hold"`.
    /// This is what the Batteries widget uses to show "Charging On Hold".
    func readChargeStatus() -> [String: Any]? {
        guard let psChargeStatus else { return nil }
        var out: Unmanaged<CFTypeRef>?
        let result = psChargeStatus(&out)
        chargeStatusError = result
        guard result == 0, let value = out?.takeRetainedValue() else { return nil }
        return value as? [String: Any]
    }

    /// Details of the connected power adapter from powerd (`IOPSCopyExternalPowerAdapterDetails`).
    func readAdapterDetails() -> [String: Any]? {
        psAdapterDetails?()?.takeRetainedValue() as? [String: Any]
    }

    /// Reads a single named property from the `IOPMPowerSource` service.
    func readProperty(_ key: String, className: String = "IOPMPowerSource") -> Any? {
        guard let createProperty, let matching = serviceMatching(className) else { return nil }
        let service = getMatchingService(0, matching.takeUnretainedValue())
        guard service != 0 else { return nil }
        defer { _ = objectRelease(service) }
        return createProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Power source descriptions from powerd (`IOPSCopyPowerSourcesInfo`), one dictionary per source.
    func readPowerSources() -> [[String: Any]] {
        guard let psCopyInfo, let psCopyList, let psDescription,
              let blob = psCopyInfo()?.takeRetainedValue(),
              let list = psCopyList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return list.compactMap { psDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    /// Returns the full property dictionary of the first `IOPMPowerSource` service.
    func readProperties() -> [String: Any]? {
        guard let matching = serviceMatching("IOPMPowerSource") else { return nil }
        // IOServiceGetMatchingService consumes the +1 reference returned by IOServiceMatching,
        // so hand it over unretained rather than letting ARC release it a second time.
        let service = getMatchingService(0 /* kIOMainPortDefault */, matching.takeUnretainedValue())
        guard service != 0 else { return nil }
        defer { _ = objectRelease(service) }

        var properties: Unmanaged<CFDictionary>?
        let result = createProperties(service, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let dictionary = properties?.takeRetainedValue() else {
            return nil
        }
        return dictionary as? [String: Any]
    }
}
