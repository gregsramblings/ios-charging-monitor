#if DEBUG
import Foundation

/// One-shot probes of private power data sources, printed to stdout.
/// Used to discover what the iOS sandbox lets a third-party app read.
enum Probes {
    private static let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private static func sym<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, _ type: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    static func run() {
        probeIOPMBatteryInfo()
        probeAdapterDetails()
        probeHID()
        probeIOReport()
        print("PROBES DONE")
    }

    /// Third round: any sensor that reports discharge current, and precise power source info.
    static func runDischarge() {
        setvbuf(stdout, nil, _IONBF, 0)
        probeHIDAll()
        print("DISCHARGE PROBES DONE")
    }

    static func probeIOPSPrecise() {
        typealias CopyInfo = @convention(c) () -> Unmanaged<CFTypeRef>?
        typealias CopyList = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias GetDesc = @convention(c) (CFTypeRef, CFTypeRef) -> Unmanaged<CFDictionary>?
        guard let precise = sym(iokit, "IOPSCopyPowerSourcesInfoPrecise", CopyInfo.self),
              let list = sym(iokit, "IOPSCopyPowerSourcesList", CopyList.self),
              let desc = sym(iokit, "IOPSGetPowerSourceDescription", GetDesc.self)
        else { print("PROBE IOPSPrecise: missing symbols"); return }
        guard let blob = precise()?.takeRetainedValue() else { print("PROBE IOPSPrecise: nil blob"); return }
        print("PROBE IOPSPrecise blob=\(String(describing: blob).prefix(1500))")
        if let sources = list(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                print("PROBE IOPSPrecise source=\(String(describing: desc(blob, source)?.takeUnretainedValue()).prefix(1500))")
            }
        }
    }

    static func probeHIDAll() {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary?) -> Void
        typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
        typealias GetFloat = @convention(c) (CFTypeRef, Int32) -> Double
        typealias GetInt = @convention(c) (CFTypeRef, Int32) -> Int64
        guard let create = sym(iokit, "IOHIDEventSystemClientCreate", Create.self),
              let setMatching = sym(iokit, "IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = sym(iokit, "IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = sym(iokit, "IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = sym(iokit, "IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloat = sym(iokit, "IOHIDEventGetFloatValue", GetFloat.self),
              let getInt = sym(iokit, "IOHIDEventGetIntegerValue", GetInt.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { print("PROBE HIDAll: missing symbols"); return }
        // Match everything.
        setMatching(client, nil)
        let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        print("PROBE HIDAll services=\(services.count)")
        for s in services {
            let name = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            let page = (copyProperty(s, "PrimaryUsagePage" as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? -1
            let usage = (copyProperty(s, "PrimaryUsage" as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? -1
            var values: [String] = []
            // Only vendor sensor pages, and only the two event types known to be safe.
            if page == 0xff08 || page == 0xff00 {
                for eventType: Int64 in [25, 15] {
                    guard let event = copyEvent(s, eventType, 0, 0)?.takeRetainedValue() else { continue }
                    let f = getFloat(event, Int32(eventType << 16))
                    values.append("t\(eventType)=\(f.isFinite ? String(format: "%.4f", f) : "nan")")
                }
            }
            _ = getInt
            print("  HIDALL \(name) page=0x\(String(page, radix: 16)) usage=\(usage) \(values.joined(separator: " "))")
        }
    }

    /// Second round: where do the charging-intelligence settings live, and can we read them?
    static func runPrefs() {
        probeBatteryLevelLimits()
        probePrefs()
        probeFiles()
        print("PREF PROBES DONE")
    }

    static func probeBatteryLevelLimits() {
        typealias Fn = @convention(c) () -> Unmanaged<CFTypeRef>?
        guard let f = sym(iokit, "IOPSCopyBatteryLevelLimits", Fn.self) else { print("PROBE IOPSCopyBatteryLevelLimits: no symbol"); return }
        let v = f()?.takeRetainedValue()
        print("PROBE IOPSCopyBatteryLevelLimits = \(String(describing: v).prefix(800))")
    }

    static func describePlist(_ value: Any) -> String {
        if let data = value as? Data,
           let decoded = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            return "plist:" + String(describing: decoded).prefix(1200)
        }
        return String(String(describing: value).prefix(600))
    }

    static func probePrefs() {
        let domains = ["com.apple.powerd.charging", "com.apple.powerd", "com.apple.powerui", "com.apple.smartcharging",
                       "com.apple.smartcharging.topoffprotection", "com.apple.batteryui.charging", "com.apple.batteryui.charging.mac",
                       "com.apple.batteryui", "com.apple.BatteryCenter", "com.apple.batterycenter", "com.apple.Preferences",
                       "com.apple.springboard", "com.apple.coreduetd", "com.apple.PowerManagement", "com.apple.powerlogd",
                       "com.apple.chargingintelligence", ".GlobalPreferences", "Apple Global Domain"]
        let scopes: [(String, CFString, CFString)] = [
            ("user/anyhost", kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
            ("anyuser/currenthost", kCFPreferencesAnyUser, kCFPreferencesCurrentHost),
            ("user/currenthost", kCFPreferencesCurrentUser, kCFPreferencesCurrentHost),
        ]
        for domain in domains {
            for (label, user, host) in scopes {
                let keys = CFPreferencesCopyKeyList(domain as CFString, user, host) as? [String] ?? []
                if keys.isEmpty { continue }
                print("PREFS \(domain) [\(label)] keys=\(keys.count): \(keys.prefix(40))")
                let values = CFPreferencesCopyMultiple(nil, domain as CFString, user, host) as? [String: Any] ?? [:]
                for key in keys.prefix(40) {
                    let k = key.lowercased()
                    if k.contains("charg") || k.contains("limit") || k.contains("polic") || k.contains("smart") || k.contains("optim") || k.contains("clean") || k.contains("batter") {
                        print("  PREF \(domain).\(key) = \(describePlist(values[key] ?? "nil"))")
                    }
                }
            }
            // Direct single-value reads in case key listing is filtered but reads are not.
            for key in ["policies", "bootSessionUUID", "com.apple.batteryui.charging.mac.prior.limit", "ChargeLimit", "SmartChargingEnabled"] {
                for (label, user, host) in scopes {
                    if let v = CFPreferencesCopyValue(key as CFString, domain as CFString, user, host) {
                        print("  PREFV \(domain).\(key) [\(label)] = \(describePlist(v))")
                    }
                }
            }
        }
    }

    static func probeFiles() {
        let paths = ["/Library/Preferences/com.apple.powerd.charging.plist",
                     "/private/var/preferences/com.apple.powerd.charging.plist",
                     "/var/mobile/Library/Preferences/com.apple.powerd.charging.plist",
                     "/var/mobile/Library/Preferences/com.apple.batteryui.charging.plist",
                     "/var/mobile/Library/Preferences/com.apple.smartcharging.topoffprotection.plist",
                     "/var/mobile/Library/Preferences/com.apple.powerui.plist",
                     "/var/db/powerd", "/var/db/powerlog", "/Library/Preferences"]
        for path in paths {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
            var detail = ""
            if exists && isDir.boolValue {
                detail = "dir: \((try? fm.contentsOfDirectory(atPath: path))?.prefix(30).description ?? "unreadable")"
            } else if exists, let data = fm.contents(atPath: path) {
                detail = "read \(data.count) bytes: " + describePlist(data)
            } else if exists {
                detail = "exists, unreadable"
            }
            print("FILE \(path): exists=\(exists) readable=\(fm.isReadableFile(atPath: path)) \(detail)")
        }
    }

    static func probeIOPMBatteryInfo() {
        typealias Fn = @convention(c) (mach_port_t, UnsafeMutablePointer<Unmanaged<CFArray>?>) -> kern_return_t
        guard let f = sym(iokit, "IOPMCopyBatteryInfo", Fn.self) else { print("PROBE IOPMCopyBatteryInfo: no symbol"); return }
        var arr: Unmanaged<CFArray>?
        let kr = f(0, &arr)
        print("PROBE IOPMCopyBatteryInfo kr=\(kr) value=\(String(describing: arr?.takeRetainedValue()).prefix(600))")
    }

    static func probeAdapterDetails() {
        typealias Fn = @convention(c) () -> Unmanaged<CFDictionary>?
        guard let f = sym(iokit, "IOPSCopyExternalPowerAdapterDetails", Fn.self) else { print("PROBE IOPSCopyExternalPowerAdapterDetails: no symbol"); return }
        print("PROBE IOPSCopyExternalPowerAdapterDetails = \(String(describing: f()?.takeRetainedValue()).prefix(800))")
    }

    static func probeHID() {
        typealias CreateWithType = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> Unmanaged<CFTypeRef>?
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias SetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Void
        typealias CopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias CopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        typealias CopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
        typealias GetFloat = @convention(c) (CFTypeRef, Int32) -> Double

        let createWithType = sym(iokit, "IOHIDEventSystemClientCreateWithType", CreateWithType.self)
        let create = sym(iokit, "IOHIDEventSystemClientCreate", Create.self)
        guard let setMatching = sym(iokit, "IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = sym(iokit, "IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = sym(iokit, "IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = sym(iokit, "IOHIDServiceClientCopyEvent", CopyEvent.self),
              let getFloat = sym(iokit, "IOHIDEventGetFloatValue", GetFloat.self)
        else { print("PROBE HID: missing symbols create=\(create != nil) createWithType=\(createWithType != nil)"); return }

        var clients: [(String, CFTypeRef?)] = []
        if let create { clients.append(("create", create(kCFAllocatorDefault)?.takeRetainedValue())) }
        if let createWithType {
            for t: Int32 in [4, 2, 1, 0] {
                clients.append(("type\(t)", createWithType(kCFAllocatorDefault, t, nil)?.takeRetainedValue()))
            }
        }
        for (label, client) in clients {
            guard let client else { print("PROBE HID \(label): nil client"); continue }
            // (usage page, usage, event type): Apple vendor power sensors (current=2, voltage=3), then temperature sensors as a sanity check.
            let probes: [(Int, Int?, Int)] = [(0xff08, nil, 25), (0xff00, 5, 15)]
            for (page, usage, eventType) in probes {
                var match: [String: Any] = ["PrimaryUsagePage": page]
                if let usage { match["PrimaryUsage"] = usage }
                setMatching(client, match as CFDictionary)
                let services = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
                print("PROBE HID \(label) page=\(String(page, radix: 16)) services=\(services.count)")
                for s in services.prefix(60) {
                    let name = copyProperty(s, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
                    let usageValue = (copyProperty(s, "PrimaryUsage" as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? -1
                    var value = Double.nan
                    if let event = copyEvent(s, Int64(eventType), 0, 0)?.takeRetainedValue() {
                        value = getFloat(event, Int32(eventType << 16))
                    }
                    print("  HID \(name) usage=\(usageValue) value=\(value)")
                }
            }
        }
    }

    static func probeIOReport() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { print("PROBE IOReport: no lib"); return }
        typealias CopyAll = @convention(c) (UInt64, UInt64) -> Unmanaged<CFDictionary>?
        typealias Iterate = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
        typealias GetStr = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
        guard let copyAll = sym(lib, "IOReportCopyAllChannels", CopyAll.self),
              let iterate = sym(lib, "IOReportIterate", Iterate.self),
              let getGroup = sym(lib, "IOReportChannelGetGroup", GetStr.self),
              let getSubGroup = sym(lib, "IOReportChannelGetSubGroup", GetStr.self),
              let getName = sym(lib, "IOReportChannelGetChannelName", GetStr.self)
        else { print("PROBE IOReport: missing symbols"); return }
        guard let channels = copyAll(0, 0)?.takeRetainedValue() else { print("PROBE IOReport: CopyAllChannels nil"); return }
        var groups = Set<String>()
        var interesting: [String] = []
        var count = 0
        iterate(channels) { ch in
            count += 1
            let g = getGroup(ch)?.takeUnretainedValue() as String? ?? ""
            let sg = getSubGroup(ch)?.takeUnretainedValue() as String? ?? ""
            let n = getName(ch)?.takeUnretainedValue() as String? ?? ""
            groups.insert("\(g)/\(sg)")
            let l = (g + sg + n).lowercased()
            if l.contains("batt") || l.contains("pmu") || l.contains("charg") || l.contains("energy") || l.contains("power") || l.contains("pmp") {
                interesting.append("\(g)/\(sg)/\(n)")
            }
            return 0
        }
        print("PROBE IOReport channels=\(count) groups=\(groups.count)")
        for g in groups.sorted().prefix(80) { print("  IORG \(g)") }
        for c in interesting.prefix(120) { print("  IORC \(c)") }
    }
}
#endif
