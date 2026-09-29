# Ventilador

Fan control for Apple Silicon Macs, as a native menu bar app.

Ventilador shows live fan speeds and temperatures, lets you set a fan speed by hand or pick a temperature
profile, and always hands control back to macOS when something goes wrong.

> **Use at your own risk.** Ventilador writes to your Mac's fan controller. It clamps every request to the
> fan's safe range and falls back to automatic control on any error, but you are changing how your
> hardware is cooled. It is provided as-is, without warranty (see [LICENSE](LICENSE)). It is not affiliated
> with or endorsed by Apple.

## Features

- **Live status** in the menu bar popover: RPM per fan and CPU / GPU temperatures.
- **Manual speed** per fan, or one speed for all fans at once. Requests are always clamped to the fan's safe range.
- **Profiles** that follow temperature instead of a fixed speed:

  | Profile | Behavior (percent of the fan's safe range) |
  |---|---|
  | Quiet | 0% up to 55 °C, 100% at 100 °C |
  | Balanced | 0% up to 50 °C, 100% at 95 °C |
  | Performance | 20% from 40 °C, 100% at 85 °C |
  | Gaming | 40% from 40 °C, 100% at 70 °C: cools ahead of a sustained load |

  Profiles follow the hotter of the CPU and GPU temperatures.
- **Menu bar readouts** (optional): CPU temperature, GPU temperature and fan speed next to the icon, in °C or °F.
  The icon fills while an override is active.
- **Event log** of every mode change and manual speed change, with the fan and value.

## Requirements

- An Apple Silicon Mac with at least one fan (MacBook Pro, Mac mini, Mac Studio, Mac Pro, iMac). Fanless Macs
  such as the MacBook Air are detected and shown as read-only.
- macOS 26 or later.
- To build: Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

Tested on a Mac mini (M4 Pro). Other models expose slightly different sensors and may need tuning; please open
an issue if fan control doesn't respond on yours.

## Install

### Homebrew

```bash
brew tap ulm0/tap                    # add the tap once
brew install --cask ventilador
```

`brew install --cask ulm0/tap/ventilador` does both steps at once. Update with `brew upgrade --cask ventilador`
and remove with `brew uninstall --cask ventilador` (add `--zap` to also delete preferences and logs).

### Manual

Download `Ventilador-<version>.zip` from the [latest release](https://github.com/ulm0/ventilador/releases/latest),
unzip it and move `Ventilador.app` to `/Applications`. The app is signed with a Developer ID and notarized by Apple;
each release also publishes a `.sha256` file to check the download.

Open it, click **Enable Fan Control** in the menu bar popover, and approve Ventilador in *System Settings > General >
Login Items & Extensions*. Reading temperatures and speeds needs no approval; only changing fan speed does.

## Build and run

```bash
cd Ventilador
xcodegen generate
open Ventilador.xcodeproj      # scheme Ventilador, Run
```

By default the app is signed ad-hoc, which is enough to build and test. macOS only registers the privileged
helper (below) for a properly signed app, so to use fan control create `Ventilador/Config/Signing.local.xcconfig`
(git-ignored) with your own identity:

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOURTEAMID
```

Then click **Enable Fan Control** in the popover and approve Ventilador in *System Settings > General >
Login Items & Extensions*. Reading temperatures and speeds needs no approval; only changing fan speed does.

## How it works

- Sensors and fans are read directly from the SMC through IOKit. No kernel extensions, no private frameworks.
- Writing fan speed needs root, so the app embeds a small **privileged helper** (a launchd daemon registered
  with `SMAppService`). It is the only process that writes to the SMC, it re-clamps every request, and it only
  accepts connections from this app (code-signing requirement).
- The helper is also a **watchdog**. While you override the fans the app sends a heartbeat every second, and the
  helper returns the fans to automatic control if the app quits, crashes or hangs, the Mac sleeps, the helper
  itself is switched off, or a sensor reading goes stale. A failed revert is retried every second.
- Ventilador never persists an override: every launch starts in automatic mode.

## Tests

```bash
cd Ventilador
./scripts/check-coverage.sh
```

Runs the regression and unit suites and fails unless every source file has 100% line coverage. It must run on
real Apple Silicon hardware: a few tests read (never write) the live SMC. Regression tests, which exercise the
app-to-helper path end to end against a simulated SMC, carry most of the weight. Rules of the project: safety first, 100% coverage, regression tests over unit tests.

## Project layout

```
Ventilador/          Xcode project (generated from project.yml), sources and tests
```

## Status

Personal project. See [releases](https://github.com/ulm0/ventilador/releases) for the current version; how
releases are built and published is documented in [RELEASING.md](RELEASING.md).

## License

[MIT](LICENSE)
