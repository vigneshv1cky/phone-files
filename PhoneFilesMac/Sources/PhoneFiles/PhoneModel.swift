import AppKit
import Foundation
import ImageIO
import QuickLookUI
import UniformTypeIdentifiers
import os

let log = Logger(subsystem: "local.phonefiles", category: "app")

// MARK: - Supporting types

enum ViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns, gallery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icons: return "Icons"
        case .list: return "List"
        case .columns: return "Columns"
        case .gallery: return "Gallery"
        }
    }
    var symbol: String {
        switch self {
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .columns: return "rectangle.split.3x1"
        case .gallery: return "rectangle.bottomthird.inset.filled"
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, kind, modified, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        case .size: return "Size"
        }
    }
}

extension PhoneItem {
    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var utType: UTType? { isFolder ? .folder : UTType(filenameExtension: fileExtension) }
    /// Finder-style kind, e.g. "JPEG image".
    var kind: String { isFolder ? "Folder" : (utType?.localizedDescription ?? "Document") }
    var isHidden: Bool { name.hasPrefix(".") }
    var isImage: Bool { utType?.conforms(to: .image) ?? false }
}

@MainActor
final class Transfer: ObservableObject, Identifiable {
    enum State: Equatable { case running, done, failed(String), cancelled }

    let id = UUID()
    let title: String
    let token = CancelToken()
    @Published var detail = ""
    @Published var fraction: Double = 0
    @Published var state: State = .running

    init(title: String) { self.title = title }

    func cancel() { token.cancel() }
}

/// A local copy of one phone file, fetched so it can be previewed.
@MainActor
final class PreviewLoad: ObservableObject {
    enum State: Equatable { case idle, loading, ready(URL), failed(String) }

    let item: PhoneItem
    @Published var state: State = .idle
    @Published var fraction: Double = 0
    @Published var dimensions: CGSize?
    var token = CancelToken()

    init(item: PhoneItem) { self.item = item }

    var url: URL? { if case .ready(let url) = state { return url } else { return nil } }
}

// MARK: - Model

@MainActor
final class PhoneModel: ObservableObject {
    enum Connection: Equatable { case connecting, connected, failed(String) }

    /// Files up to this size load into the preview automatically; larger ones wait for a click.
    static let autoPreviewLimit: UInt64 = 25_000_000
    static let favoriteNames = ["DCIM", "Pictures", "Download", "Documents", "Movies", "Music", "Recordings", "WhatsApp"]

    // Connection
    @Published var connection: Connection = .connecting
    @Published var info: PhoneInfo?
    @Published var battery: Int?
    @Published var storages: [PhoneStorage] = []
    @Published var storageID: UInt32?

    // Location and contents
    @Published private(set) var path: [PhoneItem] = []
    @Published private(set) var children: [UInt32: [PhoneItem]] = [:]
    @Published private(set) var loadingFolders: Set<UInt32> = []
    @Published var folderError: String?
    @Published var selection: Set<UInt32> = []
    @Published private(set) var backStack: [[PhoneItem]] = []
    @Published private(set) var forwardStack: [[PhoneItem]] = []

    // Presentation (persisted like Finder's per-user view settings)
    @Published var viewMode: ViewMode { didSet { defaults.set(viewMode.rawValue, forKey: "viewMode") } }
    @Published var sortKey: SortKey { didSet { defaults.set(sortKey.rawValue, forKey: "sortKey") } }
    @Published var ascending: Bool { didSet { defaults.set(ascending, forKey: "ascending") } }
    @Published var foldersOnTop: Bool { didSet { defaults.set(foldersOnTop, forKey: "foldersOnTop") } }
    @Published var showHidden: Bool { didSet { defaults.set(showHidden, forKey: "showHidden") } }
    @Published var showPreviewPane: Bool { didSet { defaults.set(showPreviewPane, forKey: "showPreviewPane") } }
    @Published var iconSize: Double { didSet { defaults.set(iconSize, forKey: "iconSize") } }
    @Published var listZoom: Int { didSet { defaults.set(listZoom, forKey: "listZoom") } }
    @Published var searchText = ""

