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

/// A sidebar entry. Mac places are fixed; phone entries appear when the phone is connected.
enum SidebarTarget: Hashable {
    case mac(URL)
    case phone(storage: UInt32)
    case phoneFolder(PhoneItem)
}

struct SidebarPlace: Identifiable {
    let title: String
    let symbol: String
    let url: URL
    var id: String { url.path }
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

/// A local copy of a phone file, fetched so it can be previewed. (Mac files preview directly.)
@MainActor
final class PreviewLoad: ObservableObject {
    enum State: Equatable { case idle, loading, ready(URL), failed(String) }

    let item: FileItem
    @Published var state: State = .idle
    @Published var fraction: Double = 0
    var token = CancelToken()

    init(item: FileItem) { self.item = item }

    var url: URL? { if case .ready(let url) = state { return url } else { return nil } }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    enum Connection: Equatable { case idle, connecting, connected, failed(String) }

    /// Phone files up to this size load into the preview automatically; larger ones wait for a click.
    static let autoPreviewLimit: UInt64 = 25_000_000
    static let phoneFavoriteNames = ["DCIM", "Pictures", "Download", "Documents", "Movies", "Music", "Recordings", "WhatsApp"]

    // Phone
    @Published private(set) var connection: Connection = .idle
    @Published private(set) var info: PhoneInfo?
    @Published private(set) var battery: Int?
    @Published private(set) var storages: [PhoneStorage] = []
    @Published private(set) var storageError: String?

    // Where we are and what's there
    @Published private(set) var location: Location
    @Published private(set) var macColumnRoot: URL
    @Published private(set) var children: [FolderKey: [FileItem]] = [:]
    @Published private(set) var loading: Set<FolderKey> = []
    @Published private(set) var folderErrors: [FolderKey: String] = [:]
    @Published var selection: Set<String> = []
    @Published private(set) var backStack: [Location] = []
    @Published private(set) var forwardStack: [Location] = []
    @Published private(set) var availableSpace: UInt64?

    // Presentation (persisted like Finder's view settings)
    @Published var viewMode: ViewMode { didSet { defaults.set(viewMode.rawValue, forKey: "viewMode") } }
    @Published var sortKey: SortKey { didSet { defaults.set(sortKey.rawValue, forKey: "sortKey") } }
    @Published var ascending: Bool { didSet { defaults.set(ascending, forKey: "ascending") } }
    @Published var foldersOnTop: Bool { didSet { defaults.set(foldersOnTop, forKey: "foldersOnTop") } }
    @Published var showHidden: Bool { didSet { defaults.set(showHidden, forKey: "showHidden") } }
    @Published var showPreviewPane: Bool { didSet { defaults.set(showPreviewPane, forKey: "showPreviewPane") } }
    @Published var iconSize: Double { didSet { defaults.set(iconSize, forKey: "iconSize") } }
    @Published var listZoom: Int { didSet { defaults.set(listZoom, forKey: "listZoom") } }
    @Published var searchText = ""

    // Caches and activity
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var previews: [String: PreviewLoad] = [:]
    @Published var quickLookURL: URL?
    @Published var alertMessage: String?
    @Published var dropTargetID: String?

    // Dialogs, owned here so menu commands can open them
    @Published var renameTarget: FileItem?
    @Published var pendingDelete: [FileItem] = []
    @Published var askNewFolder = false

    let service = PhoneService()
    private let defaults = UserDefaults.standard
    private let watcher = FolderWatcher()
    private var pendingThumbs: Set<String> = []
    private weak var activePreview: PreviewLoad?
    private var dimensionCache: [String: CGSize] = [:]
    private var clipboard: [FileItem] = []
    private var clipboardChangeCount = -1
    private var dragRegistry: [String: FileItem] = [:]
    private var dragSourceIsPhone: Bool?

