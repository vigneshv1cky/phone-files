# Phone Files

A Finder-style file manager for macOS that also shows your Android phone. Your Mac's folders
appear just as in Finder, and the phone appears under **Locations** by its name, like an external
drive — so moving files between them works the way it does between any two folders.

macOS has no built-in support for MTP, the protocol Android phones use for USB file transfer, so a
plugged-in phone never shows up in Finder. Phone Files talks MTP directly through
[libmtp](https://github.com/libmtp/libmtp).

Tested with a Pixel 10 Pro XL on macOS 27; any Android phone in "File transfer" mode should work.

## Features

Works like Finder, for the Mac and the phone alike:

- **Sidebar like Finder's** — Favorites (Applications, Desktop, Documents, Downloads, Home, …),
  Locations (Macintosh HD, external drives and the phone by name, with battery and free space),
  the phone's own folders (DCIM, Download, Pictures, …) and a Transfers section
- **Four views** — Icons, List, Columns and Gallery (⌘1–⌘4). Column view is the native macOS
  column browser, as in Finder. ⌘+ / ⌘− / ⌘0 resize icons, rows and text
- **Arrow keys everywhere** — ↑↓ in List, all four arrows in Icon view, ←→↑↓ in Gallery, and in
  Columns → opens a folder and ← steps back out
- **Preview pane** (⇧⌘P or ⌘I) and **Quick Look** (Space)
- **Moving files the Finder way** — drag onto a folder, the window, the path bar or a sidebar
  entry. Within the Mac it moves; between the Mac and the phone it copies (hold ⌥ to copy).
  ⌘C / ⌘V copy, ⌥⌘V moves, and files copied in Finder paste straight in
- **Navigation** — Back / Forward (⌘[ ⌘]), Enclosing Folder (⌘↑), Open (⌘↓), Go menu, path bar
- **Search** the current folder, sort by name, kind, date or size, hidden files (⇧⌘.)
- **Manage** — new folder (⇧⌘N), rename (Return), Move to Trash (⌘⌫) on the Mac; on the phone,
  which has no Trash, delete asks first
- Mac folders refresh by themselves when their contents change

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
3. Open Phone Files. The phone appears in the sidebar under Locations. If it says "Not connected"
   or "Unlock the phone", unlock it and press **Connect** / Reconnect (⇧⌘K).

The first time you open Desktop, Documents or Downloads, macOS asks whether Phone Files may
access that folder — allow it, as you would for Finder-like apps.

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
| `PhoneFilesMac/Sources/PhoneFiles/AppModel.swift` | Locations, navigation, previews, and the copy/move engine for every direction |
| `PhoneFilesMac/Sources/PhoneFiles/FileItem.swift` | One item type for Mac and phone files, Mac listing, Finder icons |
| `PhoneFilesMac/Sources/PhoneFiles/ColumnBrowserView.swift` | Column view on the native macOS column browser |
| `PhoneFilesMac/Sources/PhoneFiles/Autotest.swift` | Self-test driven by environment variables |
| `PhoneFilesMac/Sources/PhoneFiles/ContentView.swift` | Window layout, sidebar, dialogs |
| `PhoneFilesMac/Sources/PhoneFiles/BrowserView.swift` | Toolbar, path bar, status bar |
| `PhoneFilesMac/Sources/PhoneFiles/ItemViews.swift` | Icon, List and Gallery views |
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
