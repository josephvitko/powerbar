# PowerBar

A minimal macOS menu bar app that shows how much power your MacBook is drawing, live.

```
 9.6W · 29Wh     ← battery draw · energy left
 +45W · 29Wh     ← charging power on AC
```

Click it for:

- **Battery** — energy left and full capacity in watt-hours (no percentages), time remaining (Wh ÷ your recent average draw), 1‑min / 5‑min average draw. Wh in the menu bar can be turned off.
- **Sparkline** — battery draw over the last 10 minutes
- **USB-C devices** — power the Mac is supplying to a charging phone or other accessory, split out from the Mac's own draw, with time left if you unplugged it
- **Health** — maximum capacity (matches System Settings), cycle count, temperature
- **Apps** — per-app CPU power (watts) and GPU usage (%), with helper processes grouped under their app (e.g. all of Firefox's tab processes count as "Firefox")
- **Preventing sleep** — apps holding sleep assertions, such as a browser tab's video wake lock, `caffeinate`, or an app holding the audio output open
- **Low Power Mode** — Never / Only on Battery / Always, same as System Settings (asks for your admin password). The menu bar text turns yellow while it's on.
- **Drain alerts** — an optional notification when draw stays above a threshold (10–30 W, sustained for 2/5/10 min). It ignores power sent to USB-C devices, fires once per episode, re-arms only after draw drops, and never more than once every 30 minutes. It can be turned off.

It runs with no dependencies or root access, and uses ~0% CPU and ~25 MB of RAM.

## Install

Requires macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/josephvitko/powerbar.git
cd powerbar
./build.sh
```

`build.sh` compiles the app, ad-hoc signs it, installs it to `~/Applications/PowerBar.app`, and launches it. Turn on **Launch at Login** from the menu to keep it running after restarts.

## How it works

| Reading | Source |
| --- | --- |
| Battery watts | `InstantAmperage × Voltage` from the `AppleSmartBattery` IOKit service |
| Per-app CPU watts | Δ`ri_energy_nj` from `proc_pid_rusage` (the counters Activity Monitor uses), over a 30 s window |
| Per-app GPU % | Δ`accumulatedGPUTime` of each `IOAccelerator` user client in the IORegistry |
| Watt-hours | `AppleRawCurrentCapacity` / `NominalChargeCapacity` (mAh) × present pack voltage |
| USB-C devices | `PowerOutDetails` (per-port milliwatts) on `AppleSmartBattery` |
| Sleep blockers | `IOPMCopyAssertionsByProcess`, attributing audio assertions to the app actually playing |

Caveats:

- The battery gauge refreshes its current reading roughly once a minute, so the menu bar number moves in steps. The averages are the better guide.
- Watt-hours use the present pack voltage, so they read a few % high near full and a few % low near empty. They can differ from macOS's percentage, which is smoothed.
- On AC power it shows charging power, not total system power (that would need `powermetrics` and root).
- The per-app list won't add up to the battery number. It excludes the display backlight (often the biggest draw), macOS doesn't expose per-app GPU *power* (only GPU busy time), and CPU energy for system daemons like WindowServer isn't readable without root. Their GPU use does show up.

## License

MIT
