# Shay

Alpha macOS CLI for keeping a MacBook reachable over SSH with its lid closed.
Shay enables `SleepDisabled` behind a root-owned safety guard.

```text
  ◆ shay      ● ONLINE                                  ╔════════════╗
  ────────────────────────────────────────              ║ ┌────────┐ ║
  Sleep       disabled · awake                          ║ │  O.O   │ ║
  Power       AC Power · 78%                            ║ └────────┘ ║
  Thermal     nominal                                   ╚════════════╝
  Guard       ≤25% battery · serious+ thermal
  Expiry      4h
  Watchdog    healthy · 3s ago
  Last event  active
```

The face is `O.O` while awake, `-_-` while normal sleep is active, and `!.!`
when requested and observed power states disagree.

## Safety

Shay restores normal sleep when:

- battery reaches 25%;
- thermal pressure becomes serious or critical;
- a battery or thermal reading is unavailable.

Every power-policy change is read back and verified. Failed restoration stays
armed for retry every 15 seconds. This is still software: never leave a closed,
awake MacBook in a bag or other unventilated space.

## Install

Requires macOS 13+ and Xcode Command Line Tools.

```sh
./test.sh
sudo ./install.sh
```

The compiler step shows a spinner and elapsed time in interactive terminals.
The installed CLI has no Python, shell, Homebrew, or third-party runtime
dependency.

## Use

```sh
shay -on
shay -on --for 4h
shay -on --until 23:00
shay -status
shay -off
```

`--for` accepts minutes, hours, or days (`30m`, `4h`, `2d`). `--until` uses
local 24-hour time and rolls to tomorrow when that time has already passed.
Expiry is enforced on the next 15-second guard check.

Disable status colors with `NO_COLOR=1 shay -status`.

## Remove

```sh
sudo ./uninstall.sh
```

Emergency sleep reset:

```sh
sudo pmset -a disablesleep 0
```

See [SECURITY.md](SECURITY.md) before changing the root helper. MIT licensed.
