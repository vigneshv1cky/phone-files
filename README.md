# Phone Files

A native macOS app for browsing an Android phone over USB — browse folders, preview photos and
videos with Quick Look, download files and whole folders, and upload by drag and drop.

macOS has no built-in support for MTP, the protocol Android phones use for USB file transfer, so a
plugged-in phone never shows up in Finder. Phone Files talks MTP directly through
[libmtp](https://github.com/libmtp/libmtp).

Tested with a Pixel 10 Pro XL on macOS 27; any Android phone in "File transfer" mode should work.

## Features

Works like Finder, pointed at your phone:

- **Four views** — Icons, List, Columns and Gallery (⌘1–⌘4), with ⌘+ / ⌘− / ⌘0 to resize
  icons, rows and text, and an icon-size slider in Icon view
- **Preview pane** (⇧⌘P or ⌘I) — live preview of photos, videos, PDFs, audio and text, with kind,
  size, date, image dimensions and location
- **Quick Look** — Space (or ⌘Y) toggles the Quick Look panel
- **Open in Mac apps** — double-click or ⌘↓ opens a file in its default app (a copy; edits stay on the Mac)
- **Navigation** — Back / Forward (⌘[ ⌘]), Enclosing Folder (⌘↑), clickable path bar, Go menu,
  and Favorites in the sidebar (DCIM, Download, Pictures, …)
- **Search** the current folder, sort by name, kind, date or size, keep folders on top,
  show or hide dot-files (⇧⌘.)
- **Transfers** — download files or whole folders (⌘D, or Download To…), drag files out to
  Finder, drag files or folders in, or paste files copied in Finder (⌘V); progress and cancel
  in the sidebar
- **Manage** — new folder (⇧⌘N), rename (Return), delete (⌘⌫, always confirmed)
- Reconnects cleanly after the phone is replugged or its USB mode changes

Large files (over 25 MB) don't load into the preview automatically — the pane shows the
thumbnail and a *Load Preview* button, so selecting a 2 GB video doesn't start a 2 GB copy.

## Requirements

- macOS 14 or later, Apple silicon or Intel
- Xcode or the Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh) with libmtp:

  ```bash
  brew install libmtp
  ```

## Build

```bash
cd PhoneFilesMac
./build-app.sh
```

This produces `PhoneFilesMac/build/Phone Files.app` with libmtp and libusb bundled inside, so the
built app runs without Homebrew. Copy it to `/Applications` to install:

```bash
ditto "PhoneFilesMac/build/Phone Files.app" "/Applications/Phone Files.app"
```

## Using it

1. Plug in the phone and unlock it.
2. Pull down the notification shade, tap the USB notification and choose **File transfer**.
3. Open Phone Files. If it shows "Phone not connected" or "Can't read this folder", unlock the phone
   and press **Reconnect** (⇧⌘K).

Android hides its storage whenever the screen locks, so for long sessions turn on
**Developer options → Stay awake** (the screen stays on while charging).

### Speed

MTP over a USB 2.0 cable measured about 28 MB/s (a 1.9 GB video in 67 s). A USB-C cable rated
5–10 Gb/s plugged into a USB-C port is several times faster for large copies.

The phone answers one request at a time, so browsing waits while a large transfer is running.

## How it works

| Piece | What it does |
|---|---|
| `PhoneFilesMac/Sources/PhoneFiles/MTPDevice.swift` | Swift wrapper over libmtp, plus a serial queue that runs every phone call one at a time |
| `PhoneFilesMac/Sources/PhoneFiles/PhoneModel.swift` | Connection, navigation, thumbnails and transfers |
| `PhoneFilesMac/Sources/PhoneFiles/ContentView.swift` | Window layout, sidebar, dialogs |
| `PhoneFilesMac/Sources/PhoneFiles/BrowserView.swift` | Toolbar, path bar, status bar |
| `PhoneFilesMac/Sources/PhoneFiles/ItemViews.swift` | Icon, List, Column and Gallery views |
| `PhoneFilesMac/Sources/PhoneFiles/PreviewViews.swift` | Preview pane and embedded Quick Look |
| `PhoneFilesMac/Sources/PhoneFiles/PhoneFilesApp.swift` | App entry point and menu bar |
| `PhoneFilesMac/build-app.sh` | Builds, bundles the native libraries, adds the icon, ad-hoc signs |
| `phone-files/` | The original browser-based prototype (Python standard library + libmtp via ctypes) |

Two macOS-specific details make the connection reliable:

- **macOS's photo-import service (`ptpcamerad`) claims the phone** the moment it is plugged in,
  which makes libmtp fail with an access error. The app stops that service just before opening the
  phone; launchd restarts it on demand, but by then the app holds the USB interface.
- **libmtp's default open walks every file on the phone** before returning, which takes minutes on
  a phone full of photos. The app opens the device uncached and lists each folder on demand.

### Browser prototype

```bash
python3 phone-files/server.py --open
```

Serves the same features at http://127.0.0.1:8777 using only the Python standard library.

## Licence

MIT — see [LICENSE](LICENSE).

The packaged app bundles [libmtp](https://github.com/libmtp/libmtp) and
[libusb](https://github.com/libusb/libusb), both under the GNU LGPL 2.1 or later. They are linked
dynamically and can be replaced inside `Contents/Frameworks`; their source is available from the
linked projects.
