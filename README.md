# PowerBar

A minimal macOS menu bar app that shows how much power your MacBook is drawing, live.

```
 9.6W · 29Wh     ← battery draw · energy left
 +45W · 29Wh     ← charging power on AC
```

Click it for a panel (like Control Center) with:

- **Now** — battery draw in watts, energy left in watt-hours (no percentages), and time left from Wh ÷ your recent average draw. When the Mac is charging a phone or other USB-C device, the draw is split into Mac vs USB-C, with time left if you unplugged it.
- **History** — a chart of battery draw over the last **10 min** or **24 h**, and a **7-day** bar chart of watt-hours used per day (split into Mac vs USB-C devices). Time on power is shaded; your drain-alert threshold is drawn as a dashed line. One-minute averages are kept for 30 days in `~/Library/Application Support/PowerBar/history.csv`.
- **Apps** — per-app CPU power (watts) and GPU usage (%), with helper processes grouped under their app (e.g. all of Firefox's tab processes count as "Firefox")
- **Keeping awake** — apps holding sleep assertions, such as a browser tab's video wake lock, `caffeinate`, or an app holding the audio output open
- **Health** — full-charge capacity vs. new (in Wh), cycle count, temperature

The gear menu has:

- **Low Power Mode** — Never / Only on Battery / Always, same as System Settings (asks for your admin password). The menu bar text turns yellow while it's on.
- **Drain alerts** — an optional notification when draw stays above a threshold (10–30 W, sustained for 2/5/10 min). It ignores power sent to USB-C devices, fires once per episode, re-arms only after draw drops, and never more than once every 30 minutes.
- **Show Wh in Menu Bar**, **Launch at Login**, **Open Activity Monitor**

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
