import AppKit
import QuickLookUI

/// Developer self-test, driven by environment variables so the UI can be exercised without
/// clicking. Results are "Autotest:" lines in the log (subsystem local.phonefiles).
///
/// PHONEFILES_AUTOTEST_MAC=<scratch folder>  start there and test Mac browsing, Quick Look,
///     keys, new folder, copy, drag-and-drop move and clipboard paste — all inside that folder.
/// PHONEFILES_AUTOTEST="Pictures,Download"   for each phone folder: all four views, preview,
///     Quick Look, keys, then copy one small file from the phone into the scratch folder.
///
/// Nothing is ever written to or deleted from the phone.
extension AppModel {
    func runAutotestIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard env["PHONEFILES_AUTOTEST_MAC"] != nil || env["PHONEFILES_AUTOTEST"] != nil else { return }
        let originalMode = viewMode
        defer { viewMode = originalMode }
        if let pane = env["PHONEFILES_AUTOTEST_PANE"] { showPreviewPane = pane == "1" }

        var scratch: URL?
        if let dir = env["PHONEFILES_AUTOTEST_MAC"] {
            let root = URL(fileURLWithPath: dir).standardizedFileURL
            scratch = root
            await testMac(root)
        }
        if let folders = env["PHONEFILES_AUTOTEST"] {
            await testPhone(folders.split(separator: ",").map(String.init), copyInto: scratch)
        }
        report("finished")
    }

    private func report(_ message: String) {
        log.notice("Autotest: \(message, privacy: .public)")
    }

    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// Waits for a transfer started after `count` transfers existed to finish.
    private func waitForTransfers(after count: Int) async -> String {
        let started = Date()
        _ = await waitUntil(90) { transfers.count > count && !hasActiveTransfer }
        guard let last = transfers.first else { return "no transfer" }
        if last.state == .running {
            let loadingPreviews = previews.values.filter { $0.state == .loading }.map { "\($0.item.name) \(Int($0.fraction * 100))%" }
            report("transfer \"\(last.title)\" still running after \(Int(Date().timeIntervalSince(started)))s at \(Int(last.fraction * 100))% (\(last.detail)); previews loading: \(loadingPreviews)")
        }
        switch last.state {
        case .done: return "done"
        case .failed(let m): return "failed: \(m)"
        case .cancelled: return "cancelled"
        case .running: return "still running"
        }
    }

    private var quickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    // MARK: Mac side

    private func testMac(_ root: URL) async {
        navigate(to: .mac(root), record: false, columnRoot: root, force: true)
        _ = await waitUntil(5) { hasListing }
        report("Mac folder \(root.lastPathComponent): \(visibleItems.count) items")
        await cycleViews(label: "Mac folder")
        guard let file = visibleItems.first(where: { !$0.isFolder }) else { return report("no Mac file to test with") }

        await checkPreviewAndKeys(file)

        // New folder.
        makeFolder(named: "Autotest Folder")
        let sub = root.appendingPathComponent("Autotest Folder")
        let made = await waitUntil(5) { FileManager.default.fileExists(atPath: sub.path) }
        report("new folder on Mac: \(made)")

        // Copy a file into it.
        var before = transfers.count
        transfer([file], to: .mac(sub), move: false)
        let copyState = await waitForTransfers(after: before)
        let copied = sub.appendingPathComponent(file.name)
        report("copy Mac→Mac: \(copyState), file there: \(FileManager.default.fileExists(atPath: copied.path))")

        // Drag that copy back onto the parent folder: same device, so it should move.
        let copiedItem = MacFiles.item(copied)
        let provider = dragProvider(for: copiedItem)
        report("drop cursor for Mac→Mac: \(dropOperation(to: .mac(root), isInternal: true) == .move ? "move" : "copy"), Mac→phone: \(dropOperation(to: .phone(storage: 1, path: []), isInternal: true) == .move ? "move" : "copy")")
        let expectedArrival = MacFiles.uniqueURL(in: root, name: file.name)  // e.g. "notes 2.txt", as Finder names it
        before = transfers.count
        _ = handleDrop([provider], to: .mac(root))
        let moveState = await waitForTransfers(after: before)
        let movedAway = !FileManager.default.fileExists(atPath: copied.path)
        let arrived = FileManager.default.fileExists(atPath: expectedArrival.path)
        report("drag-and-drop move Mac→Mac: \(moveState), left subfolder: \(movedAway), arrived in parent as \(expectedArrival.lastPathComponent): \(arrived)")

        // Clipboard: copy the file, paste into the subfolder.
        await load(Location.mac(root).key)
        selection = [file.id]
        copySelectionToClipboard()
        navigate(to: .mac(sub))
        _ = await waitUntil(5) { hasListing }
        before = transfers.count
        paste(move: false)
        let pasteState = await waitForTransfers(after: before)
        report("clipboard paste Mac→Mac: \(pasteState), file there: \(FileManager.default.fileExists(atPath: copied.path))")

        // Back and forward history.
        goBack()
        _ = await waitUntil(3) { location == .mac(root) }
        report("back: \(location == .mac(root)), can go forward: \(canGoForward)")
    }

    // MARK: Phone side

    private func testPhone(_ folders: [String], copyInto scratch: URL?) async {
        _ = await waitUntil(15) { connection == .connected && !storages.isEmpty }
        guard let storage = storages.first?.id else { return report("phone not connected — phone tests skipped") }
        navigate(to: .phone(storage: storage, path: []))
        _ = await waitUntil(10) { hasListing }
        report("phone top level: \(visibleItems.count) items; sidebar phone folders: \(phoneFavorites.map(\.name).joined(separator: ", "))")
        for name in folders {
            guard let folder = visibleItems.first(where: { $0.isFolder && $0.name == name }) else {
                report("no phone folder \(name)")
                continue
            }
            open(folder)
            _ = await waitUntil(10) { hasListing }
            report("phone folder \(name): \(visibleItems.count) items")
            await cycleViews(label: name)
            if let file = visibleItems.first(where: { !$0.isFolder && $0.size <= Self.autoPreviewLimit }) {
                requestPreview(file, force: false)
                let ready = await waitUntil(15) { previews[file.id]?.url != nil }
                report("phone preview for \(file.name): \(ready ? "ready" : "NOT ready")")
                await checkPreviewAndKeys(file)
                if let scratch {
                    let before = transfers.count
                    let copyStart = Date()
                    transfer([file], to: .mac(scratch), move: true)  // cross-device: must copy, not move
                    let state = await waitForTransfers(after: before)
                    report("phone→Mac copy took \(String(format: "%.1f", Date().timeIntervalSince(copyStart)))s")
                    let local = scratch.appendingPathComponent(file.name)
                    report("copy phone→Mac: \(state), size matches: \(MacFiles.size(local) == file.size), still on phone: \(children[location.key]?.contains { $0.id == file.id } ?? false)")
                }
            }
            goUp()
            _ = await waitUntil(5) { hasListing }
        }
    }

    // MARK: Shared checks

    private func cycleViews(label: String) async {
        for mode in ViewMode.allCases {
            viewMode = mode
            try? await Task.sleep(for: .seconds(1.2))
            report("\(label) shown as \(mode.title)")
        }
    }

    private func checkPreviewAndKeys(_ file: FileItem) async {
        quickLook(file)
        let shown = await waitUntil(5) { quickLookVisible }
        report("Quick Look panel for \(file.name): \(shown)")
        quickLookURL = nil
        try? await Task.sleep(for: .seconds(0.8))

        viewMode = .list
        selection = [file.id]
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let table = Self.findTable(in: window.contentView!) else { return report("list table not found") }
        window.makeFirstResponder(table)
        Self.sendKey(" ", keyCode: 49, to: window)
        let opened = await waitUntil(5) { quickLookVisible }
        Self.sendKey(" ", keyCode: 49, to: window)
        let closed = await waitUntil(3) { !quickLookVisible }
        report("Space opens Quick Look: \(opened), second Space closes it: \(closed)")
        quickLookURL = nil
        window.makeFirstResponder(table)
        Self.sendKey("\r", keyCode: 36, to: window)
        try? await Task.sleep(for: .seconds(0.5))
        report("Return starts rename: \(renameTarget != nil)")
        renameTarget = nil
        await checkArrowKeys()
    }

    /// Real arrow-key presses in List view and in the native column view.
    private func checkArrowKeys() async {
        let items = visibleItems
        guard items.count >= 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        viewMode = .list
        selection = [items[0].id]
        try? await Task.sleep(for: .seconds(0.8))
        if let table = Self.findTable(in: window.contentView!) {
            window.makeFirstResponder(table)
            Self.sendArrow(.down, to: window)
            try? await Task.sleep(for: .seconds(0.5))
            report("List view ↓ moves to the next item: \(selection == [items[1].id])")
            Self.sendArrow(.up, to: window)
            try? await Task.sleep(for: .seconds(0.5))
            report("List view ↑ moves back: \(selection == [items[0].id])")
        }

        let start = location
        viewMode = .columns
        try? await Task.sleep(for: .seconds(1.5))
        guard let folderIndex = items.firstIndex(where: \.isFolder), folderIndex + 1 < items.count || folderIndex > 0 else {
            return report("no folder here to test column arrows")
        }
        // Start one row above (or below) a folder so ↓ (or ↑) lands on it.
        let startIndex = folderIndex > 0 ? folderIndex - 1 : folderIndex + 1
        selection = [items[startIndex].id]
        try? await Task.sleep(for: .seconds(0.8))
        guard let browser = Self.find(NSBrowser.self, in: window.contentView!) else { return report("column browser not found") }
        let tablesForIcons = FinderColumnView.Coordinator.columnTables(in: browser)
        if let firstColumn = tablesForIcons.first, firstColumn.numberOfRows > 0,
           let cell = firstColumn.preparedCell(atColumn: 0, row: 0) as? NSBrowserCell {
            report("Column view row shows \"\(cell.stringValue)\" with an icon: \(cell.image != nil)")
        } else {
            report("Column view first row could not be read")
        }
        // Focus the last column, as clicking in it would.
        let columnIndex = columnLocations.count - 1
        var tables = FinderColumnView.Coordinator.columnTables(in: browser)
        guard columnIndex < tables.count else { return report("column \(columnIndex) not found") }
        window.makeFirstResponder(tables[columnIndex])
        await Self.postArrow(folderIndex > 0 ? .down : .up)
        let enteredFolder = location != start  // selecting a folder opens it in the next column
        report("Column view ↑/↓ onto the folder \(items[folderIndex].displayName) opens it: \(enteredFolder) (now showing \(currentTitle))")
        await Self.postArrow(.right)
        tables = FinderColumnView.Coordinator.columnTables(in: browser)
        let focus = tables.firstIndex { $0 === window.firstResponder }
        report("Column view → moves into it: \(selection.count == 1), selected \(selectedItems.first?.displayName ?? "nothing"), focus in column \(focus.map(String.init) ?? "none") of \(tables.count)")
        await Self.postArrow(.down)
        report("Column view ↓ inside it: now \(selectedItems.first?.displayName ?? currentTitle)")
        await Self.postKey(" ", keyCode: 49)
        let spaceOpened = await waitUntil(4) { quickLookVisible }
        await Self.postKey(" ", keyCode: 49)
        let spaceClosed = await waitUntil(3) { !quickLookVisible }
        quickLookURL = nil
        report("Column view Space opens Quick Look: \(spaceOpened), Space again closes it: \(spaceClosed)")
        window.makeFirstResponder(FinderColumnView.Coordinator.columnTables(in: browser).last ?? browser)
        await Self.postKey("\r", keyCode: 36)
        report("Column view Return starts rename: \(renameTarget != nil)")
        renameTarget = nil
        await Self.postArrow(.left)
        report("Column view ← back out: showing \(currentTitle), selected \(selectedItems.first?.displayName ?? "nothing")")
        await Self.postArrow(.left)
        report("Column view ← again: showing \(currentTitle), selected \(selectedItems.first?.displayName ?? "nothing")")
        navigate(to: start)
        viewMode = .list
        try? await Task.sleep(for: .seconds(0.5))
    }

    private enum Arrow { case up, down, left, right }

    /// Posts a plain key through the normal event queue, as the keyboard would.
    private static func postKey(_ chars: String, keyCode: UInt16) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        try? await Task.sleep(for: .seconds(0.8))
    }

    /// Posts an arrow key through the normal event queue, as the keyboard would.
    private static func postArrow(_ arrow: Arrow) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        let (char, code): (Int, UInt16) = {
            switch arrow {
            case .up: return (NSUpArrowFunctionKey, 126)
            case .down: return (NSDownArrowFunctionKey, 125)
            case .left: return (NSLeftArrowFunctionKey, 123)
            case .right: return (NSRightArrowFunctionKey, 124)
            }
        }()
        let chars = String(Character(UnicodeScalar(char)!))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        try? await Task.sleep(for: .seconds(1))
    }

    private static func sendArrow(_ arrow: Arrow, to window: NSWindow) {
        let (char, code): (Int, UInt16) = {
            switch arrow {
            case .up: return (NSUpArrowFunctionKey, 126)
            case .down: return (NSDownArrowFunctionKey, 125)
            case .left: return (NSLeftArrowFunctionKey, 123)
            case .right: return (NSRightArrowFunctionKey, 124)
            }
        }()
        let chars = String(Character(UnicodeScalar(char)!))
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) {
                window.sendEvent(event)
            }
        }
    }

    private static func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { findAll(type, in: $0) }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews { if let found = findTable(in: sub) { return found } }
        return nil
    }

    private static func sendKey(_ chars: String, keyCode: UInt16, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: keyCode) {
                window.sendEvent(event)
            }
        }
    }
}
