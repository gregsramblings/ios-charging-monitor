# ios-charging-monitor

ChargeSpeed: live charging power on an iPhone, read from the phone's PMU and charger sensors via
private APIs. Build it yourself, install on your own phone. Cannot ship on the App Store because of the private
APIs it uses (see below).

<img src="docs/screenshot.png" width="360" alt="ChargeSpeed showing 27.86 W from a USB-C charger, 25.92 W into the battery, 14.20 V at 1.96 A, 55% charged, session peak 31.70 W, adapter negotiated 15 V × 3 A, thermal state nominal with battery, charger, and SoC temperatures">

## Why

To compare chargers and cables. iOS shows a lightning bolt and nothing else. Seeing the wattage
exposed a few bad charging setups I'd been using. On a wireless charger it shows the profile iOS
reports and the watts that actually reach the battery, which don't always match.
And it finds the sweet spot on a wireless charger with no magnets, like a car tray: slide the phone
around with the live watts on screen until the number peaks.

## What it shows (verified on iPhone 17 Pro Max / iOS 26 and iPhone 18 Pro Max / iOS 27)

- Watts from the charger, 1 s updates, sparkline. USB-C input voltage × current. On MagSafe no
  readable sensor reports input current, so the headline is watts into the battery instead. On
  battery power the headline is blank: no readable sensor reports discharge current.
- Watts into the battery, battery voltage and current.
- Peak watts for the current charge, kept on screen after unplugging, reset at the next plug-in.
- Adapter name, negotiated USB-PD profile, full profile list.
- Temperatures: battery, the charger sensor (TQ0j), the hottest PMU die sensor, and iOS's thermal
  state. A red line appears at serious or critical, where Apple says performance may be reduced.
  No CPU or SoC sensor is exposed on these phones.
- The battery gauge publishes four temperature keys (TG0B, TG0C, TG0H, TG0V). Three agree within
  0.1 °C. TG0B reads 1 to 13 °C higher while charging. Apple doesn't document what each one
  measures. Earlier builds showed the hottest key as the battery, so a phone whose other three
  keys read 27 °C showed 40 °C. The battery row is now the median of the four, and TG0B gets its
  own row when it stands out. Amber at 38 °C and red at 42 °C are the app's thresholds, not Apple's.
- Percent, charging state, low power mode.
- A charging hold below 100 % (Optimized Battery Charging or charge limit), inferred from behaviour.
- Raw sensor and dictionary dumps, collapsed.

## What iOS hides from apps

Tried and blocked by the sandbox on iOS 26 and 27; the simulator shows them because it reads the Mac:

- Battery health, cycle count, mAh capacity, design capacity (IOKit registry filtered to two keys).
- Optimized Battery Charging, charge limit, and Clean Energy Charging settings (PowerUI XPC denied).
- powerd's "Charging On Hold" status and time-to-empty (privileged, or always 0).
- Discharge current on battery: no readable sensor reports it, so no time-to-empty from power.

Details in [CLAUDE.md](CLAUDE.md).

## iPhone 18 Pro Max reads half above ~30 W

Measured on an iPhone 18 Pro Max, iOS 27, with a 45 W adapter that has a built-in wattage display.
Battery at 55 %. Five side-by-side readings over four minutes:

| Display charger | App | Ratio |
|---|---|---|
| 33.8 W | 18.4 W | 0.54 |
| 43.8 W | 22.0 W | 0.50 |
| 43.8 W | 21.8 W | 0.50 |
| 42.3 W | 21.4 W | 0.51 |
| 38.2 W | 18.4 W | 0.48 |

At the peak the input current sensor read 1.50 A of a 3.00 A contract. The battery current
sensor dropped by about half at the same moment. No other readable sensor changed.

Two users of [MiniWatts](https://github.com/ResistanceTo/MiniWatts), another app that reads the
same sensors, report the same on their 18 Pro Max using charger displays and a USB-C meter. One
saw 14.55 V × 2.99 A on the meter while the sensor read 1.51 A. Both say readings matched at
lower power: at 14 W and 26 W in one report, up to about 30 W in the other. One says the half
reading began after a brief dropout near 30 W. Our capture shows the same dropout: one second at
8 W, then half.

The numbers fit a second charging path that the sensors don't cover. That is an inference. Apple
doesn't document it. Not yet known: whether other adapters behave the same, and whether the
reading recovers before unplugging. The 17 Pro Max was never compared against a meter.

The app does not correct the number, because it cannot tell from its sensors when the phone is in
that mode. On an iPhone 18 Pro or Pro Max connected to an adapter that can supply more than 30 W,
it shows an orange note under the headline pointing here.

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
