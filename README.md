# ios-charging-monitor

ChargeSpeed: live charging power on an iPhone, read from the phone's PMU and charger sensors via
private APIs. Build it yourself, install on your own phone. Cannot ship on the App Store because of the private
APIs it uses (see below).

<img src="docs/screenshot.png" width="360" alt="ChargeSpeed showing 20.39 W from a USB-C charger, 18.33 W into the battery, 14.31 V at 1.43 A, 50% charged, adapter negotiated 15 V × 3 A, battery and charger temperatures">

## Why

To compare chargers and cables. iOS shows a lightning bolt and nothing else. Seeing the wattage
exposed a few bad charging setups I'd been using.

## What it shows (verified on iPhone 17 Pro Max, iOS 26)

- Watts from the charger, 1 s updates, sparkline. USB-C input voltage × current.
- Watts into the battery, battery voltage and current.
- Adapter name, negotiated USB-PD profile, full profile list.
- Temperatures: battery, charger junction, charger die, hottest SoC die.
- Percent, charging state, low power mode.
- A charging hold below 100 % (Optimized Battery Charging or charge limit), inferred from behaviour.
- Raw sensor and dictionary dumps, collapsed.

## Not available on iPhone

Tried and blocked by the sandbox on iOS 26; the simulator shows them because it reads the Mac:

- Battery health, cycle count, mAh capacity, design capacity (IOKit registry filtered to two keys).
- Optimized Battery Charging, charge limit, and Clean Energy Charging settings (PowerUI XPC denied).
- powerd's "Charging On Hold" status and time-to-empty (privileged, or always 0).
- Discharge current on battery: no sensor exists, so no time-to-empty from power.

Details in [CLAUDE.md](CLAUDE.md).

## Versus App Store "charging speed" apps

They estimate from the percent climb times rated capacity: minutes of delay, battery side only,
wrong under throttling or holds. This reads the sensors. The same estimate is kept as a fallback
("% rate"). Private APIs are why this can't be published: Guideline 2.5.1, and TestFlight scans too.

## Build and install

Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen). A free Apple ID is enough; no paid
Apple Developer Program membership needed.

```bash
xcodegen generate
open ChargeSpeed.xcodeproj
```

1. Target → Signing & Capabilities → your team (or `DEVELOPMENT_TEAM` in `project.yml`, regenerate).
2. Phone: Settings → Privacy & Security → Developer Mode.
3. Run.
4. First launch: Settings → General → VPN & Device Management → trust.

Free Apple ID: 7-day expiry, 3 sideloaded apps, own devices only. Paid Apple Developer Program:
1-year signing, ad hoc distribution to 100 devices. Simulator works but reads the Mac's battery.

Private APIs can change or disappear in any iOS update.

## License

MIT. See [LICENSE](LICENSE).