    // Content caches and activity
    @Published var thumbnails: [UInt32: NSImage] = [:]
    @Published var transfers: [Transfer] = []
    @Published private(set) var previews: [UInt32: PreviewLoad] = [:]
    @Published var quickLookURL: URL?
    @Published var alertMessage: String?

    // Dialogs, owned here so menu commands can open them
    @Published var renameTarget: PhoneItem?
    @Published var pendingDelete: [PhoneItem] = []
    @Published var askNewFolder = false

    let service = PhoneService()
    private let defaults = UserDefaults.standard
    private var pendingThumbs: Set<UInt32> = []
    private weak var activePreview: PreviewLoad?

    init() {
        viewMode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .list
        sortKey = SortKey(rawValue: defaults.string(forKey: "sortKey") ?? "") ?? .name
        ascending = defaults.object(forKey: "ascending") as? Bool ?? true
        foldersOnTop = defaults.object(forKey: "foldersOnTop") as? Bool ?? true
        showHidden = defaults.bool(forKey: "showHidden")
        showPreviewPane = defaults.object(forKey: "showPreviewPane") as? Bool ?? true
        iconSize = defaults.object(forKey: "iconSize") as? Double ?? 80
        listZoom = defaults.integer(forKey: "listZoom")
    }

    // MARK: Derived state

    var currentStorage: PhoneStorage? { storages.first { $0.id == storageID } }
    var currentFolderID: UInt32 { path.last?.id ?? MTPDevice.root }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var hasActiveTransfer: Bool { transfers.contains { $0.state == .running } }
    var isLoadingCurrent: Bool { loadingFolders.contains(currentFolderID) }
    var hasListing: Bool { children[currentFolderID] != nil }

    /// Contents of a folder as shown: hidden files filtered, search applied to the current folder, sorted.
    func visible(_ folder: UInt32) -> [PhoneItem] {
        var list = children[folder] ?? []
        if !showHidden { list.removeAll(where: \.isHidden) }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if folder == currentFolderID, !query.isEmpty {
            list.removeAll { !$0.name.localizedCaseInsensitiveContains(query) }
        }
        list.sort { a, b in
            if foldersOnTop, a.isFolder != b.isFolder { return a.isFolder }
            let ordered: ComparisonResult
            switch sortKey {
            case .name: ordered = a.name.localizedStandardCompare(b.name)
            case .kind:
                let byKind = a.kind.localizedStandardCompare(b.kind)
                ordered = byKind == .orderedSame ? a.name.localizedStandardCompare(b.name) : byKind
            case .modified: ordered = a.modified == b.modified ? .orderedSame : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            case .size: ordered = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            }
            if ordered == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? ordered == .orderedAscending : ordered == .orderedDescending
        }
        return list
    }

    var visibleItems: [PhoneItem] { visible(currentFolderID) }
    var selectedItems: [PhoneItem] { visibleItems.filter { selection.contains($0.id) } }

    /// Well-known top-level folders shown under Favorites in the sidebar.
    var favorites: [PhoneItem] {
        let top = children[MTPDevice.root] ?? []
        return Self.favoriteNames.compactMap { name in top.first { $0.isFolder && $0.name == name } }
    }

    var locationDescription: String {
        ([currentStorage?.name ?? "Phone"] + path.map(\.name)).joined(separator: " › ")
    }

    // Zoom: Command-plus / Command-minus, as in Finder.
    var listIconSize: CGFloat { CGFloat(16 + 4 * listZoom) }
    var listFontSize: CGFloat { 13 + 1.5 * CGFloat(listZoom) }
    var filmstripSize: CGFloat { CGFloat(64 + 12 * listZoom) }

    func zoomIn() {
        if viewMode == .icons { iconSize = min(iconSize + 16, 256) } else { listZoom = min(listZoom + 1, 6) }
    }

