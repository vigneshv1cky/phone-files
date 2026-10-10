import AppKit
import Foundation
import os

let log = Logger(subsystem: "local.phonefiles", category: "app")

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

@MainActor
final class PhoneModel: ObservableObject {
    enum Connection: Equatable { case connecting, connected, failed(String) }

    @Published var connection: Connection = .connecting
    @Published var info: PhoneInfo?
    @Published var battery: Int?
    @Published var storages: [PhoneStorage] = []
    @Published var storageID: UInt32?
    @Published var path: [PhoneItem] = []
    @Published var items: [PhoneItem] = []
    @Published var isLoading = false
    @Published var folderError: String?
    @Published var thumbnails: [UInt32: NSImage] = [:]
    @Published var transfers: [Transfer] = []
    @Published var previewURL: URL?
    @Published var alertMessage: String?

    let service = PhoneService()
    private var pendingThumbs: Set<UInt32> = []

    var currentStorage: PhoneStorage? { storages.first { $0.id == storageID } }
    var currentFolderID: UInt32 { path.last?.id ?? MTPDevice.root }
    var hasActiveTransfer: Bool { transfers.contains { $0.state == .running } }

    // MARK: Connection

    func connect() async {
        connection = .connecting
        storages = []; storageID = nil; path = []; items = []
        folderError = nil; thumbnails = [:]; pendingThumbs = []
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
            await load()
        } catch {
            items = []
            folderError = error.localizedDescription
            log.error("Storage failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Developer aid: PHONEFILES_AUTOTEST="Download,DCIM" opens each top-level folder in turn
    /// (going back up in between), so folder navigation can be exercised without clicking.
    private func runAutotestIfRequested() async {
        guard let spec = ProcessInfo.processInfo.environment["PHONEFILES_AUTOTEST"] else { return }
        for name in spec.split(separator: ",").map(String.init) {
            try? await Task.sleep(for: .seconds(1.5))
            guard let folder = items.first(where: { $0.isFolder && $0.name == name }) else {
                log.error("Autotest: no folder \(name, privacy: .public)")
                continue
            }
            path.append(folder)
            await load()
            try? await Task.sleep(for: .seconds(2))
            log.info("Autotest: still alive inside \(name, privacy: .public)")
            path.removeLast()
            await load()
        }
        log.info("Autotest: finished")
    }

    // MARK: Navigation

    func selectStorage(_ id: UInt32) {
        guard id != storageID else { return }
        storageID = id
        path = []
        Task { await load() }
    }

    func open(_ item: PhoneItem) {
        if item.isFolder {
            path.append(item)
            Task { await load() }
        } else {
            preview(item)
        }
    }

    func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        Task { await load() }
    }

    /// Jump to a breadcrumb; -1 means the storage root.
    func goTo(depth: Int) {
        path = Array(path.prefix(depth + 1))
        Task { await load() }
    }

    func refresh() async {
        if connection != .connected { return await connect() }
        battery = try? await service.run { $0.battery() }
        if storages.isEmpty { return await loadStorages() }
        if let fresh = try? await service.run({ try $0.storages() }) { storages = fresh }
        await load()
    }

    func load() async {
        guard let storage = storageID else { return }
        let folder = currentFolderID
        _ = service.nextGeneration()
        isLoading = true
        folderError = nil
        do {
            let list = try await service.run { try $0.list(storage: storage, parent: folder) }
            guard storage == storageID, folder == currentFolderID else { return }  // user moved on
            items = list
            log.info("Listed \(self.path.last?.name ?? "top level", privacy: .public): \(list.count) items")
        } catch {
            guard storage == storageID, folder == currentFolderID else { return }
            items = []
            folderError = error.localizedDescription
            log.error("List failed: \(error.localizedDescription, privacy: .public)")
        }
        isLoading = false
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

    func preview(_ item: PhoneItem) {
        guard !item.isFolder else { return open(item) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhoneFilesPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(item.id)-\(item.name)")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
           size.uint64Value == item.size {
            previewURL = url
            return
        }
        let transfer = startTransfer("Opening \(item.name)")
        Task {
            do {
                try await fetch(item, to: url, transfer: transfer, doneBytes: 0, totalBytes: max(item.size, 1))
                finish(transfer, .done)
                previewURL = url
            } catch {
                finish(transfer, transfer.token.isCancelled ? .cancelled : .failed(error.localizedDescription))
            }
        }
    }

    // MARK: Download

    func download(_ selection: [PhoneItem], to directory: URL, reveal: Bool = true) {
        guard !selection.isEmpty else { return }
        let label = selection.count == 1 ? selection[0].name : "\(selection.count) items"
        let transfer = startTransfer("Downloading \(label)")
        Task {
            do {
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
                    try await fetch(item, to: target, transfer: transfer, doneBytes: done, totalBytes: total)
                    done += item.size
                }
                transfer.detail = "\(jobs.count) file\(jobs.count == 1 ? "" : "s") · \(Self.format(bytes: done))"
                finish(transfer, .done)
                if reveal { NSWorkspace.shared.activateFileViewerSelecting(topLevel) }
            } catch {
                finish(transfer, transfer.token.isCancelled ? .cancelled : .failed(error.localizedDescription))
            }
        }
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

    private func fetch(_ item: PhoneItem, to url: URL, transfer: Transfer,
                       doneBytes: UInt64, totalBytes: UInt64) async throws {
        let throttle = Throttle()
        let token = transfer.token
        try await service.run { dev in
            try dev.download(item.id, to: url) { sent, _ in
                if throttle.shouldFire() {
                    let fraction = Double(doneBytes + sent) / Double(totalBytes)
                    Task { @MainActor in transfer.fraction = fraction }
                }
                return !token.isCancelled
            }
        }
        transfer.fraction = Double(doneBytes + item.size) / Double(totalBytes)
    }

    // MARK: Upload

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
            if storage == storageID, parent == currentFolderID { await load() }
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

    // MARK: Folder and delete

    func makeFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let storage = storageID, !trimmed.isEmpty, !trimmed.contains("/") else { return }
        let parent = currentFolderID
        Task {
            do {
                _ = try await service.run { try $0.makeFolder(trimmed, storage: storage, parent: parent) }
                await load()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func delete(_ selection: [PhoneItem]) {
        Task {
            for item in selection {
                do {
                    try await service.run { try $0.delete(item.id) }
                } catch {
                    alertMessage = "Could not delete \(item.name): \(error.localizedDescription)"
                    break
                }
            }
            await load()
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

/// What kind of file an item is, for icons and thumbnails.
struct FileKind {
    let symbol: String
    let hasThumbnail: Bool

    init(_ item: PhoneItem) {
        guard !item.isFolder else { symbol = "folder.fill"; hasThumbnail = false; return }
        switch (item.name as NSString).pathExtension.lowercased() {
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
