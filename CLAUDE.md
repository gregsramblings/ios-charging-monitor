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
- `HIDSensors.swift`: `IOHIDEventSystemClient`, usage page 0xff08 (usage 2 = A, 3 = V), 0xff00/5 = temps. One client per process; created once. Services are `AppleSMCKeysEndpoint`; `LocationID` is the ASCII SMC key (0x49513075 = "IQ0u"). iOS 27 publishes every key through two endpoints, so each name appears twice with the same LocationID: one sensor sampled twice, never sum them. iOS 27 also adds PMU rail keys (`ildo*`, `vbuck*`, `vldo*`) that read 15,000 A / 16,000 V; readings ≥1000 are dropped.
- `PowerSnapshot.swift`: merges sources. Headline = `Charger VQ0u × IQ0u` (USB-C input). `IQ0B × VQ0l` = into battery. `VQ1u` = wireless coil rail voltage (MagSafe ≈14 V, Qi BPP pad ≈10 V; adapter description "magsafe chg" vs "baseline arcas") (no wireless input current sensor exists, so MagSafe input watts are unavailable; headline falls back to battery watts). `gas gauge battery` ×4 = SMC keys TG0B/TG0C/TG0H/TG0V; three agree (cell), TG0B runs 3–11 °C hotter under charge current (gauge board near the connector), so battery temp is the median and TG0B is shown separately as the hotspot. `Charger TQ0j`, `PMU tdie*` = temps. `WQ0u`/`QQ0u` are input energy/charge integrators that reset every ~7 s (ratio ≈ VQ0u), not live readings. Throttling flag = `ProcessInfo.thermalState` serious/critical; battery colored ≥38 °C amber, ≥42 °C red.
- `PowerMonitor.swift`: 1 s poll, %-rate fallback (`batteryWattHours` = 19.7 for 17 Pro Max), hold detection with 45 s debounce, peak of the headline watts per charging session (median of last 3 samples; resets at plug-in, survives full/top-off and relaunch via persisted session identity: adapter serial + last-seen plugged/percent; manual reset button).
- `SmartCharge.m`: PowerUI client, blocked on iOS, kept for macOS/entitled builds. `Probes*.swift/.m`: DEBUG exploration only, not called.

## iPhone 18 Pro second charge path (verified 2026-10-18)

Above ~30 W wired the 18 Pro Max splits charging across two paths; only path 0 has SMC keys. Display charger vs app over 4 min at 15 V × 3 A: 33.8/18.4, 43.8/22.0, 43.8/21.8, 42.3/21.4, 38.2/18.4 W (ratio 0.48–0.54). Onset: input ramps to ~23 W and pauses with `IQ0u` ≈ 1.5 A for ~7 s, jumps to 30 W for 2 s, dips to 8 W for one tick, then sits at exactly half the contract (1.50 A of 3.00 A); `IQ0B` halves too. No other sensor of the 123 moves; `WQ0u`/`QQ0u` integrate the metered path only. Detector in PowerMonitor: iPhone19,x + metered current within 5 % of contract/2 for 10 s → `unmeteredPathEngaged`; cleared on unplug or current > 0.58 × contract. Known gap: a return to single path at high charge while drawing little leaves the flag set until unplug (one report says readings are correct again above 70 %).

powerd `Current Capacity` steps in 5 % increments on iOS (55 → 60 → 65), so the %-rate estimator and hold threshold work on 5 % data.

## Verified blocked on iOS 26 and 27 (don't retry)

IOKit battery registry keys beyond `BatteryInstalled`/`ExternalConnected`; `IOReport`; `IOPMCopyBatteryInfo`;
`IOPSCopyChargeStatus`, `IOPSCopyBatteryLevelLimits`, `IOPSCopyPowerSourcesInfoPrecise` (all kIOReturnNotPrivileged);
PowerUI XPC (Optimized Charging / charge limit settings); CFPreferences of other domains; powerd `Time to Empty` (always 0);
any discharge-current sensor (none exists in the 75 HID services). Darwin notify `smartchargestatuschanged` state is always 0.
