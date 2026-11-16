# Third-party notices

Mac Control Pro source code is distributed under the MIT License in `LICENSE`.

## System frameworks and tools

The application uses Apple-provided frameworks and SDKs, including SwiftUI, AppKit, Charts, Foundation, IOKit and system services, under their respective Apple SDK / platform terms. These frameworks are supplied by macOS rather than bundled as third-party source dependencies.

GitHub workflows use `actions/checkout` and `actions/upload-artifact` from their respective open-source repositories. They are CI services, not components shipped inside the application.

## Independent implementation

Macs Fan Control is a separate product of CrystalIDEA. This repository contains no redistributed Macs Fan Control app, commercial source, extracted resources, logos or helper binaries. Product names are used only to explain the project's inspiration. Mac Control Pro is not affiliated with or endorsed by CrystalIDEA or Apple.

The SMC protocol and hardware behavior are undocumented platform details. Any future copied or adapted third-party source must be listed here with its source and license before merging. Merely linking a reference does not authorize copying it.

## Protocol research references

The independent implementation consulted [SMCKit](https://github.com/beltex/SMCKit), [macos-smc sensor key notes](https://github.com/sebhildebrandt/macos-smc/blob/main/docs/smc-keys.md), and [iSMC sensor mappings](https://github.com/dkorunic/iSMC/blob/master/smc/sensors.go) to cross-check protocol facts and sensor meanings. No source files from these projects are included.
