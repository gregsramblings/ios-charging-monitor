# ios-charging-monitor

ChargeSpeed: live charging power on an iPhone, read from the phone's PMU and charger sensors via
private APIs. Build it yourself, install on your own phone. Cannot ship on the App Store because of the private
APIs it uses (see below).

<img src="docs/screenshot.png" width="360" alt="ChargeSpeed showing 27.86 W from a USB-C charger, 25.92 W into the battery, 14.20 V at 1.96 A, 55% charged, session peak 31.70 W, adapter negotiated 15 V × 3 A, thermal state nominal with battery, charger, and SoC temperatures">

## Why

To compare chargers and cables. iOS shows a lightning bolt and nothing else. Seeing the wattage
exposed a few bad charging setups I'd been using. It also shows what a wireless charger actually
negotiates (for example MagSafe 15 W versus Qi 7.5 W) and what reaches the battery.
And it finds the sweet spot on a wireless charger with no magnets, like a car tray: slide the phone
around with the live watts on screen until the number peaks.

## What it shows (verified on iPhone 17 Pro Max / iOS 26 and iPhone 18 Pro Max / iOS 27)

- Watts from the charger, 1 s updates, sparkline. USB-C input voltage × current. On MagSafe there
  is no input current sensor, so the headline is watts into the battery instead.
- Watts into the battery, battery voltage and current.
- Peak watts for the current charge, kept on screen after unplugging, reset at the next plug-in.
- Adapter name, negotiated USB-PD profile, full profile list.
- Temperatures: battery, charger junction, hottest SoC die. iOS thermal state, with a red
  "Throttling" line when it reaches serious or critical; battery turns amber at 38 °C, red at 42 °C.
- Percent, charging state, low power mode.
- A charging hold below 100 % (Optimized Battery Charging or charge limit), inferred from behaviour.
- Raw sensor and dictionary dumps, collapsed.

## Not available on iPhone

Tried and blocked by the sandbox on iOS 26 and 27; the simulator shows them because it reads the Mac:

- Battery health, cycle count, mAh capacity, design capacity (IOKit registry filtered to two keys).
- Optimized Battery Charging, charge limit, and Clean Energy Charging settings (PowerUI XPC denied).
- powerd's "Charging On Hold" status and time-to-empty (privileged, or always 0).
- Discharge current on battery: no sensor exists, so no time-to-empty from power.
- iPhone 18 Pro / Pro Max above about 30 W wired: the phone adds a second charge path with no
  sensor, and input and battery readings show half the true value (43.8 W on a display charger,
  21.9 W read). The app flags it when the metered path sits at half the PD contract and prints the
  doubled estimate; it never alters the headline number.

Details in [CLAUDE.md](CLAUDE.md).

## Versus App Store "charging speed" apps

There are apps on the App Store that claim to show charging wattage. They can't read the sensors,
because Apple doesn't expose them to third-party apps, so they guess: watch the battery percentage
tick up, multiply by the battery's rated capacity, divide by time. That's close enough on a good
day, minutes behind at best, and wrong whenever the phone throttles or pauses charging. I wanted
the real number.

This reads the sensors. The same estimate is kept as a fallback ("% rate"). Private APIs are why
this can't be published: Guideline 2.5.1, and TestFlight scans too.

## IPA

Unsigned, in [Releases](https://github.com/gregsramblings/ios-charging-monitor/releases). Sign it with
your own Apple ID using any sideloading tool (AltStore, Sideloadly, and similar). Free Apple ID
signatures last 7 days, paid developer accounts one year. The app needs no entitlements, so nothing
special is required. I don't provide support for the sideloading step; use the tool's own docs.

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
