<img src="assets/icon.svg" width="64" height="64" alt="">

# statty

A macOS menu bar app that shows memory and CPU use **per app**, over time.

Activity Monitor lists every helper process separately (a browser can be 40 rows). Statty rolls each
process up into the app responsible for it, so Zen's tabs, GPU helper and plugin containers show up as
one "Zen" row and one band in a stacked area chart. Click a row to see the processes inside it, with
plain-English descriptions of common macOS processes.

## Build and run

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
./scripts/build-app.sh --install   # builds build/Statty.app, copies it to ~/Applications, launches it
swift run                          # or run the debug build directly
```

Debug snapshot (renders the popover to a PNG without clicking the menu bar):

```sh
.build/debug/Statty --snapshot /path/out.png 20 [--cpu] [--expand Zen] [--light]
```

## How grouping works

macOS records a *responsible process* for every process: the app that launched it, directly or via XPC.
Statty groups by the responsible app's `.app` bundle first, then by the process's own location. Daemons
and agents under `/System`, `/usr` and similar paths go in a single "macOS" group. Command-line tools
launched from a terminal count toward that terminal app, the same way macOS attributes them.

Per-app memory is the physical footprint, the same number as Activity Monitor's "Memory" column.
Footprints count compressed memory at full size, so the per-app total can exceed "Used".
Root-owned processes (WindowServer, kernel_task...) can't be read directly without privileges, so their
memory comes from `top` every 30 seconds and their CPU from `ps`.
