import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row in the column browser. Folders carry the location they open.
final class BrowserNode: NSObject {
    let item: FileItem?
    let location: Location?

    init(item: FileItem?, location: Location?) {
        self.item = item
        self.location = location
    }
}

/// Column view built on NSBrowser — the same control Finder's column view uses — so it gets
/// Finder's look, resizable columns, the preview column and native arrow-key navigation
/// (up/down within a column, right into a folder, left back out).
struct FinderColumnView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSBrowser {
        let browser = NSBrowser()
        let coordinator = context.coordinator
        coordinator.browser = browser
        browser.delegate = coordinator
        browser.target = coordinator
        browser.action = #selector(Coordinator.selectionChanged(_:))
        browser.doubleAction = #selector(Coordinator.doubleClicked(_:))
        browser.isTitled = false
        browser.hasHorizontalScroller = true
        browser.autohidesScroller = true
        browser.separatesColumns = true
        browser.allowsMultipleSelection = true
        browser.allowsEmptySelection = true
        browser.sendsActionOnArrowKeys = true
        browser.columnResizingType = .userColumnResizing
        browser.minColumnWidth = 160
        browser.setDefaultColumnWidth(230)
        browser.rowHeight = 20
        browser.setCellClass(IconBrowserCell.self)
        browser.focusRingType = .none
        browser.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        browser.setDraggingSourceOperationMask(.copy, forLocal: false)
        browser.registerForDraggedTypes([.fileURL, Coordinator.itemType])
        browser.menu = coordinator.makeMenu()
        coordinator.installKeyHandling()
        coordinator.sync()
        return browser
    }

    func updateNSView(_ browser: NSBrowser, context: Context) {
        context.coordinator.sync()
    }

    static func dismantleNSView(_ browser: NSBrowser, coordinator: Coordinator) {
        coordinator.removeKeyHandling()
    }

    @MainActor
    final class Coordinator: NSObject, NSBrowserDelegate, NSMenuDelegate {
        static let itemType = NSPasteboard.PasteboardType(UTType.phoneFilesItem.identifier)

        let model: AppModel
        weak var browser: NSBrowser?
        private var root: BrowserNode?
        private var nodes: [FolderKey: [BrowserNode]] = [:]
        /// True while we change the browser ourselves, so those changes aren't echoed back.
        private var applying = false
        private lazy var preview = ColumnPreviewController(model: model)

        private var keyMonitor: Any?

        init(model: AppModel) { self.model = model }

        // MARK: Right / Left arrows, the Finder way

        func installKeyHandling() {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handleKey(event) }
            }
        }

        func removeKeyHandling() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }

        /// The Finder keys while a column has keyboard focus: ← → between columns (↑ ↓ are the
        /// browser's own), Space for Quick Look, Return to rename.
        private func handleKey(_ event: NSEvent) -> NSEvent? {
            guard let browser, event.window === browser.window,
                  let responder = browser.window?.firstResponder as? NSView, responder.isDescendant(of: browser),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return event }
            switch event.keyCode {
            case 124: moveRight(); return nil
            case 123: moveLeft(); return nil
            case 49:  // Space
                guard !model.selection.isEmpty || model.quickLookURL != nil else { return event }
                model.quickLookSelection()
                return nil
            case 36, 76:  // Return, Enter
                guard model.selectedItems.count == 1 else { return event }
                model.beginRename()
                return nil
            default:
                return event
            }
        }

        /// Into the selected folder (or the open folder), selecting its first item.
        private func moveRight() {
            var target = model.location
            let selected = model.selectedItems
            if selected.count == 1, selected[0].isFolder {
                target = model.child(selected[0], of: model.location)
                model.navigate(to: target)
            } else if !selected.isEmpty {
                return  // a file: nothing further right but its preview
            }
            let model = self.model
            Task {
                await model.ensureLoaded([target])
                guard model.location == target, let first = model.visible(target.key).first else { return }
                model.selection = [first.id]
                self.focusColumn(model.columnLocations.count - 1)
            }
        }

        /// Back out to the enclosing folder, keeping the folder we were in selected.
        private func moveLeft() {
            guard model.columnLocations.count > 1 else { return }
            model.goUp()
            focusColumn(model.columnLocations.count - 1)
        }

        /// Gives keyboard focus to a column once the browser has caught up with the model.
        private func focusColumn(_ index: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let browser = self?.browser else { return }
                let tables = Self.columnTables(in: browser)
                if index >= 0, index < tables.count { browser.window?.makeFirstResponder(tables[index]) }
            }
        }

        /// The browser's column views, left to right.
        static func columnTables(in browser: NSBrowser) -> [NSTableView] {
            func all(_ view: NSView) -> [NSTableView] {
                ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(all)
            }
            return all(browser).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }

        // MARK: Keeping the browser in step with the model

        /// Rows for a folder, built once per listing so the browser always sees the same objects.
        private func children(of location: Location) -> [BrowserNode] {
            if let cached = nodes[location.key] { return cached }
            guard model.children[location.key] != nil else {
                let model = self.model
                Task { await model.ensureLoaded([location]) }
                return []
            }
            let built = model.visible(location.key).map {
                BrowserNode(item: $0, location: $0.isFolder ? model.child($0, of: location) : nil)
            }
            nodes[location.key] = built
            return built
        }

        func sync() {
            guard let browser else { return }
            applying = true
            defer { applying = false }
            let columns = model.columnLocations
            guard let first = columns.first else { return }

            if root?.location?.key != first.key {
                root = BrowserNode(item: nil, location: first)
                nodes = [:]
                browser.loadColumnZero()
            }

            // Reload any column whose listing changed (new files, sort, search, hidden files).
            for (index, location) in columns.enumerated() where index <= browser.lastColumn {
                guard model.children[location.key] != nil else { continue }
                let fresh = model.visible(location.key).map(\.id)
                if nodes[location.key]?.compactMap(\.item?.id) != fresh {
                    nodes[location.key] = nil
                    browser.reloadColumn(index)
                }
            }

            // Select the path of folders leading to the current one, then the selection inside it.
            var path = IndexPath()
            for index in 0..<(columns.count - 1) {
                let target = model.itemID(leadingTo: columns[index + 1])
                guard let row = children(of: columns[index]).firstIndex(where: { $0.item?.id == target }) else { break }
                path.append(row)
            }
            let complete = path.count == columns.count - 1
            let last = children(of: columns[columns.count - 1])
            let selectedRows = IndexSet(last.indices.filter { last[$0].item.map { model.selection.contains($0.id) } ?? false })
            if complete, selectedRows.count == 1 { path.append(selectedRows.first!) }
            if browser.selectionIndexPath != path { browser.selectionIndexPath = path }
            if complete, selectedRows.count > 1 { browser.selectRowIndexes(selectedRows, inColumn: columns.count - 1) }
        }

        private func node(_ browser: NSBrowser, row: Int, column: Int) -> BrowserNode? {
            browser.item(atRow: row, inColumn: column) as? BrowserNode
        }

        private func folder(of browser: NSBrowser, column: Int) -> Location? {
            column == 0 ? root?.location : (browser.parentForItems(inColumn: column) as? BrowserNode)?.location
        }

        // MARK: NSBrowserDelegate — contents

        func rootItem(for browser: NSBrowser) -> Any? { root }

        func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
            guard let location = ((item as? BrowserNode) ?? root)?.location else { return 0 }
            return children(of: location).count
        }

        func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
            guard let location = ((item as? BrowserNode) ?? root)?.location else { return BrowserNode(item: nil, location: nil) }
            let rows = children(of: location)
            return index < rows.count ? rows[index] : BrowserNode(item: nil, location: nil)
        }

        func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
            (item as? BrowserNode)?.location == nil
        }

        /// The whole row object goes to the cell, which draws the name and Finder's icon.
        /// (In this item-based mode the browser never asks the delegate to decorate cells.)
        func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
            item as? BrowserNode
        }

        func browser(_ browser: NSBrowser, previewViewControllerForLeafItem item: Any) -> NSViewController? {
            preview
        }

        // MARK: Selection and opening

        /// Every selection change — click, arrow key, Right into a folder, Left back out — passes
        /// through here. (Right/Left don't send the browser's action, and the next sync would
        /// otherwise put the old selection back.)
        func browser(_ browser: NSBrowser, selectionIndexesForProposedSelection proposed: IndexSet,
                     inColumn column: Int) -> IndexSet {
            if !applying {
                DispatchQueue.main.async { [weak self, weak browser] in
                    guard let self, let browser else { return }
                    self.adopt(rows: proposed, column: column, in: browser)
                }
            }
            return proposed
        }

        @objc func selectionChanged(_ browser: NSBrowser) {
            let column = browser.selectedColumn
            guard column >= 0 else { return }
            adopt(rows: browser.selectedRowIndexes(inColumn: column) ?? [], column: column, in: browser)
        }

        private func adopt(rows: IndexSet, column: Int, in browser: NSBrowser) {
            guard let parent = folder(of: browser, column: column) else { return }
            let picked = rows.compactMap { node(browser, row: $0, column: column)?.item }
            if picked.count == 1, picked[0].isFolder {
                model.navigate(to: model.child(picked[0], of: parent))
            } else if picked.isEmpty, column > 0, rows.isEmpty {
                return  // a column losing its selection as focus moves left; the next event says where we are
            } else {
                if parent != model.location { model.navigate(to: parent) }
                model.selection = Set(picked.map(\.id))
            }
        }

        @objc func doubleClicked(_ browser: NSBrowser) {
            guard browser.clickedRow >= 0, let item = node(browser, row: browser.clickedRow, column: browser.clickedColumn)?.item,
                  !item.isFolder else { return }
            model.open(item)
        }

        // MARK: Drag and drop

        func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool {
            true
        }

        func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
            let items = rowIndexes.compactMap { node(browser, row: $0, column: column)?.item }
            guard !items.isEmpty else { return false }
            model.noteDrag(items)
            pasteboard.clearContents()
            let urls = items.compactMap(\.macURL)
            if !urls.isEmpty { pasteboard.writeObjects(urls as [NSURL]) }  // Mac files can go to Finder too
            pasteboard.setString(items.map(\.id).joined(separator: "\n"), forType: Self.itemType)
            return true
        }

        func browser(_ browser: NSBrowser, validateDrop info: NSDraggingInfo,
                     proposedRow row: UnsafeMutablePointer<Int>, column: UnsafeMutablePointer<Int>,
                     dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>) -> NSDragOperation {
            guard column.pointee >= 0 else { return [] }
            var destination: Location?
            if row.pointee >= 0, dropOperation.pointee == .on,
               let folder = node(browser, row: row.pointee, column: column.pointee)?.location {
                destination = folder
            } else {
                // Not over a folder: drop into the folder this column shows.
                row.pointee = -1
                dropOperation.pointee = .on
                destination = self.folder(of: browser, column: column.pointee)
            }
            guard let destination else { return [] }
            let isInternal = info.draggingPasteboard.types?.contains(Self.itemType) ?? false
            return model.dropOperation(to: destination, isInternal: isInternal)
        }

        func browser(_ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int,
                     dropOperation: NSBrowser.DropOperation) -> Bool {
            let destination = (row >= 0 ? node(browser, row: row, column: column)?.location : nil) ?? folder(of: browser, column: column)
            guard let destination else { return false }
            let forceCopy = NSEvent.modifierFlags.contains(.option) || info.draggingSourceOperationMask == .copy
            return model.handlePasteboardDrop(info.draggingPasteboard, to: destination, forceCopy: forceCopy)
        }

        // MARK: Right-click menu

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.delegate = self
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let browser, browser.clickedRow >= 0,
                  let clicked = node(browser, row: browser.clickedRow, column: browser.clickedColumn)?.item else { return }
            let selected = model.selectedItems
            let items = selected.contains(clicked) ? selected : [clicked]
            let model = self.model
            if items.count == 1 {
                menu.addItem(ActionItem("Open") { model.open(clicked) })
                if !clicked.isFolder { menu.addItem(ActionItem("Quick Look") { model.quickLook(clicked) }) }
                menu.addItem(ActionItem("Rename…") { model.renameTarget = clicked })
                menu.addItem(.separator())
            }
            menu.addItem(ActionItem("Copy") { model.copyToClipboard(items) })
            if items.contains(where: \.isPhone) {
                menu.addItem(ActionItem("Copy to Downloads") { model.transfer(items, to: .mac(AppModel.downloadsFolder), move: false) })
            }
            menu.addItem(ActionItem("Copy To…") { model.copy(items, toChosenFolder: true) })
            if items.count == 1, let url = clicked.macURL {
                menu.addItem(ActionItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
            }
            menu.addItem(.separator())
            menu.addItem(ActionItem(items.contains(where: \.isPhone) ? "Delete…" : "Move to Trash") { model.beginDelete(items) })
        }
    }
}

/// A column row: Finder's 16-point icon (or the photo's thumbnail) and the item's name.
final class IconBrowserCell: NSBrowserCell {
    override var objectValue: Any? {
        get { super.objectValue }
        set {
            if let node = newValue as? BrowserNode, let item = node.item {
                super.objectValue = item.displayName
                let source = MainActor.assumeIsolated { Icons.icon(for: item) }
                let icon = (source.copy() as? NSImage) ?? NSImage()
                icon.size = NSSize(width: 16, height: 16)
                image = icon
            } else {
                super.objectValue = newValue
            }
        }
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// The preview column NSBrowser shows after a selected file.
final class ColumnPreviewController: NSViewController {
    private let model: AppModel
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        host.sizingOptions = []  // let the column size the preview, never the other way round
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() { view = host }

    override var representedObject: Any? {
        didSet {
            guard let item = (representedObject as? BrowserNode)?.item else { return }
            host.rootView = AnyView(ColumnPreview(model: model, item: item))
        }
    }
}
