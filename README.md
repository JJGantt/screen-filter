# screen-filter

A warm, dimmable filter for every screen on the Mac (built-in and external), plus a DDC CLI.
It replaces Night Shift, which is turned off on this Mac so the two tints do not stack.

| binary | what it does |
|---|---|
| `screenfilter` | Background daemon + CLI. Tints and dims each display through the GPU gamma tables. |
| `ddc` | Reads/sets a monitor's own settings (VCP codes, e.g. `0x10` brightness) over DDC/CI. |

## screenfilter

    screenfilter status
    screenfilter auto                  # warm from sunset to sunrise
    screenfilter on | off              # warm always / never
    screenfilter warmth 0-100          # 0 = no tint, 100 = 1900K; both screens
    screenfilter brightness 10-100     # external display output, day and night
    screenfilter laptop-brightness 10-100   # built-in screen output, on top of its backlight

The daemon also owns the menu bar icon (`◐` while the screens are tinted, `○` while not, so `○` in
`auto` during the day). The Auto item shows the next switch time. The menu has mode, warmth and per-screen brightness
submenus, and Quit. The menu is rebuilt from the config each time it opens and a choice saves the
config, so the menu, the CLI and a hand edit of the file all go through the same path. Quit restores
the screens; launchd restarts the daemon after a crash but not after a clean quit, so it comes back
at the next login (or `launchctl kickstart gui/$(id -u)/com.jaredgantt.screen-filter`).

Settings live in `~/.config/screen-filter/config.json`; the CLI writes it and the daemon picks the
change up from a directory watch. A key missing from the file keeps its default.

How it stays applied:

- A gamma table lasts only as long as the process that set it, so the daemon runs under launchd
  (`com.jaredgantt.screen-filter`, restarted on a crash) and restores the default tables when stopped.
- macOS resets the tables on display reconfiguration and wake; the daemon reapplies on
  `CGDisplayRegisterReconfigurationCallback` and the NSWorkspace wake notifications.
- In `auto`, it computes sunset and sunrise itself (NOAA approximation) for `latitude`/`longitude` in the
  config and sleeps on a wall-clock timer to exactly the next one.
- The coordinates follow the Mac: CoreLocation gives a fix at start and on significant location
  changes, and the daemon saves it (rounded to 0.01°) to the config. That needs Location Services
  permission for **ScreenFilter.app**, which is why the daemon is built as an app bundle (an
  unbundled binary cannot be granted it). Denied, it keeps the saved coordinates and logs an ERROR.
- A 5-minute backstop compares the live tables with the target and logs an ERROR when it had to
  reapply, meaning some reset arrived without an event.
- Anything that calls `CGDisplayRestoreColorSyncSettings` (another gamma tool, a test script) clears
  the filter for every display until the next event or the backstop.

Night Shift must stay off (System Settings → Displays → Night Shift, schedule Off), or it tints the
built-in screen a second time.

Log: `~/Library/Logs/screen-filter.log`. The daemon reports to the ops responder (health/responder) as
`mac/screen-filter`: every ERROR line above is sent as an error, and each backstop pass is its heartbeat
(`every_s` 300). A run that crashed is reported by the next one: the daemon keeps
`$TMPDIR/screen-filter.running` while it runs and removes it on each clean stop. The reporter is the
`Ops` enum in `screenfilter.swift` (the ops-report wire format; `OPS_URLS` and `OPS_TOKEN` from
`~/.config/ops/env`). The CLI does not report. It is Mac-only: it drives this Mac's displays, so it has
no fallback machine.

## ddc

The LG 38GN950 here is connected through a USB-C→HDMI adapter (VIA Labs VLI billboard device). That
adapter does not pass DDC/CI: every read returns a null message (`6e 80 …`), so the monitor's own
brightness cannot be set from the Mac on this connection, and `screenfilter brightness` is the
substitute. A direct USB-C/DisplayPort cable should carry DDC. `DDC_DEBUG=1` prints raw replies.

Get-VCP requests use a checksum seeded with `0x6E` only; set-VCP packets seed with `0x6E ^ 0x51`.

## Build / install

    make install    # builds ScreenFilter.app and ddc, links the CLIs into ~/.local/bin, (re)starts the agent

When the launchd plist itself changes, `launchctl bootout gui/$(id -u)/com.jaredgantt.screen-filter`
first: a restart in place keeps running the old program path.
