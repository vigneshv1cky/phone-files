# Phone Files — project notes

Native macOS app (SwiftUI + libmtp) for browsing an Android phone over USB. `phone-files/` is the
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
- One MTP request at a time: every libmtp call goes through `PhoneService`'s serial queue.

## Phone-side requirements
- USB mode must be "File transfer / Android Auto"; storage is hidden while the screen is locked.
- Developer options → "Stay awake" keeps the session alive while plugged in.

## Debugging
- Logs: `/usr/bin/log show --last 5m --info --predicate 'subsystem == "local.phonefiles"'` (zsh's own `log` builtin shadows the system one).
- Automatic UI test, no clicking needed (2026-10-10): `PHONEFILES_AUTOTEST="Pictures,Download" .build/release/PhoneFiles`. For each folder it shows all four views, presses real ⌘= ⌘+ ⌘- ⌘0, loads a preview, opens Quick Look, presses Space twice and Return (rename prompt is opened then cancelled — nothing on the phone changes), then goes Back. `PHONEFILES_AUTOTEST_PANE=0|1` forces the preview pane. Results are "Autotest:" lines in the log.
- Crash reasons: info-level log lines can be lost on a crash; capture stderr (`… > out.txt 2>&1`) to get the exception reason.
- Running the bare binary uses the `PhoneFiles` defaults domain; the installed app uses `local.phonefiles`.
- This session cannot screenshot other apps' windows (no Screen Recording permission); verify through the log.
- Measured transfer speed over USB 2.0: about 28 MB/s.