    init() {
        viewMode = ViewMode(rawValue: defaults.string(forKey: "viewMode") ?? "") ?? .list
        sortKey = SortKey(rawValue: defaults.string(forKey: "sortKey") ?? "") ?? .name
        ascending = defaults.object(forKey: "ascending") as? Bool ?? true
        foldersOnTop = defaults.object(forKey: "foldersOnTop") as? Bool ?? true
        showHidden = defaults.bool(forKey: "showHidden")
        showPreviewPane = defaults.object(forKey: "showPreviewPane") as? Bool ?? true
        iconSize = defaults.object(forKey: "iconSize") as? Double ?? 80
        listZoom = defaults.integer(forKey: "listZoom")

        let start = ProcessInfo.processInfo.environment["PHONEFILES_AUTOTEST_MAC"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        location = .mac(start.standardizedFileURL)
        macColumnRoot = start.standardizedFileURL
    }

    /// Called once the window is up: show the start folder and look for the phone.
    func start() async {
        navigate(to: location, record: false, force: true)
        await connectPhone()
        await runAutotestIfRequested()
    }

    // MARK: Names and places

    var phoneName: String {
        guard let info else { return "Phone" }
        return info.name.isEmpty ? info.model : info.name
    }

    var currentStorage: PhoneStorage? {
        if case .phone(let storage, _) = location { return storages.first { $0.id == storage } }
        return storages.first
    }

    func title(of location: Location) -> String {
        switch location {
        case .mac(let url):
            return url.path == "/" ? MacFiles.volumeName(url) : FileManager.default.displayName(atPath: url.path)
        case .phone(_, let path):
            return path.last?.name ?? phoneName
        }
    }

    var currentTitle: String { title(of: location) }

    /// Path bar entries from the volume (or phone) down to the current folder.
    var breadcrumbs: [(title: String, location: Location)] {
        switch location {
        case .mac(let url):
            var crumbs: [(String, Location)] = []
            var u = url.standardizedFileURL
            while true {
                crumbs.insert((title(of: .mac(u)), .mac(u)), at: 0)
                if u.path == "/" { break }
                u = u.deletingLastPathComponent().standardizedFileURL
            }
            return crumbs
        case .phone(let storage, let path):
            return [(phoneName, .phone(storage: storage, path: []))]
                + path.indices.map { (path[$0].name, .phone(storage: storage, path: Array(path.prefix($0 + 1)))) }
        }
    }

    static var macFavorites: [SidebarPlace] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let places = [
            SidebarPlace(title: "Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")),
            SidebarPlace(title: "Desktop", symbol: "menubar.dock.rectangle", url: home.appendingPathComponent("Desktop")),
            SidebarPlace(title: "Documents", symbol: "doc", url: home.appendingPathComponent("Documents")),
            SidebarPlace(title: "Downloads", symbol: "arrow.down.circle", url: home.appendingPathComponent("Downloads")),
            SidebarPlace(title: home.lastPathComponent, symbol: "house", url: home),
            SidebarPlace(title: "Pictures", symbol: "photo", url: home.appendingPathComponent("Pictures")),
            SidebarPlace(title: "Movies", symbol: "film", url: home.appendingPathComponent("Movies")),
            SidebarPlace(title: "Music", symbol: "music.note", url: home.appendingPathComponent("Music")),
        ]
        return places.filter { fm.fileExists(atPath: $0.url.path) }
    }

