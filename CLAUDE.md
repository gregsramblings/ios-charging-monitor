# ChargeSpeed (ios-charging-monitor)

Personal dev-only iPhone app: live charge power in watts from private APIs. Not App Store safe.

## Build and deploy

- XcodeGen project: `xcodegen generate` after editing `project.yml` or adding files.
- Scheme `ChargeSpeed`, bundle id `com.gregwilson.chargespeed`, team in `project.yml`.
- Runs on iPhone 17 Pro Max (iOS 26) and iPhone 18 Pro Max (iOS 27) with the same sensor names. `batteryWattHours` is per model (hw.machine).
- Deploy: `/deploy-to-iphone`. Console-attached launch (phone unlocked):
  `xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.gregwilson.chargespeed`
- Simulator runs but IOKit calls hit the Mac, so it shows the Mac's battery.
- Release IPA: `.github/workflows/release.yml` builds an unsigned IPA on any `v*` tag and attaches it to a
  GitHub release. To ship: bump `MARKETING_VERSION` in `project.yml`, `git tag vX.Y.Z && git push origin vX.Y.Z`.
  Keep it unsigned; a signed IPA embeds the team, certificate, and registered device UDIDs.

## Code

- `IOKitBattery.swift`: dlsym'd IOKit. `IOPMPowerSource` registry (sandbox leaves 2 keys on iOS), powerd `IOPSCopyPowerSourcesInfo`, `IOPSCopyExternalPowerAdapterDetails`, `IOPSCopyChargeStatus` (always refused).
- `HIDSensors.swift`: `IOHIDEventSystemClient`, usage page 0xff08 (usage 2 = A, 3 = V), 0xff00/5 = temps. One client per process; created once. Services are `AppleSMCKeysEndpoint`; `LocationID` is the ASCII SMC key (0x49513075 = "IQ0u"), read into `Reading.key`. Look sensors up by key, not product name: names repeat across keys ("PMU tdie1" is TP1b and TP1l).
- iOS 27 publishes every key through two services with the same LocationID. Tested 2026-10-18: one service read twice 2 ms apart varies as much as the two copies differ (IQ0u 0.94 → 1.11 A, IQ0B ±10 %), and the static ALS key reads identically on both. The copies are one signal; `PowerSnapshot.sensor(key:name:)` averages them, never sums. MiniWatts users with meters also report one copy matching the meter at 14–30 W.
- Each read is a fresh, noisy sample, so IQ0u and IQ0B are averaged over 4 reads per refresh (halved battery-watts tick-to-tick spread in a 90 s test; no effect on the input headline, whose swings are real). A full `read()` of all 123 services takes ~116 ms on the main actor, ~2 ms per power key; oversampling these two keys should add ~30 ms (estimated from the per-read cost, not measured).
- iOS 27 PMU rail keys `IP3l/4l/5l/7l/9l` (`ildo*`) and most `VP*b`/`VP*l` (`vbuck*`/`vldo*`) read 14,800–16,450 or below −17,000 on every sample; readings with |value| ≥ 1000 are dropped. None feed computed values.
- `PowerSnapshot.swift`: merges sources. Headline = VQ0u × IQ0u (USB-C input). IQ0B × VQ0l = into battery. IQ0B reads 0 on battery power, so battery current and watts are nil when unplugged and the headline is blank (no readable discharge sensor). VQ1u = wireless input rail (MagSafe ≈14 V, a Qi BPP pad 9.85 V; adapter description "magsafe chg" vs "baseline arcas"). No readable wireless input current, so on wireless the headline is battery watts. iOS's wireless "Watts" is a profile label: a Qi pad reported 4 W while 6.3–6.8 W reached the battery.
- Temperatures: `gas gauge battery` ×4 = TG0B/TG0C/TG0H/TG0V. Three agree within 0.1 °C; TG0B reads 1–13 °C above them while charging (seen 39.8 vs 27 °C). What each key measures is undocumented; battery = median, and the hottest key gets its own row when > 1.5 °C above the median. `Charger TQ0j` shown as "Charger (TQ0j)". `PMU tdie*` (TP*b, TP*l) are PMU sensors; no CPU/SoC-named sensor exists on the 17 or 18 Pro Max (an iPhone 11 does expose pACC/SOC sensors). `PMU tcal` is a constant 51.8 °C. `WQ0u`/`QQ0u` are integrators that reset every ~7 s, not live readings.
- Thermal line = `ProcessInfo.thermalState` serious/critical. Apple's wording: serious is "high" with performance possibly affected; critical significantly reduces performance. It does not say "throttled". Battery amber ≥38 °C, red ≥42 °C are the app's own thresholds.
- Adapter `UsbHvcMenu` entries with 65535 mV/mA are placeholders iOS did not decode (fixed PDOs max out at 51.15 V / 10.23 A); shown as "values not reported".
- `PowerMonitor.swift`: 1 s poll, %-rate fallback (`batteryWattHours` is rated capacity per model), hold detection with 45 s debounce, peak of the headline watts per charging session (median of last 3 samples; resets at plug-in, survives full/top-off and relaunch via persisted session identity: adapter serial + last-seen plugged/percent; manual reset button).
- `SmartCharge.m`: PowerUI client, blocked on iOS, kept for macOS/entitled builds. `Probes*.swift/.m`: DEBUG exploration only, not called.

