# Phone Files — project notes

Finder-style macOS file manager (SwiftUI + libmtp): browses the Mac like Finder and shows the Android phone under Locations; one copy/move engine covers every direction. `phone-files/` is the
earlier Python/browser prototype; `PhoneFilesMac/` is the app that ships.

## Build and install (2026-10-10)
- `cd PhoneFilesMac && ./build-app.sh` → `PhoneFilesMac/build/Phone Files.app` (libmtp + libusb bundled, ad-hoc signed).
- Install: `ditto "PhoneFilesMac/build/Phone Files.app" "/Applications/Phone Files.app"`, quitting the running copy first.
- Only the Command Line Tools are installed (no Xcode app); SwiftPM builds fine without it.
- Needs `brew install libmtp`; Package.swift hardcodes `/opt/homebrew` include and lib paths.

## Hard-won fixes — keep these (2026-10-10)
- **ptpcamerad grabs the phone.** macOS's photo-import daemon claims MTP devices; libmtp then fails with `libusb_claim_interface() = -3`. A plain kill is ignored — `pkill -9 -x ptpcamerad` right before opening works.
- **Open uncached.** `LIBMTP_Get_First_Device` walks every object up front (minutes on a full phone). Use `LIBMTP_Detect_Raw_Devices` + `LIBMTP_Open_Raw_Device_Uncached`, then `LIBMTP_Get_Files_And_Folders` per folder.
- **Read `next` before `LIBMTP_destroy_file_t`.** In the Python/ctypes version a pointer field read after the free returned NULL, so every folder showed only its first item. Swift copies the pointer by value and is safe, but keep the order.
- **Dead handle after re-enumeration.** Switching the phone's USB mode or replugging makes the old device handle dead, and `LIBMTP_Release_Device` on it can block on USB timeouts. Reconnect releases the old handle on a detached thread.
- **No `@EnvironmentObject` inside Table or List rows.** macOS rebuilds those cells outside the environment when the data changes, which crashed the app on entering any folder. Pass values and closures into row views instead.
- **Keep the file area at least ~350 pt wide while the preview pane is open.** Narrower, and AppKit's split view loops re-solving constraints and throws ("more Update Constraints in Window passes than there are views"). A status bar that demanded extra width (the icon-size control) triggered it at the old 900 pt minimum. Now: window min 1000, sidebar max 280, inspector max 360, and the status bar yields (ViewThatFits + truncating text). (2026-10-10)
- **Quick Look embedded views: never call close() when SwiftUI tears one down.** Switching views can dismantle a preview before Quick Look has activated it; close() then hits a Quick Look assertion and crashes. Clear the preview item instead. (2026-10-10)
- **Column view is NSBrowser (item-based).** In that mode the delegate's willDisplayCell is never called — icons come from a custom cell that receives the row object as its value. NSBrowser didn't act on synthetic → / ← presses and doesn't send its action for them, so → / ← are handled by a local key monitor (Finder rules: → into the folder selecting its first item, ← back out selecting the folder). Every model→browser sync must not echo back (guard flag). (2026-10-10)
- One MTP request at a time: every libmtp call goes through `PhoneService`'s serial queue.

## Crash guard: never let libmtp fail an open (2026-10-10)
- When `LIBMTP_Open_Raw_Device_Uncached` can't claim the USB interface, libmtp's clean-up (`close_usb`) sends a control transfer on a never-opened handle → SIGSEGV inside libusb. Seen when two copies of the app (installed app + a test build) opened the phone at once.
- Guards: a per-user flock (`/tmp/phonefiles-<uid>.lock`, held for the process lifetime) so only one copy talks to the phone; and a libusb claim probe of interface 0 before calling libmtp, which turns "someone else holds it" into a message.
- **Quit the installed app before running a test build** (`osascript -e 'quit app "Phone Files"'`), or the test build will (correctly) refuse the phone.

## Open issues (2026-10-10)
- A phone→Mac copy right after browsing phone photos in Column view waited >60 s (likely queued behind preview fetches); not yet diagnosed.
- After a replug a Pixel often falls back to "No data transfer": it still enumerates as MTP (PID 0x4ee1) but hides storage ("Get Storage information failed"). The fix is on the phone: choose File transfer again.

## Phone-side requirements
- USB mode must be "File transfer / Android Auto"; storage is hidden while the screen is locked.
- Developer options → "Stay awake" keeps the session alive while plugged in.

## Debugging
- Logs: `/usr/bin/log show --last 5m --info --predicate 'subsystem == "local.phonefiles"'` (zsh's own `log` builtin shadows the system one).
- Automatic UI test, no clicking needed (2026-10-10): `PHONEFILES_AUTOTEST="Pictures,Download" .build/release/PhoneFiles`. For each folder it shows all four views, presses real ⌘= ⌘+ ⌘- ⌘0, loads a preview, opens Quick Look, presses Space twice and Return (rename prompt is opened then cancelled — nothing on the phone changes), then goes Back. `PHONEFILES_AUTOTEST_PANE=0|1` forces the preview pane. Results are "Autotest:" lines in the log.
- Autotest: `PHONEFILES_AUTOTEST_MAC=<scratch folder>` tests Mac browsing, keys, new folder, copy, drag-and-drop move and paste inside that folder; combine with `PHONEFILES_AUTOTEST="Pictures"` for the phone (views, preview, Quick Look, arrows, phone→Mac copy). Nothing is written to the phone. Report lines use notice level: info-level lines are memory-only and were silently dropped between runs. (2026-10-10)
- Crash reasons: info-level log lines can be lost on a crash; capture stderr (`… > out.txt 2>&1`) to get the exception reason.
- Running the bare binary uses the `PhoneFiles` defaults domain; the installed app uses `local.phonefiles`.
- This session cannot screenshot other apps' windows (no Screen Recording permission); verify through the log.
- Measured transfer speed over USB 2.0: about 28 MB/s.
