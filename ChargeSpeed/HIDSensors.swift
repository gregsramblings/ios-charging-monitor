import Foundation

/// Reads Apple's vendor power and temperature sensors through the private
/// `IOHIDEventSystemClient` API. A sandboxed app can create one client and copy sensor
/// events from it; additional clients in the same process return NaN, so a single
/// instance is created once and reused.
///
/// Each service is an `AppleSMCKeysEndpoint` whose `LocationID` is the four-letter SMC key
/// in ASCII (0x49513075 = "IQ0u"). Keys are the stable identifier: product names repeat
/// across different keys ("PMU tdie1" is both TP1b and TP1l), and iOS 27 publishes every key
/// through two services.
///
/// Keys the app uses (usage 2 = current in A, 3 = voltage in V, 5 = temperature in °C):
///   VQ0u / IQ0u   USB-C input voltage / current ("Charger")
///   VQ1u          wireless input rail voltage
///   IQ0B          charge current into the battery; reads 0 on battery power
///   VQ0l, VP0u    battery-side voltages
///   TG0B/C/H/V    the four "gas gauge battery" temperatures
final class HIDSensors {
    struct Reading: Identifiable {
        let id: Int
        let name: String
        /// SMC key from the service's LocationID, e.g. "IQ0u". Empty when not published.
        let key: String
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
        let key: String
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
            let location = (copyProperty(ref, "LocationID" as CFString)?.takeRetainedValue() as? NSNumber)?.uint32Value ?? 0
            return Service(ref: ref, name: name, key: Self.smcKey(location), usage: usage, eventType: eventType)
        }
    }

    /// Four-character SMC key from a LocationID, or "" when it is not printable ASCII.
    private static func smcKey(_ location: UInt32) -> String {
        let bytes = withUnsafeBytes(of: location.bigEndian) { Array($0) }
        guard location != 0, bytes.allSatisfy({ (32...126).contains($0) }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Current keys averaged over several reads per refresh. Each read returns a fresh sample, and
    /// on an 18 Pro Max reads 2 ms apart vary by up to 10 % (IQ0B) while charging. In a 90 s test,
    /// four reads halved the tick-to-tick spread of battery watts; voltages barely vary.
    private static let oversampledKeys: Set<String> = ["IQ0u", "IQ0B"]
    private static let oversampleCount = 4

    private func sample(_ service: Service) -> Double? {
        guard let event = copyEvent(service.ref, service.eventType, 0, 0)?.takeRetainedValue() else { return nil }
        return getFloat(event, Int32(service.eventType << 16))
    }

    /// Current values of every discovered sensor. Sensors that return NaN are skipped.
    func read() -> [Reading] {
        services.enumerated().compactMap { index, service in
            let count = Self.oversampledKeys.contains(service.key) ? Self.oversampleCount : 1
            let samples = (0..<count).compactMap { _ in sample(service) }.filter(\.isFinite)
            guard !samples.isEmpty else { return nil }
            let value = samples.reduce(0, +) / Double(samples.count)
            // On iOS 27 several PMU rail keys (IP3l, IP5l, VP0b, VP2l, ...) read between 14,800 and
            // 16,450, or below -17,000, on every sample. No current, voltage, or temperature here is that large.
            guard value.isFinite, abs(value) < 1000 else { return nil }
            return Reading(id: index, name: service.name, key: service.key, usage: service.usage, value: value)
        }
    }
}
