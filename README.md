# dials

Simple personal macOS apps for solving problems I have.

| App | What it does |
| --- | --- |
| [neqMac](docs/neqMac.md) | Keeps the preferred audio input and output selected |
| [nitMac](docs/nitMac.md) | Controls an external monitor with the brightness keys |

Both run on macOS 14 or later and live in the menu bar. Download a zipped app from [Releases](https://github.com/incognitojam/dials/releases), or build and install one with `./scripts/build-app.sh --install <app>`.

Release builds are not signed with an Apple Developer ID or notarized, so macOS blocks them the first time they open. Open the app once, then allow it under **System Settings › Privacy & Security › Open Anyway**.

nitMac relies on `DisplayServices`, a private macOS framework, so a future macOS release may stop it from controlling displays.

[Development instructions](docs/development.md) · [Release instructions](docs/releases.md)