## iPhone 18 Pro Max half reading (measured 2026-10-18)

Measured: display charger vs app over 4 min at 15 V × 3 A, battery 55 %: 33.8/18.4, 43.8/22.0, 43.8/21.8, 42.3/21.4, 38.2/18.4 W (ratio 0.48–0.54). Onset: input ramped to ~23 W and paused with IQ0u ≈ 1.5 A for ~7 s, read 30 W for 2 s, 8 W for one tick, then half (IQ0u 1.50 A of a 3.00 A contract). IQ0B dropped by half at the same tick. No other readable sensor changed. The adapter dictionary was not logged per tick during the split; check `PMUConfiguration` (3000 at 13–20 W) and `UsbHvcHvcIndex` next time.

Third-party (MiniWatts issues #10 and the Mionx-II report, iPhone19,7): 45 W display vs 21.6 W app; meter 14.55 V × 2.99 A vs IQ0u 1.513 A (both copies). Readings matched at 14 W and 26 W after a reconnect, and "up to about 30 W" before a brief dropout, after which they were half, including after power fell back to ~30 W.

Inference, not verified: a second charging path without SMC keys. Unknown: behaviour with other adapters or contracts, whether it recovers before unplug (one unsourced report says above 70 %), whether the 18 Pro (iPhone19,2) does it. The 17 Pro Max was never compared with a meter.

App behaviour: no correction. `PowerSnapshot.mayReadHalf` (iPhone19,x, wired, negotiated profile > 30 W) shows a caution. An earlier detector (metered current within 5 % of contract/2 for 10 s, then doubled the number) was removed: it only fires when the adapter is the limit, and the single-path onset pause at 1.5 A for ~7 s came within 3 s of a false positive.

powerd `Current Capacity` has only been seen in 5 % steps on the 18 Pro Max / iOS 27 (55 → 60 → 65, 80), so the %-rate estimator and hold threshold work on 5 % data there.

Writing rule for README and these notes: state what was measured, by whom, on which device. Mark anything else as inference.

## Verified blocked on iOS 26 and 27 (don't retry)

IOKit battery registry keys beyond `BatteryInstalled`/`ExternalConnected`; `IOReport`; `IOPMCopyBatteryInfo`;
`IOPSCopyChargeStatus`, `IOPSCopyBatteryLevelLimits`, `IOPSCopyPowerSourcesInfoPrecise` (all kIOReturnNotPrivileged);
PowerUI XPC (Optimized Charging / charge limit settings); CFPreferences of other domains; powerd `Time to Empty` (always 0);
any discharge-current sensor (IQ0B reads 0 on battery; nothing else in the 75 (iOS 26) or 123 (iOS 27) services reports it). Darwin notify `smartchargestatuschanged` state is always 0.