    static var volumes: [SidebarPlace] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let isInternalDrive = (try? url.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal) ?? true
            return SidebarPlace(title: MacFiles.volumeName(url), symbol: isInternalDrive ? "internaldrive" : "externaldrive", url: url)
        }
    }

    /// Well-known phone folders shown under the phone's name in the sidebar.
    var phoneFavorites: [PhoneItem] {
        guard let storage = storages.first?.id else { return [] }
        let top = children[.phone(storage: storage, folder: MTPDevice.root)] ?? []
        return Self.phoneFavoriteNames.compactMap { name in top.first { $0.isFolder && $0.name == name }?.phoneItem }
    }

    var sidebarSelection: SidebarTarget? {
        switch location {
        case .mac(let url): return .mac(url)
        case .phone(let storage, let path):
            if path.isEmpty { return .phone(storage: storage) }
            return path.count == 1 ? .phoneFolder(path[0]) : nil
        }
    }

    func open(_ target: SidebarTarget) {
        switch target {
        case .mac(let url): navigate(to: .mac(url), columnRoot: url)
        case .phone(let storage): navigate(to: .phone(storage: storage, path: []))
        case .phoneFolder(let folder): navigate(to: .phone(storage: folder.storage, path: [folder]))
        }
    }

    // MARK: Listing

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var hasActiveTransfer: Bool { transfers.contains { $0.state == .running } }
    var isLoadingCurrent: Bool { loading.contains(location.key) }
    var hasListing: Bool { children[location.key] != nil }
    var currentError: String? { folderErrors[location.key] }

    /// A folder's contents as shown: hidden files filtered, search applied to the current folder, sorted.
    func visible(_ key: FolderKey) -> [FileItem] {
        var list = children[key] ?? []
        if !showHidden { list.removeAll(where: \.isHidden) }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if key == location.key, !query.isEmpty {
            list.removeAll { !$0.displayName.localizedCaseInsensitiveContains(query) }
        }
        list.sort { a, b in
            if foldersOnTop, a.isFolder != b.isFolder { return a.isFolder }
            let ordered: ComparisonResult
            switch sortKey {
            case .name: ordered = a.displayName.localizedStandardCompare(b.displayName)
            case .kind:
                let byKind = a.kind.localizedStandardCompare(b.kind)
                ordered = byKind == .orderedSame ? a.displayName.localizedStandardCompare(b.displayName) : byKind
            case .modified: ordered = a.modified == b.modified ? .orderedSame : (a.modified < b.modified ? .orderedAscending : .orderedDescending)
            case .size: ordered = a.size == b.size ? .orderedSame : (a.size < b.size ? .orderedAscending : .orderedDescending)
            }
            if ordered == .orderedSame { return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending }
            return ascending ? ordered == .orderedAscending : ordered == .orderedDescending
        }
        return list
    }

    var visibleItems: [FileItem] { visible(location.key) }
    var selectedItems: [FileItem] { visibleItems.filter { selection.contains($0.id) } }

    /// Column view: every folder from the starting point down to the current one.
    var columnLocations: [Location] {
        switch location {
        case .mac(let url):
            var urls: [URL] = []
            var u = url.standardizedFileURL
            let root = macColumnRoot.standardizedFileURL.path
            while true {
                urls.insert(u, at: 0)
                if u.path == root || u.path == "/" { break }
                u = u.deletingLastPathComponent().standardizedFileURL
            }
            return urls.map { .mac($0) }
        case .phone(let storage, let path):
            return (0...path.count).map { .phone(storage: storage, path: Array(path.prefix($0))) }
        }
    }

    /// The ID of the folder item that leads into `location` (to highlight it in the column before).
    func itemID(leadingTo location: Location) -> String? {
        switch location {
        case .mac(let url): return "mac:" + url.standardizedFileURL.path
        case .phone(let storage, let path): return path.last.map { "phone:\(storage):\($0.id)" }
        }
    }

    func child(_ folder: FileItem, of parent: Location) -> Location {
        switch folder.source {
        case .mac(let url): return .mac(url)
        case .phone(let item):
            if case .phone(let storage, let path) = parent { return .phone(storage: storage, path: path + [item]) }
            return .phone(storage: item.storage, path: [item])
        }
    }

    // MARK: Navigation

    func navigate(to newLocation: Location, record: Bool = true, columnRoot: URL? = nil, force: Bool = false) {
        guard force || newLocation != location else { return }
        if record && newLocation != location {
            backStack.append(location)
            forwardStack.removeAll()
        }
        location = newLocation
        selection = []
        searchText = ""
        _ = service.nextGeneration()
        switch newLocation {
        case .mac(let url):
            if let columnRoot {
                macColumnRoot = columnRoot.standardizedFileURL
            } else if !(url.standardizedFileURL.path + "/").hasPrefix(macColumnRoot.path == "/" ? "/" : macColumnRoot.path + "/") {
                macColumnRoot = url.standardizedFileURL
            }
            availableSpace = MacFiles.availableSpace(at: url)
            watcher.watch(url) { [weak self] in
                guard let self, self.location.key == newLocation.key else { return }
                Task { await self.load(newLocation.key) }
            }
        case .phone:
            watcher.watch(nil) {}
            availableSpace = currentStorage?.free
        }
        Task { await load(newLocation.key) }
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        navigate(to: previous, record: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        navigate(to: next, record: false)
    }

    func goUp() {
        switch location {
        case .mac(let url):
            guard url.path != "/" else { return }
            let current = "mac:" + url.standardizedFileURL.path
            navigate(to: .mac(url.deletingLastPathComponent().standardizedFileURL))
            selection = [current]  // Finder keeps the folder you came from selected
        case .phone(let storage, let path):
            guard let last = path.last else { return }
            navigate(to: .phone(storage: storage, path: Array(path.dropLast())))
            selection = ["phone:\(storage):\(last.id)"]
        }
    }

    var canGoUp: Bool {
        switch location {
        case .mac(let url): return url.path != "/"
        case .phone(_, let path): return !path.isEmpty
        }
    }

    /// Column view: clicking an item in the column showing `parent`.
    func columnSelect(_ item: FileItem, in parent: Location) {
        if item.isFolder {
            navigate(to: child(item, of: parent))
        } else {
            if parent != location { navigate(to: parent) }
            selection = [item.id]
        }
    }

    /// Double-click / Command-Down: folders open in place, files open in their default Mac app.
    func open(_ item: FileItem) {
        if item.isFolder { return navigate(to: child(item, of: location)) }
        switch item.source {
        case .mac(let url):
            NSWorkspace.shared.open(url)
        case .phone:
            Task {
                do { NSWorkspace.shared.open(try await ensureLocalCopy(of: item)) } catch {
                    alertMessage = "Could not open \(item.name): \(error.localizedDescription)"
                }
            }
        }
    }

    func openSelection() {
        let items = selectedItems
        if items.count == 1 { open(items[0]) } else { items.filter { !$0.isFolder }.forEach(open) }
    }

    func selectAll() { selection = Set(visibleItems.map(\.id)) }

    // MARK: Loading

    func load(_ key: FolderKey) async {
        loading.insert(key)
        defer { loading.remove(key) }
        switch key {
        case .mac(let path):
            let url = URL(fileURLWithPath: path)
            do {
                let list = try await Task.detached(priority: .userInitiated) { try MacFiles.list(url) }.value
                children[key] = list
                folderErrors[key] = nil
            } catch {
                folderErrors[key] = Self.describe(error, at: url)
            }
        case .phone(let storage, let folder):
            guard connection == .connected else { return }
            do {
                let list = try await service.run { try $0.list(storage: storage, parent: folder) }
                children[key] = list.map(FileItem.init(phone:))
                folderErrors[key] = nil
                log.info("Listed phone folder \(folder): \(list.count) items")
            } catch {
                folderErrors[key] = error.localizedDescription
                log.error("Phone list failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Reloads a folder only if it has been shown before (keeps caches fresh after changes).
    private func reloadIfCached(_ key: FolderKey) async {
        if children[key] != nil || key == location.key { await load(key) }
    }

    func ensureLoaded(_ locations: [Location]) async {
        for key in locations.map(\.key) where children[key] == nil && !loading.contains(key) {
            await load(key)
        }
    }

    func refresh() async {
        if location.isPhone, connection != .connected { return await connectPhone() }
        if connection == .connected {
            battery = try? await service.run { $0.battery() }
            if let fresh = try? await service.run({ try $0.storages() }) { storages = fresh }
        }
        let keys = viewMode == .columns ? columnLocations.map(\.key) : [location.key]
        for key in keys { await load(key) }
        if let url = location.macURL { availableSpace = MacFiles.availableSpace(at: url) } else { availableSpace = currentStorage?.free }
    }

    private static func describe(_ error: Error, at url: URL) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError {
            return "Phone Files doesn’t have permission to see “\(url.lastPathComponent)”. Allow it in System Settings › Privacy & Security › Files and Folders."
        }
        return error.localizedDescription
    }

    // MARK: Phone connection

    func connectPhone() async {
        connection = .connecting
        info = nil; battery = nil; storages = []; storageError = nil
        // The phone renumbers every object per session, so drop everything cached from before.
        children = children.filter { if case .phone = $0.key { return false } else { return true } }
        folderErrors = folderErrors.filter { if case .phone = $0.key { return false } else { return true } }
        thumbnails = thumbnails.filter { !$0.key.hasPrefix("phone:") }
        previews = previews.filter { !$0.key.hasPrefix("phone:") }
        pendingThumbs = pendingThumbs.filter { !$0.hasPrefix("phone:") }
        _ = service.nextGeneration()
        do {
            let (info, battery) = try await service.run { dev in (try dev.connect(), dev.battery()) }
            self.info = info
            self.battery = battery
            connection = .connected
            log.notice("Connected to \(info.model, privacy: .public), battery \(battery ?? -1)")
            do {
                storages = try await service.run { try $0.storages() }
            } catch {
                storageError = error.localizedDescription
                log.notice("Phone storage unavailable: \(error.localizedDescription, privacy: .public)")
            }
            if let storage = storages.first?.id {
                await load(.phone(storage: storage, folder: MTPDevice.root))  // for the sidebar's phone folders
                if location.isPhone { navigate(to: .phone(storage: storage, path: []), record: false, force: true) }
            }
        } catch {
            connection = .failed(error.localizedDescription)
            log.error("Connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Zoom (Command-plus / Command-minus, as in Finder)

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

    // MARK: Thumbnails

    func loadThumbnail(for item: FileItem) {
        guard item.wantsThumbnail, thumbnails[item.id] == nil, !pendingThumbs.contains(item.id) else { return }
        pendingThumbs.insert(item.id)
        switch item.source {
        case .mac(let url):
            Task {
                let image = await MacThumbnails.make(for: url)
                pendingThumbs.remove(item.id)
                if let image { thumbnails[item.id] = image }
            }
        case .phone(let phoneItem):
            let generation = service.generation
            let service = self.service
            Task {
                let data = try? await service.run { dev -> Data? in
                    // Skip requests queued for a folder the user has already left.
                    guard service.generation == generation else { return nil }
                    return dev.thumbnail(phoneItem.id)
                }
                pendingThumbs.remove(item.id)
                if let data = data ?? nil, let image = NSImage(data: data) { thumbnails[item.id] = image }
            }
        }
    }

    // MARK: Preview

    /// A local file to preview, if there is one yet. Mac files are always ready.
    func previewURL(for item: FileItem) -> URL? {
        item.macURL ?? previews[item.id]?.url
    }

    func dimensions(of item: FileItem) -> CGSize? {
        guard item.isImage, let url = previewURL(for: item) else { return nil }
        if let cached = dimensionCache[item.id] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let size = CGSize(width: width, height: height)
        dimensionCache[item.id] = size
        return size
    }

    /// Starts fetching a phone file for the preview pane, gallery and column preview.
    /// Small files load automatically; `force` loads large ones too.
    func requestPreview(_ item: FileItem, force: Bool) {
        guard let phoneItem = item.phoneItem, !item.isFolder else { return }
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
                load.state = .ready(try await cachedCopy(of: phoneItem, token: token) { load.fraction = $0 })
            } catch {
                load.state = token.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func quickLook(_ item: FileItem) {
        guard !item.isFolder else { return open(item) }
        if let url = item.macURL { quickLookURL = url; return }
        Task {
            do { quickLookURL = try await ensureLocalCopy(of: item) } catch {
                alertMessage = "Could not preview \(item.name): \(error.localizedDescription)"
            }
        }
    }

    func quickLookSelection() {
        if quickLookURL != nil { quickLookURL = nil; return }  // Space toggles, as in Finder
        if let item = selectedItems.first { quickLook(item) }
    }

    /// A local copy of a phone file for Quick Look or opening in a Mac app. Large ones show in Transfers.
    func ensureLocalCopy(of item: FileItem) async throws -> URL {
        if let url = item.macURL { return url }
        guard let phoneItem = item.phoneItem else { throw CancellationError() }
        if let url = previews[item.id]?.url, FileManager.default.fileExists(atPath: url.path) { return url }
        let transfer = item.size > Self.autoPreviewLimit ? startTransfer("Opening \(item.name)") : nil
        let token = transfer?.token ?? CancelToken()
        do {
            let url = try await cachedCopy(of: phoneItem, token: token) { transfer?.fraction = $0 }
            if let transfer { finish(transfer, .done) }
            let load = previews[item.id] ?? PreviewLoad(item: item)
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
        let url = Self.previewDirectory.appendingPathComponent("\(item.storage)-\(item.id)-\(item.name)")
        if MacFiles.size(url) == item.size, FileManager.default.fileExists(atPath: url.path) { return url }
        try await fetch(item, to: url, token: token, doneBytes: 0, totalBytes: max(item.size, 1), progress: progress)
        return url
    }

    // MARK: Copy and move — one engine for every direction

    /// Same Mac, or same phone storage: dragging there moves, as in Finder.
    func sameDevice(_ items: [FileItem], _ destination: Location) -> Bool {
        switch destination {
        case .mac: return items.allSatisfy { !$0.isPhone }
        case .phone(let storage, _): return items.allSatisfy { $0.phoneItem?.storage == storage }
        }
    }

    private func parentKey(of item: FileItem) -> FolderKey {
        switch item.source {
        case .mac(let url): return .mac(url.deletingLastPathComponent().standardizedFileURL.path)
        case .phone(let p): return .phone(storage: p.storage, folder: p.parent == 0 ? MTPDevice.root : p.parent)
        }
    }

    /// True when `destination` is `item` itself or inside it (a folder can't go into itself).
    private func isInside(_ destination: Location, _ item: FileItem) -> Bool {
        switch (destination, item.source) {
        case (.mac(let dir), .mac(let url)):
            let d = dir.standardizedFileURL.path, s = url.standardizedFileURL.path
            return d == s || d.hasPrefix(s + "/")
        case (.phone(_, let path), .phone(let p)):
            return path.contains { $0.id == p.id }
        default:
            return false
        }
    }

    /// Copies or moves items into a folder, on either side. Between the Mac and the phone it
    /// always copies (like an external drive); within one device `move` moves.
    func transfer(_ items: [FileItem], to destination: Location, move requestedMove: Bool) {
        let items = items.filter { !isInside(destination, $0) }
        guard !items.isEmpty else { return }
        let move = requestedMove && sameDevice(items, destination)
        if move && items.allSatisfy({ parentKey(of: $0) == destination.key }) { return }  // already there
        if destination.isPhone && connection != .connected {
            alertMessage = "The phone isn’t connected."
            return
        }
        let label = items.count == 1 ? items[0].displayName : "\(items.count) items"
        let transfer = startTransfer("\(move ? "Moving" : "Copying") \(label) to \(title(of: destination))")
        Task {
            do {
                try await perform(items, to: destination, move: move, transfer: transfer)
                finish(transfer, .done)
            } catch {
                finish(transfer, transfer.token.isCancelled ? .cancelled : .failed(error.localizedDescription))
            }
            await reloadIfCached(destination.key)
            if move { for key in Set(items.map(parentKey)) { await reloadIfCached(key) } }
            await refreshFreeSpace()
        }
    }

    private func perform(_ items: [FileItem], to destination: Location, move: Bool, transfer: Transfer) async throws {
        let macURLs = items.compactMap(\.macURL)
        let phoneItems = items.compactMap(\.phoneItem)
        switch destination {
        case .mac(let dir):
            if !macURLs.isEmpty { try await macToMac(macURLs, into: dir, move: move, transfer: transfer) }
            if !phoneItems.isEmpty { _ = try await download(phoneItems, into: dir, transfer: transfer) }
        case .phone(let storage, let path):
            let parent = path.last?.id ?? MTPDevice.root
            if !macURLs.isEmpty { try await upload(macURLs, storage: storage, parent: parent, transfer: transfer) }
            if !phoneItems.isEmpty {
                if move {
                    for (index, item) in phoneItems.enumerated() {
                        if transfer.token.isCancelled { throw CancellationError() }
                        transfer.detail = "\(index + 1) of \(phoneItems.count) · \(item.name)"
                        try await service.run { try $0.move(item.id, storage: storage, parent: parent) }
                        transfer.fraction = Double(index + 1) / Double(phoneItems.count)
                    }
                } else {
                    // Phone-to-phone copies go through a temporary folder on the Mac.
                    let staging = FileManager.default.temporaryDirectory
                        .appendingPathComponent("PhoneFilesCopy-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let local = try await download(phoneItems, into: staging, transfer: transfer)
                    try await upload(local, storage: storage, parent: parent, transfer: transfer)
                }
            }
        }
    }

    private func macToMac(_ urls: [URL], into dir: URL, move: Bool, transfer: Transfer) async throws {
        for (index, url) in urls.enumerated() {
            if transfer.token.isCancelled { throw CancellationError() }
            transfer.detail = "\(index + 1) of \(urls.count) · \(url.lastPathComponent)"
            let target = MacFiles.uniqueURL(in: dir, name: url.lastPathComponent)
            try await Task.detached(priority: .userInitiated) {
                if move {
                    try FileManager.default.moveItem(at: url, to: target)
                } else {
                    try FileManager.default.copyItem(at: url, to: target)
                }
            }.value
            transfer.fraction = Double(index + 1) / Double(urls.count)
        }
        transfer.detail = "\(urls.count) item\(urls.count == 1 ? "" : "s")"
    }

    /// Copies phone items (folders recursively) into a Mac folder; returns the top-level copies.
    private func download(_ selection: [PhoneItem], into directory: URL, transfer: Transfer) async throws -> [URL] {
        transfer.detail = "Listing files…"
        var jobs: [(PhoneItem, URL)] = []
        var topLevel: [URL] = []
        for item in selection {
            let target = MacFiles.uniqueURL(in: directory, name: item.name)
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

    /// Copies Mac files and folders onto the phone.
    private func upload(_ urls: [URL], storage: UInt32, parent: UInt32, transfer: Transfer) async throws {
        var jobs: [(URL, UInt32)] = []
        for url in urls { try await plan(url, storage: storage, parent: parent, jobs: &jobs) }
        let sizes = jobs.map { MacFiles.size($0.0) }
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
            for child in children { try await plan(child, storage: storage, parent: folder, jobs: &jobs) }
        } else {
            jobs.append((url, parent))
        }
    }

    private func refreshFreeSpace() async {
        if connection == .connected, let fresh = try? await service.run({ try $0.storages() }) { storages = fresh }
        if let url = location.macURL { availableSpace = MacFiles.availableSpace(at: url) } else { availableSpace = currentStorage?.free }
    }

    // MARK: Download shortcuts (toolbar and menus)

    static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    func copySelection(toChosenFolder: Bool) { copy(selectedItems, toChosenFolder: toChosenFolder) }

    func copy(_ items: [FileItem], toChosenFolder: Bool) {
        guard !items.isEmpty else { return }
        var destination = Self.downloadsFolder
        if toChosenFolder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Copy Here"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        transfer(items, to: .mac(destination), move: false)
    }

    /// Upload button: pick Mac files and copy them into the current phone folder.
    func pickFilesToCopyHere() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy Here"
        if panel.runModal() == .OK { transfer(panel.urls.map(MacFiles.item), to: location, move: false) }
    }

    // MARK: Clipboard — Command-C / Command-V / Option-Command-V, like Finder

    func copySelectionToClipboard() { copyToClipboard(selectedItems) }

    func copyToClipboard(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        clipboard = items
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = items.compactMap(\.macURL)
        if urls.isEmpty {
            pasteboard.setString(items.map(\.name).joined(separator: "\n"), forType: .string)
        } else {
            pasteboard.writeObjects(urls as [NSURL])  // so Finder can paste Mac files too
        }
        clipboardChangeCount = pasteboard.changeCount
    }

    var canPaste: Bool {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == clipboardChangeCount { return !clipboard.isEmpty }
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func paste(move: Bool) {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == clipboardChangeCount, !clipboard.isEmpty {
            transfer(clipboard, to: location, move: move)
            if move { clipboard = [] }
            return
        }
        // Files copied in Finder.
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        transfer(urls.map(MacFiles.item), to: location, move: move)
    }

    // MARK: Drag and drop

    /// Dragging an item: within the app it carries the item's ID; to Finder it carries the file
    /// (Mac files directly, phone files copied off the phone on drop).
    func dragProvider(for item: FileItem) -> NSItemProvider {
        dragRegistry[item.id] = item
        dragSourceIsPhone = item.isPhone
        let provider: NSItemProvider
        switch item.source {
        case .mac(let url):
            provider = NSItemProvider(object: url as NSURL)
        case .phone:
            provider = NSItemProvider()
            let type = item.utType ?? .data
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
                Task { @MainActor in
                    do { completion(try await self.exportForDrag(item), false, nil) } catch { completion(nil, false, error) }
                }
                return nil
            }
        }
        provider.suggestedName = item.name
        let id = item.id
        provider.registerDataRepresentation(forTypeIdentifier: UTType.phoneFilesItem.identifier, visibility: .ownProcess) { completion in
            completion(id.data(using: .utf8), nil)
            return nil
        }
        return provider
    }

    private func exportForDrag(_ item: FileItem) async throws -> URL {
        guard let phoneItem = item.phoneItem else { throw CancellationError() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneFilesDrag", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transfer = startTransfer("Copying \(item.name) to Finder")
        do {
            let urls = try await download([phoneItem], into: dir, transfer: transfer)
            finish(transfer, .done)
            return urls[0]
        } catch {
            finish(transfer, transfer.token.isCancelled ? .cancelled : .failed(error.localizedDescription))
            throw error
        }
    }

    /// Move when dragging within one device, copy across devices or with Option held.
    func dropOperation(to destination: Location, isInternal: Bool) -> NSDragOperation {
        guard isInternal, let fromPhone = dragSourceIsPhone, !NSEvent.modifierFlags.contains(.option) else { return .copy }
        return fromPhone == destination.isPhone ? .move : .copy
    }

    /// Records items being dragged by a native AppKit view (the column browser).
    func noteDrag(_ items: [FileItem]) {
        for item in items { dragRegistry[item.id] = item }
        dragSourceIsPhone = items.first?.isPhone
    }

    /// Drops onto the native column browser arrive as a pasteboard rather than item providers.
    func handlePasteboardDrop(_ pasteboard: NSPasteboard, to destination: Location, forceCopy: Bool) -> Bool {
        let type = NSPasteboard.PasteboardType(UTType.phoneFilesItem.identifier)
        if let ids = pasteboard.string(forType: type) {
            let items = ids.split(separator: "\n").compactMap { dragRegistry[String($0)] }
            transfer(items, to: destination, move: !forceCopy)
            return !items.isEmpty
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        transfer(urls.map(MacFiles.item), to: destination, move: false)  // from Finder: always copy
        return true
    }

    func handleDrop(_ providers: [NSItemProvider], to destination: Location) -> Bool {
        let wantCopy = NSEvent.modifierFlags.contains(.option)
        let internalProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.phoneFilesItem.identifier) }
        if !internalProviders.isEmpty {
            let group = DispatchGroup()
            let lock = NSLock()
            var ids: [String] = []
            for provider in internalProviders {
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.phoneFilesItem.identifier) { data, _ in
                    if let data, let id = String(data: data, encoding: .utf8) { lock.withLock { ids.append(id) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                MainActor.assumeIsolated {
                    let items = ids.compactMap { self.dragRegistry[$0] }
                    self.transfer(items, to: destination, move: !wantCopy)
                }
            }
            return true
        }
        // Files dragged in from Finder or another app are copied, never moved.
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.withLock { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated { self.transfer(urls.map(MacFiles.item), to: destination, move: false) }
        }
        return true
    }

    // MARK: New folder, rename, delete

    func makeFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let here = location
        Task {
            do {
                let newID: String
                switch here {
                case .mac(let dir):
                    let url = MacFiles.uniqueURL(in: dir, name: trimmed)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    newID = "mac:" + url.standardizedFileURL.path
                case .phone(let storage, let path):
                    let id = try await service.run { try $0.makeFolder(trimmed, storage: storage, parent: path.last?.id ?? MTPDevice.root) }
                    newID = "phone:\(storage):\(id)"
                }
                await load(here.key)
                if location == here { selection = [newID] }
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func beginRename() {
        if selectedItems.count == 1 { renameTarget = selectedItems[0] }
    }

    func rename(_ item: FileItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != item.name else { return }
        Task {
            do {
                var newID = item.id
                switch item.source {
                case .mac(let url):
                    let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
                    guard !FileManager.default.fileExists(atPath: target.path) else {
                        alertMessage = "The name “\(trimmed)” is already taken. Please choose a different name."
                        return
                    }
                    try FileManager.default.moveItem(at: url, to: target)
                    newID = "mac:" + target.standardizedFileURL.path
                case .phone(let phoneItem):
                    try await service.run { try $0.rename(phoneItem.id, to: trimmed) }
                    previews[item.id] = nil  // the cached copy carries the old name
                }
                await load(parentKey(of: item))
                selection = [newID]
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    /// Command-Delete: Mac items go to the Trash like in Finder; phone items have no Trash,
    /// so they are deleted permanently after a confirmation.
    func beginDelete() { beginDelete(selectedItems) }

    func beginDelete(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        if items.contains(where: \.isPhone) {
            pendingDelete = items
        } else {
            moveToTrash(items)
        }
    }

    private func moveToTrash(_ items: [FileItem]) {
        let urls = items.compactMap(\.macURL)
        selection.subtract(items.map(\.id))
        let here = location.key
        NSWorkspace.shared.recycle(urls) { _, error in
            Task { @MainActor in
                if let error { self.alertMessage = error.localizedDescription }
                await self.load(here)
            }
        }
    }

    func confirmDelete() {
        let items = pendingDelete
        pendingDelete = []
        selection.subtract(items.map(\.id))
        Task {
            for item in items {
                guard let phoneItem = item.phoneItem else { continue }
                do {
                    try await service.run { try $0.delete(phoneItem.id) }
                } catch {
                    alertMessage = "Could not delete \(item.name): \(error.localizedDescription)"
                    break
                }
            }
            await load(location.key)
            await refreshFreeSpace()
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

    static func format(bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
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