    func zoomOut() {
        if viewMode == .icons { iconSize = max(iconSize - 16, 32) } else { listZoom = max(listZoom - 1, -1) }
    }

    func resetZoom() {
        if viewMode == .icons { iconSize = 80 } else { listZoom = 0 }
    }

    // MARK: Connection

    func connect() async {
        connection = .connecting
        storages = []; storageID = nil; path = []; children = [:]
        backStack = []; forwardStack = []; selection = []
        folderError = nil; thumbnails = [:]; pendingThumbs = []; previews = [:]
        _ = service.nextGeneration()
        do {
            let (info, battery) = try await service.run { dev in (try dev.connect(), dev.battery()) }
            self.info = info
            self.battery = battery
            connection = .connected
            log.info("Connected to \(info.model, privacy: .public), battery \(battery ?? -1)")
            await loadStorages()
            await runAutotestIfRequested()
        } catch {
            info = nil; battery = nil
            connection = .failed(error.localizedDescription)
            log.error("Connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadStorages() async {
        do {
            storages = try await service.run { try $0.storages() }
            log.info("Storages: \(self.storages.map(\.name).joined(separator: ", "), privacy: .public)")
            if !storages.contains(where: { $0.id == storageID }) { storageID = storages.first?.id }
            folderError = nil
            await loadFolder(currentFolderID)
        } catch {
            folderError = error.localizedDescription
            log.error("Storage failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func selectStorage(_ id: UInt32) {
        guard id != storageID else { return }
        storageID = id
        children = [:]
        backStack = []; forwardStack = []
        path = []
        selection = []
        Task { await loadFolder(MTPDevice.root) }
    }

    // MARK: Navigation

    func navigate(to newPath: [PhoneItem], recordHistory: Bool = true) {
        guard newPath.map(\.id) != path.map(\.id) else { return }
        if recordHistory {
            backStack.append(path)
            forwardStack.removeAll()
        }
        path = newPath
        selection = []
        searchText = ""
        _ = service.nextGeneration()
        Task { await loadFolder(currentFolderID) }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(path)
        navigate(to: previous, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(path)
        navigate(to: next, recordHistory: false)
    }

    func goUp() {
        guard !path.isEmpty else { return }
        let child = path.last
        navigate(to: Array(path.dropLast()))
        if let child { selection = [child.id] }  // Finder keeps the folder you came from selected
    }

    /// Jump to a breadcrumb; -1 means the storage's top level.
    func goTo(depth: Int) {
        navigate(to: Array(path.prefix(depth + 1)))
    }

    /// Column view: clicking an item in column `index` (0 = top level).
    func columnSelect(_ item: PhoneItem, at index: Int) {
        if item.isFolder {
            navigate(to: Array(path.prefix(index)) + [item])
        } else {
            if index < path.count { navigate(to: Array(path.prefix(index))) }
            selection = [item.id]
        }
    }

    /// Double-click / Command-Down: folders open in place, files open in their default Mac app.
    func open(_ item: PhoneItem) {
        if item.isFolder {
            navigate(to: path + [item])
        } else {
            Task {
                do {
                    let url = try await ensureLocalCopy(of: item)
                    NSWorkspace.shared.open(url)
                } catch {
                    alertMessage = "Could not open \(item.name): \(error.localizedDescription)"
                }
            }
        }
    }

    func openSelection() {
        let items = selectedItems
        if items.count == 1 { open(items[0]) } else { items.filter { !$0.isFolder }.forEach(open) }
    }

    func refresh() async {
        if connection != .connected { return await connect() }
        battery = try? await service.run { $0.battery() }
        if storages.isEmpty { return await loadStorages() }
        if let fresh = try? await service.run({ try $0.storages() }) { storages = fresh }
        let folders = viewMode == .columns ? [MTPDevice.root] + path.map(\.id) : [currentFolderID]
        for folder in folders { await loadFolder(folder) }
    }

    /// Makes sure each folder has a listing (column view needs every folder along the path).
    func ensureLoaded(_ folders: [UInt32]) async {
        for folder in folders where children[folder] == nil && !loadingFolders.contains(folder) {
            await loadFolder(folder)
        }
    }

    func loadFolder(_ folder: UInt32) async {
        guard let storage = storageID else { return }
        loadingFolders.insert(folder)
        if folder == currentFolderID { folderError = nil }
        defer { loadingFolders.remove(folder) }
        do {
            let list = try await service.run { try $0.list(storage: storage, parent: folder) }
            guard storage == storageID else { return }
            children[folder] = list
            let name = folder == MTPDevice.root ? "top level" : (path.first { $0.id == folder }?.name ?? "folder \(folder)")
            log.info("Listed \(name, privacy: .public): \(list.count) items")
        } catch {
            guard storage == storageID else { return }
            if folder == currentFolderID { folderError = error.localizedDescription }
            log.error("List failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Thumbnails

    func loadThumbnail(for item: PhoneItem) {
        guard FileKind(item).hasThumbnail, thumbnails[item.id] == nil, !pendingThumbs.contains(item.id) else { return }
        pendingThumbs.insert(item.id)
        let generation = service.generation
        let service = self.service
        Task {
            let data = try? await service.run { dev -> Data? in
                // Skip requests queued for a folder the user has already left.
                guard service.generation == generation else { return nil }
                return dev.thumbnail(item.id)
            }
            pendingThumbs.remove(item.id)
            if let data = data ?? nil, let image = NSImage(data: data) {
                thumbnails[item.id] = image
            }
        }
    }

    // MARK: Preview

    /// Starts fetching a file for the preview pane, gallery and column preview.
    /// Small files load automatically; `force` loads large ones too.
    func requestPreview(_ item: PhoneItem, force: Bool) {
        guard !item.isFolder else { return }
        let load: PreviewLoad
        if let existing = previews[item.id] {
            load = existing
        } else {
            load = PreviewLoad(item: item)
            previews[item.id] = load
        }
        if let url = load.url, FileManager.default.fileExists(atPath: url.path) { return }
        if load.state == .loading { return }
        if !force && item.size > Self.autoPreviewLimit { return }

        // Moving to another file abandons the previous automatic fetch so the phone isn't
        // kept busy sending a file nobody is looking at any more.
        if let active = activePreview, active !== load, active.state == .loading { active.token.cancel() }
        activePreview = load

        let token = CancelToken()
        load.token = token
        load.state = .loading
        load.fraction = 0
        Task {
            do {
                let url = try await cachedCopy(of: item, token: token) { load.fraction = $0 }
                load.dimensions = item.isImage ? Self.pixelSize(of: url) : nil
                load.state = .ready(url)
            } catch {
                load.state = token.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func quickLook(_ item: PhoneItem) {
        guard !item.isFolder else { return open(item) }
        Task {
            do {
                quickLookURL = try await ensureLocalCopy(of: item)
            } catch {
                alertMessage = "Could not preview \(item.name): \(error.localizedDescription)"
            }
        }
    }

    func quickLookSelection() {
        if quickLookURL != nil { quickLookURL = nil; return }  // Space toggles, as in Finder
        if let item = selectedItems.first { quickLook(item) }
    }

    /// A local copy for Quick Look or opening in another app. Large files show in Transfers.
    func ensureLocalCopy(of item: PhoneItem) async throws -> URL {
        if let url = previews[item.id]?.url, FileManager.default.fileExists(atPath: url.path) { return url }
        let transfer = item.size > Self.autoPreviewLimit ? startTransfer("Opening \(item.name)") : nil
        let token = transfer?.token ?? CancelToken()
        do {
            let url = try await cachedCopy(of: item, token: token) { transfer?.fraction = $0 }
            if let transfer { finish(transfer, .done) }
            let load = previews[item.id] ?? PreviewLoad(item: item)
            load.dimensions = item.isImage ? Self.pixelSize(of: url) : nil
            load.state = .ready(url)
            previews[item.id] = load
            return url
        } catch {
            if let transfer { finish(transfer, token.isCancelled ? .cancelled : .failed(error.localizedDescription)) }
            throw error
        }
    }

    private static var previewDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneFilesPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Fetches into the preview cache, reusing an earlier complete copy.
    private func cachedCopy(of item: PhoneItem, token: CancelToken,
                            progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let url = Self.previewDirectory.appendingPathComponent("\(item.id)-\(item.name)")
        if Self.fileSize(url) == item.size, FileManager.default.fileExists(atPath: url.path) { return url }
        try await fetch(item, to: url, token: token, doneBytes: 0, totalBytes: max(item.size, 1), progress: progress)
        return url
    }

    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: Download

    func downloadSelection() { download(selectedItems, to: Self.downloadsFolder) }

    func downloadSelectionTo() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        if panel.runModal() == .OK, let url = panel.url { download(items, to: url) }
    }

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func download(_ selection: [PhoneItem], to directory: URL, reveal: Bool = true) {
        guard !selection.isEmpty else { return }
        let label = selection.count == 1 ? selection[0].name : "\(selection.count) items"
        let transfer = startTransfer("Downloading \(label)")
        Task {
            do {
                let urls = try await performDownload(selection, to: directory, transfer: transfer)
                finish(transfer, .done)
                if reveal { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            } catch {
                finish(transfer, transfer.token.isCancelled ? .cancelled : .failed(error.localizedDescription))
            }
        }
    }

    /// Copies items (folders recursively) into `directory`; returns the top-level copies.
    private func performDownload(_ selection: [PhoneItem], to directory: URL, transfer: Transfer) async throws -> [URL] {
        transfer.detail = "Listing files…"
        var jobs: [(PhoneItem, URL)] = []
        var topLevel: [URL] = []
        for item in selection {
            let target = Self.uniqueURL(in: directory, name: item.name)
            topLevel.append(target)
            if item.isFolder {
                try await collect(item, into: target, jobs: &jobs, token: transfer.token)
            } else {
                jobs.append((item, target))
            }
        }
        let total = max(jobs.reduce(0) { $0 + $1.0.size }, 1)
        var done: UInt64 = 0
        for (index, (item, target)) in jobs.enumerated() {
            if transfer.token.isCancelled { throw CancellationError() }
            transfer.detail = "\(index + 1) of \(jobs.count) · \(item.name)"
            try await fetch(item, to: target, token: transfer.token, doneBytes: done, totalBytes: total) { transfer.fraction = $0 }
            done += item.size
        }
        transfer.detail = "\(jobs.count) file\(jobs.count == 1 ? "" : "s") · \(Self.format(bytes: done))"
        return topLevel
    }

    /// Recreates a phone folder locally and queues every file inside it.
    private func collect(_ folder: PhoneItem, into local: URL, jobs: inout [(PhoneItem, URL)], token: CancelToken) async throws {
        if token.isCancelled { throw CancellationError() }
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let children = try await service.run { try $0.list(storage: folder.storage, parent: folder.id) }
        for child in children {
            let target = local.appendingPathComponent(child.name)
            if child.isFolder {
                try await collect(child, into: target, jobs: &jobs, token: token)
            } else {
                jobs.append((child, target))
            }
        }
    }

    private func fetch(_ item: PhoneItem, to url: URL, token: CancelToken, doneBytes: UInt64, totalBytes: UInt64,
                       progress: @escaping @MainActor (Double) -> Void) async throws {
        let throttle = Throttle()
        try await service.run { dev in
            try dev.download(item.id, to: url) { sent, _ in
                if throttle.shouldFire() {
                    let fraction = Double(doneBytes + sent) / Double(totalBytes)
                    Task { @MainActor in progress(fraction) }
                }
                return !token.isCancelled
            }
        }
        progress(Double(doneBytes + item.size) / Double(totalBytes))
    }

    // MARK: Drag out to Finder

    /// Lets an item be dragged to Finder or the Desktop; the file is copied off the phone on drop.
    func dragProvider(for item: PhoneItem) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = item.name
        let type = item.utType ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    completion(try await self.exportForDrag(item), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    private func exportForDrag(_ item: PhoneItem) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneFilesDrag", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transfer = startTransfer("Copying \(item.name)")
        do {
            let urls = try await performDownload([item], to: dir, transfer: transfer)
            finish(transfer, .done)
            return urls[0]
        } catch {
            finish(transfer, transfer.token.isCancelled ? .cancelled : .failed(error.localizedDescription))
            throw error
        }
    }

    // MARK: Upload

    func pickUploads() {
        guard storageID != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Phone"
        if panel.runModal() == .OK { upload(panel.urls) }
    }

    func upload(_ urls: [URL]) {
        guard let storage = storageID, !urls.isEmpty else { return }
        let parent = currentFolderID
        let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        let transfer = startTransfer("Uploading \(label)")
        Task {
            do {
                var jobs: [(URL, UInt32)] = []
                for url in urls {
                    try await plan(url, storage: storage, parent: parent, jobs: &jobs)
                }
                let sizes = jobs.map { Self.fileSize($0.0) }
                let total = max(sizes.reduce(0, +), 1)
                var done: UInt64 = 0
                let token = transfer.token
                for (index, (url, folder)) in jobs.enumerated() {
                    if token.isCancelled { throw CancellationError() }
                    transfer.detail = "\(index + 1) of \(jobs.count) · \(url.lastPathComponent)"
                    let throttle = Throttle()
                    let before = done
                    _ = try await service.run { dev in
                        try dev.upload(url, name: url.lastPathComponent, storage: storage, parent: folder) { sent, _ in
                            if throttle.shouldFire() {
                                let fraction = Double(before + sent) / Double(total)
                                Task { @MainActor in transfer.fraction = fraction }
                            }
                            return !token.isCancelled
                        }
                    }
                    done += sizes[index]
                    transfer.fraction = Double(done) / Double(total)
                }
                transfer.detail = "\(jobs.count) file\(jobs.count == 1 ? "" : "s") · \(Self.format(bytes: done))"
                finish(transfer, .done)
            } catch {
                finish(transfer, transfer.token.isCancelled ? .cancelled : .failed(error.localizedDescription))
            }
            if storage == storageID { await loadFolder(parent) }
        }
    }

    /// Mac folders become phone folders; files are queued against their phone parent.
    private func plan(_ url: URL, storage: UInt32, parent: UInt32, jobs: inout [(URL, UInt32)]) async throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            let name = url.lastPathComponent
            let folder = try await service.run { try $0.makeFolder(name, storage: storage, parent: parent) }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for child in children {
                try await plan(child, storage: storage, parent: folder, jobs: &jobs)
            }
        } else {
            jobs.append((url, parent))
        }
    }

    /// Edit › Paste with files copied in Finder uploads them here.
    func uploadFromPasteboard() {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        upload(urls)
    }

    // MARK: New folder, rename, delete

    func makeFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let storage = storageID, !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let parent = currentFolderID
        Task {
            do {
                let id = try await service.run { try $0.makeFolder(trimmed, storage: storage, parent: parent) }
                await loadFolder(parent)
                selection = [id]
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func beginRename() {
        if selectedItems.count == 1 { renameTarget = selectedItems[0] }
    }

    func rename(_ item: PhoneItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != item.name else { return }
        Task {
            do {
                try await service.run { try $0.rename(item.id, to: trimmed) }
                previews[item.id] = nil  // cached copy carries the old name
                await loadFolder(item.parent == 0 ? MTPDevice.root : item.parent)
                selection = [item.id]
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func beginDelete() {
        if !selectedItems.isEmpty { pendingDelete = selectedItems }
    }

    func confirmDelete() {
        let items = pendingDelete
        pendingDelete = []
        selection.subtract(items.map(\.id))
        Task {
            for item in items {
                do {
                    try await service.run { try $0.delete(item.id) }
                } catch {
                    alertMessage = "Could not delete \(item.name): \(error.localizedDescription)"
                    break
                }
            }
            await loadFolder(currentFolderID)
            if let fresh = try? await service.run({ try $0.storages() }) { storages = fresh }
        }
    }

    // MARK: Transfers

    private func startTransfer(_ title: String) -> Transfer {
        let transfer = Transfer(title: title)
        transfers.insert(transfer, at: 0)
        return transfer
    }

    private func finish(_ transfer: Transfer, _ state: Transfer.State) {
        transfer.state = state
        if state == .done { transfer.fraction = 1 }
        if case .failed(let message) = state { transfer.detail = message }
        if state == .cancelled { transfer.detail = "Cancelled" }
    }

    func clearFinishedTransfers() {
        transfers.removeAll { $0.state != .running }
    }

    // MARK: Formatting

    static func format(bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }

    /// "photo.jpg" -> "photo (1).jpg" when the name is taken.
    static func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: Developer self-test

    /// PHONEFILES_AUTOTEST="Pictures,DCIM": for each top-level folder, open it, show it in every
    /// view mode, load a preview, open Quick Look, check the panel appeared, then go back.
    /// Lets the UI be exercised without clicking; results go to the log.
    private func runAutotestIfRequested() async {
        guard let spec = ProcessInfo.processInfo.environment["PHONEFILES_AUTOTEST"] else { return }
        let originalMode = viewMode
        let originalPane = showPreviewPane
        if let pane = ProcessInfo.processInfo.environment["PHONEFILES_AUTOTEST_PANE"] { showPreviewPane = pane == "1" }
        log.info("Autotest: starting in \(self.viewMode.title, privacy: .public)")
        for name in spec.split(separator: ",").map(String.init) {
            try? await Task.sleep(for: .seconds(1.5))
            guard let folder = visibleItems.first(where: { $0.isFolder && $0.name == name }) else {
                log.error("Autotest: no folder \(name, privacy: .public)")
                continue
            }
            navigate(to: path + [folder])
            for _ in 0..<40 where !hasListing { try? await Task.sleep(for: .milliseconds(100)) }
            for mode in ViewMode.allCases {
                log.info("Autotest: switching to \(mode.title, privacy: .public), preview pane \(self.showPreviewPane ? "open" : "closed", privacy: .public)")
                viewMode = mode
                try? await Task.sleep(for: .seconds(1.5))
                log.info("Autotest: \(name, privacy: .public) shown as \(mode.title, privacy: .public)")
            }
            // Real Command-key presses, posted through the normal event queue so the menu bar
            // and key monitor see them exactly as they would a keyboard.
            for mode in [ViewMode.icons, .list] {
                viewMode = mode
                try? await Task.sleep(for: .seconds(0.8))
                let before = (iconSize, listZoom)
                Self.postCommandKey("=", keyCode: 24)
                try? await Task.sleep(for: .seconds(0.5))
                let afterEquals = (iconSize, listZoom)
                Self.postCommandKey("+", keyCode: 24, shift: true)
                try? await Task.sleep(for: .seconds(0.5))
                let afterPlus = (iconSize, listZoom)
                Self.postCommandKey("-", keyCode: 27)
                try? await Task.sleep(for: .seconds(0.5))
                let afterMinus = (iconSize, listZoom)
                Self.postCommandKey("0", keyCode: 29)
                try? await Task.sleep(for: .seconds(0.5))
                log.info("Autotest: \(mode.title, privacy: .public) zoom (icon size, list zoom) start \(before.0)/\(before.1) → ⌘= \(afterEquals.0)/\(afterEquals.1) → ⌘+ \(afterPlus.0)/\(afterPlus.1) → ⌘- \(afterMinus.0)/\(afterMinus.1) → ⌘0 \(self.iconSize)/\(self.listZoom)")
            }
            if let file = visibleItems.first(where: { !$0.isFolder && $0.size <= Self.autoPreviewLimit }) {
                showPreviewPane = true
                selection = [file.id]
                requestPreview(file, force: false)
                for _ in 0..<100 where previews[file.id]?.url == nil { try? await Task.sleep(for: .milliseconds(100)) }
                log.info("Autotest: preview pane for \(file.name, privacy: .public): \(self.previews[file.id]?.url == nil ? "NOT ready" : "ready", privacy: .public)")
                quickLook(file)
                try? await Task.sleep(for: .seconds(2.5))
                let visible = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
                log.info("Autotest: Quick Look panel visible: \(visible, privacy: .public)")
                quickLookURL = nil
                try? await Task.sleep(for: .seconds(1))

                // Real key presses in List view: Space should open Quick Look, Return should rename.
                viewMode = .list
                selection = [file.id]
                try? await Task.sleep(for: .seconds(1))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                   let table = Self.findTable(in: window.contentView!) {
                    window.makeFirstResponder(table)
                    Self.sendKey(" ", keyCode: 49, to: window)
                    try? await Task.sleep(for: .seconds(2.5))
                    let spaceWorks = QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
                    log.info("Autotest: Space key opened Quick Look: \(spaceWorks, privacy: .public)")
                    Self.sendKey(" ", keyCode: 49, to: window)  // Space again closes it
                    try? await Task.sleep(for: .seconds(1))
                    let closed = !(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible)
                    log.info("Autotest: second Space closed Quick Look: \(closed, privacy: .public)")
                    quickLookURL = nil
                    window.makeFirstResponder(table)
                    Self.sendKey("\r", keyCode: 36, to: window)
                    try? await Task.sleep(for: .seconds(0.5))
                    log.info("Autotest: Return key started rename: \(self.renameTarget != nil, privacy: .public)")
                    renameTarget = nil
                } else {
                    log.error("Autotest: list table not found")
                }
            }
            goBack()
            log.info("Autotest: back at \(self.path.isEmpty ? "top level" : self.path.last!.name, privacy: .public), can go forward: \(self.canGoForward)")
        }
        viewMode = originalMode
        showPreviewPane = originalPane
        log.info("Autotest: finished")
    }
}

extension PhoneModel {
    fileprivate static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for sub in view.subviews { if let found = findTable(in: sub) { return found } }
        return nil
    }

    fileprivate static func postCommandKey(_ chars: String, keyCode: UInt16, shift: Bool = false) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        let flags: NSEvent.ModifierFlags = shift ? [.command, .shift] : [.command]
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: keyCode) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    fileprivate static func sendKey(_ chars: String, keyCode: UInt16, to window: NSWindow) {
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

/// Limits progress updates from the MTP queue to about ten per second.
final class Throttle: @unchecked Sendable {
    private var last = Date.distantPast
    func shouldFire() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.1 else { return false }
        last = now
        return true
    }
}

/// Icon symbol and whether the phone can supply a thumbnail.
struct FileKind {
    let symbol: String
    let hasThumbnail: Bool

    init(_ item: PhoneItem) {
        guard !item.isFolder else { symbol = "folder.fill"; hasThumbnail = false; return }
        switch item.fileExtension {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "dng":
            symbol = "photo"; hasThumbnail = true
        case "mp4", "mov", "webm", "3gp", "mkv", "avi":
            symbol = "film"; hasThumbnail = true
        case "mp3", "m4a", "wav", "ogg", "flac", "aac", "opus", "amr":
            symbol = "music.note"; hasThumbnail = false
        case "pdf":
            symbol = "doc.richtext"; hasThumbnail = false
        case "zip", "rar", "7z", "gz", "tar":
            symbol = "doc.zipper"; hasThumbnail = false
        case "apk":
            symbol = "app.badge"; hasThumbnail = false
        case "txt", "md", "json", "csv", "xml", "html":
            symbol = "doc.text"; hasThumbnail = false
        default:
            symbol = "doc"; hasThumbnail = false
        }
    }
}
