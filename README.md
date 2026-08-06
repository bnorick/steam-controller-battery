# steam-controller-battery

I think it's silly that there isn't an easy way to check the battery level of a connected Steam Controller from the desktop, so this repository contains Windows utilities for reading Steam Controller battery state through SDL3. It doesn't work for everything (see below), but it's good enough for me.

![System tray icon example](assets/screenshot.png)

Left click to trigger a refresh, right click for a menu (refresh, launch at startup, quit).

You can [download](https://github.com/bnorick/steam-controller-battery/releases/latest) binaries for the latest release. This repo currently builds two Windows executables (build them yourself if you don't trust my binaries, it's easy):

- `steam-controller-battery.exe`: console app for enumerating SDL gamepads and printing battery information
- `steam-controller-battery-tray.exe`: Windows tray app that shows Steam Controller battery state in the notification area

Using `steam-controller-battery` to test, I observe the following with a single controller connected:
| Connection method | Status |
|-------------------|--------|
| via puck          | **Working** (*) |
| via USB (direct)  | Not working (**) |
| via Bluetooth     | Untested |

- \* — reports wired, on battery, and correct battery percent
- \** — reports wired, charged, and 100%

I don't know what happens with multiple controllers connected to the puck, it probably just gets stats for one. 

## Recommended build environment

- [mise](https://mise.jdx.dev/)
- WSL

`mise.toml` pins the Zig toolchain used by the project, running `mise install` will install the requisite Zig dependency.

## Build

I build this project in WSL2 (Ubuntu 24.04) and cross-compiles a Windows binary.

```bash
mise run build
```

That produces Windows binaries under:

```text
zig-out/bin/
```

The main artifact for normal use is:

```text
zig-out/bin/steam-controller-battery-tray.exe
```

There is also a helper task for building SDL's upstream controller test app:

```bash
mise run build-sdl-test
```

## Run On Windows

After building in WSL, copy the `.exe` you want to use from `zig-out/bin/` to Windows and run it there.

Example:

```powershell
steam-controller-battery-tray.exe --interval 15000 --battery-wait-ms 5000
```

Useful tray app flags:

- `--interval <ms>`: how often to refresh battery state, default `60000`
- `--battery-wait-ms <ms>`: how long to wait for battery telemetry before giving up, default `10000`
- `--enable-autostart`: register the tray app in the current user's Windows startup entries and exit
- `--disable-autostart`: remove the tray app from the current user's Windows startup entries and exit

## Console Tool

The console binary can be useful for diagnostics:

```powershell
steam-controller-battery.exe --diagnostics --battery-wait-ms 5000
```

Useful console app flags:

- `--watch`: continuously refresh output
- `--interval <ms>`: refresh interval for watch mode, default `5000`
- `--battery-wait-ms <ms>`: wait for battery telemetry, default `3000`
- `--diagnostics`: print SDL revision and backend hint information

## Notes

- The tray app is only built when targeting Windows.
- The current tray implementation looks specifically for the physical Steam Controller puck USB ID (`28de:1304`).
