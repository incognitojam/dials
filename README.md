# dials

Simple personal macOS apps for solving problems I have.

| App | What it does |
| --- | --- |
| [neqMac](docs/neqMac.md) | Keeps the preferred audio input and output selected |
| [nitMac](docs/nitMac.md) | Controls an external monitor with the brightness keys |

Both run on macOS 14 or later and live in the menu bar. Build and install one with `./scripts/build-app.sh --install <app>`.

nitMac relies on `DisplayServices`, a private macOS framework, so a future macOS release may stop it from controlling displays.

[Development instructions](docs/development.md) · [Release instructions](docs/releases.md)
