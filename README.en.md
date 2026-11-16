# Mac Control Pro

A native SwiftUI monitor and fan-management app. Fully open source under MIT.

[Download](https://github.com/Hughhhhcoder/mac-control-pro/releases/latest) · [简体中文](README.md) · [Compatibility](docs/COMPATIBILITY.md) · [Contributing](CONTRIBUTING.md)

![Native Mac Control Pro interface](docs/images/dashboard.png)

## Install

Use the **universal `.pkg`** from [Releases](https://github.com/Hughhhhcoder/mac-control-pro/releases/latest) to install the app and matching helper. macOS Installer requests administrator authorization and configures the current signed-in user; no fixed UID, source checkout or Terminal command is required.

The DMG also contains the full installer. ZIP and drag-and-drop users can install, update or remove the helper through the native packages included in the app's Settings. Monitoring works without administrator access.

Requires **macOS 14 or later**. Universal downloads contain arm64 and x86_64 binaries. Default builds use ad-hoc application signing, lack a Developer ID Installer signature and are not Apple-notarized. System Settings → Privacy & Security → Open Anyway may be needed. See [installation](docs/INSTALLATION.md).

## Features

- Native navigation, system typography, light/dark appearance and menu bar access.
- Real CPU, memory, battery, thermal-state, fan and temperature readings; missing data stays unavailable.
- Per-fan capability checks, fixed RPM and temperature curves. Applied control requires manual mode and target RPM to match in the final readback after bounded target confirmation; actual RPM settling is reported separately.
- Portable presets expressed as percentages of each fan's own range; custom percentage or absolute-RPM curves, including schema 1 import compatibility.
- Session charts and CSV export, searchable sensors, JSON profiles and diagnostic snapshots.
- Chinese / English preferences, temperature units, sampling interval, launch at login and an optional power-source rule.
- Bundled `MacControlCLI` for bounded control sessions and independent JSONL readback.
- Offline operation without an account, subscription or third-party Swift dependencies.

## Compatibility and validation

Version 0.2.0 implements separate fan discovery and control, dual-fan paths relevant to M4 Pro models, protected-mode handling, desktop speed ranges for Mac mini / Mac Studio, and fanless Air monitoring. Presets adapt to each fan instead of applying a notebook's absolute RPM to every Mac.

**Implemented paths are not a guarantee that every recent Mac has been physically tested.** Physical records come from **Mac18,1 / Apple M6 / macOS 27.0**: version 0.1.1 covers fixed speeds, curves, automatic recovery and lost-client lease expiry; an early 0.2.0 candidate also has CLI fixed-speed, curve, lease-expiry and competing-session rejection records. Each result applies to the tested build. M4 Pro, Mac mini, Mac Studio, other Mac models and Intel writes remain covered by simulated code paths, without physical pass records on those machines.

[Compatibility matrix](docs/COMPATIBILITY.md) · [Hardware evidence](docs/HARDWARE_VALIDATION.md) · [Test scope](docs/TESTING.md)

The app distinguishes a missing or outdated helper, unavailable readings, read-only fans, pending requests and confirmed application. P2 sessions bind renewal and release to their owner. Losing a lease or encountering a protection condition does not silently replay the previous target. SMC is undocumented; firmware may reject writes or recovery. See [helper design](docs/HELPER.md).

## Build

Requires Xcode / Command Line Tools with Swift 5.9 or later:

```bash
git clone https://github.com/Hughhhhcoder/mac-control-pro.git
cd mac-control-pro
swift test
./scripts/build-release.sh
```

`dist/` contains the app, full PKG, ZIP, DMG and checksums. Set `ARCHS=arm64` for an Apple Silicon-only build. Use `MacControlPro --diagnose` for real hardware JSON, or `--demo` for explicitly labeled sample UI data. [CLI commands](docs/CLI.md) · [Release process](docs/RELEASING.md)

Independent of CrystalIDEA, Macs Fan Control and Apple. No proprietary binaries, source or assets from those products are redistributed.
