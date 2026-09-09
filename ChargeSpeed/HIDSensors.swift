import Foundation

/// Reads Apple's vendor power and temperature sensors through the private
/// `IOHIDEventSystemClient` API. On iOS 26 a sandboxed app can create one client
/// and copy sensor events from it; additional clients in the same process return
/// NaN, so a single instance is created once and reused.
///
/// Sensor names seen on iPhone 17 Pro Max (usage 2 = current in A, 3 = voltage in V):
///   Charger VQ0u / IQ0u   USB-C input voltage / current
///   Charger VQ1u          wireless (MagSafe) input voltage
///   Charger IQ0B          current delivered to the battery
///   Charger VQ0l, PMU VP0u  battery-side voltages
///   gas gauge battery     battery temperature (usage page 0xff00, usage 5)
final class HIDSensors {
    struct Reading: Identifiable {
        let id: Int
        let name: String
        /// HID usage: 2 = current (A), 3 = voltage (V), 5 = temperature (°C).
        let usage: Int
        let value: Double

        var formatted: String {
            switch usage {
            case 2: return String(format: "%.3f A", value)
            case 3: return String(format: "%.3f V", value)
            case 5: return Formatting.temperature(value)
            default: return String(format: "%.3f", value)
            }
        }
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let powerEventType: Int64 = 25        // kIOHIDEventTypePower
    private static let temperatureEventType: Int64 = 15  // kIOHIDEventTypeTemperature

    private struct Service {
        let ref: CFTypeRef
        let name: String
        let usage: Int
        let eventType: Int64
    }

    private let client: CFTypeRef
    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private var services: [Service] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        self.client = client
        self.setMatching = setMatching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        rescan()
    }

    /// Re-enumerates sensor services. Cheap enough to call occasionally.
    func rescan() {
        var found: [Service] = []
        // Apple vendor power sensors (usage page 0xff08): usage 2 = current, 3 = voltage.
        found += discover(matching: ["PrimaryUsagePage": 0xff08], eventType: Self.powerEventType)
        // Temperature sensors: usage page 0xff00, usage 5.
        found += discover(matching: ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5], eventType: Self.temperatureEventType)
        services = found
    }

    var isEmpty: Bool { services.isEmpty }

    private func discover(matching: [String: Any], eventType: Int64) -> [Service] {
        setMatching(client, matching as CFDictionary)
        let refs = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return refs.map { ref in
            let name = copyProperty(ref, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            let usage = (copyProperty(ref, "PrimaryUsage" as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            return Service(ref: ref, name: name, usage: usage, eventType: eventType)
        }
    }

    /// Current values of every discovered sensor. Sensors that return NaN are skipped.
    func read() -> [Reading] {
        services.enumerated().compactMap { index, service in
            guard let event = copyEvent(service.ref, service.eventType, 0, 0)?.takeRetainedValue() else { return nil }
            let value = getFloat(event, Int32(service.eventType << 16))
            guard value.isFinite else { return nil }
            return Reading(id: index, name: service.name, usage: service.usage, value: value)
        }
    }
}
