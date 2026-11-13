# screen-filter

A warm, dimmable filter for the Mac's external display, plus small CLIs for Night Shift and DDC.

| binary | what it does |
|---|---|
| `screenfilter` | Background daemon + CLI. Tints and dims external displays through the GPU gamma tables. |
| `nightshift` | Reads and sets macOS Night Shift (private `CBBlueLightClient`): on/off, warmth, schedule. |
| `ddc` | Reads/sets a monitor's own settings (VCP codes, e.g. `0x10` brightness) over DDC/CI. |

## screenfilter

    screenfilter status
    screenfilter auto            # warm while Night Shift is active (its sunset-to-sunrise schedule)
    screenfilter on | off        # warm always / never
    screenfilter warmth 0-100    # 0 = no tint, 100 = 1900K
    screenfilter brightness 10-100   # scales the display's output, day and night

Settings live in `~/.config/screen-filter/config.json`; the CLI writes it and the daemon picks the
change up from a directory watch. Only external displays are touched; the built-in screen is left to
Night Shift and its own backlight.

How it stays applied:

- A gamma table lasts only as long as the process that set it, so the daemon runs under launchd
  (`com.jaredgantt.screen-filter`, KeepAlive) and restores the default tables when stopped.
- macOS resets the tables on display reconfiguration and wake; the daemon reapplies on
  `CGDisplayRegisterReconfigurationCallback` and the NSWorkspace wake notifications.
- In `auto`, it follows Night Shift's own status callback, so the schedule is the system's.
- A 5-minute backstop compares the live table with the target and logs an ERROR when it had to
  reapply, meaning some reset arrived without an event.
- Anything that calls `CGDisplayRestoreColorSyncSettings` (another gamma tool, a test script) clears
  the filter for every display until the next event or the backstop.

Log: `~/Library/Logs/screen-filter.log`. It is a Mac-only desktop utility (it drives this Mac's
display) and does not report to the ops responder; a failure shows on the screen itself.

If Night Shift also reaches the external display, the two tints stack.

## ddc

The LG 38GN950 here is connected through a USB-C→HDMI adapter (VIA Labs VLI billboard device). That
adapter does not pass DDC/CI: every read returns a null message (`6e 80 …`), so the monitor's own
brightness cannot be set from the Mac on this connection, and `screenfilter brightness` is the
substitute. A direct USB-C/DisplayPort cable should carry DDC.

Get-VCP requests use a checksum seeded with `0x6E` only; set-VCP packets seed with `0x6E ^ 0x51`.

## Build / install

    make install    # builds, links the CLIs into ~/.local/bin, (re)loads the launchd agent
