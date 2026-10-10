import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

extension UTType {
    /// Private drag type carrying item IDs between the app's own views.
    static let phoneFilesItem = UTType(exportedAs: "local.phonefiles.item")
}

/// A folder the browser can show: somewhere on the Mac, or somewhere on the phone.
enum Location: Hashable {
    case mac(URL)
    case phone(storage: UInt32, path: [PhoneItem])  // empty path = the storage's top level

    var key: FolderKey {
        switch self {
        case .mac(let url): return .mac(url.standardizedFileURL.path)
        case .phone(let storage, let path): return .phone(storage: storage, folder: path.last?.id ?? MTPDevice.root)
        }
    }

    var isPhone: Bool { if case .phone = self { return true } else { return false } }
    var macURL: URL? { if case .mac(let url) = self { return url } else { return nil } }
}

/// Cache key for a folder's listing.
enum FolderKey: Hashable {
    case mac(String)
    case phone(storage: UInt32, folder: UInt32)
}

/// One file or folder, from either side.
struct FileItem: Identifiable, Hashable {
    enum Source: Hashable {
        case mac(URL)
        case phone(PhoneItem)
    }

    let id: String
    let source: Source
    let name: String         // the real name, used for copying and renaming
    let displayName: String  // what Finder would show (e.g. "Safari" for Safari.app)
    let size: UInt64
    let modified: Date
    let isFolder: Bool
    let isHidden: Bool

    init(mac url: URL, values: URLResourceValues?) {
        let url = url.standardizedFileURL
        let isPackage = values?.isPackage ?? false
        id = "mac:" + url.path
        source = .mac(url)
        name = url.lastPathComponent
        displayName = values?.localizedName ?? url.lastPathComponent
        size = UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        modified = values?.contentModificationDate ?? .distantPast
        isFolder = (values?.isDirectory ?? false) && !isPackage
        isHidden = values?.isHidden ?? url.lastPathComponent.hasPrefix(".")
    }

    init(phone item: PhoneItem) {
        id = "phone:\(item.storage):\(item.id)"
        source = .phone(item)
        name = item.name
        displayName = item.name
        size = item.size
        modified = item.modified
        isFolder = item.isFolder
        isHidden = item.name.hasPrefix(".")
    }

    var macURL: URL? { if case .mac(let url) = source { return url } else { return nil } }
    var phoneItem: PhoneItem? { if case .phone(let item) = source { return item } else { return nil } }
    var isPhone: Bool { phoneItem != nil }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    var utType: UTType? {
        if isFolder { return .folder }
        if let url = macURL, let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType { return type }
        return UTType(filenameExtension: fileExtension)
    }
    /// Finder-style kind, e.g. "JPEG image".
    var kind: String { isFolder ? "Folder" : (utType?.localizedDescription ?? "Document") }
    var isImage: Bool { utType?.conforms(to: .image) ?? false }
    /// Worth asking for a picture thumbnail rather than the generic icon.
    var wantsThumbnail: Bool {
        guard !isFolder, let type = utType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .audiovisualContent) || type.conforms(to: .pdf)
    }
}

/// Reading and changing the Mac's own files.
enum MacFiles {
    static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
        .contentModificationDateKey, .isHiddenKey, .localizedNameKey,
    ]

    static func list(_ folder: URL) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
        return urls.map(item)
    }

    static func item(_ url: URL) -> FileItem {
        FileItem(mac: url, values: try? url.resourceValues(forKeys: keys))
    }

    static func availableSpace(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
    }

    static func volumeName(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? url.lastPathComponent
    }

    /// "photo.jpg" -> "photo 2.jpg" when the name is taken, the way Finder names copies.
    static func uniqueURL(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
    }

    /// Total bytes under a file or folder, for progress.
    static func treeSize(_ url: URL) -> UInt64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else { return size(url) }
        var total: UInt64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let child = walker?.nextObject() as? URL {
            total += UInt64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Finder's own icons: the real app and document icons for Mac files, and the matching
/// type icon (folder, JPEG, movie, …) for phone files.
@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let key: String
        if let url = item.macURL {
            key = item.isFolder || url.pathExtension.isEmpty ? "path:" + url.path : "path:" + url.path
        } else {
            key = "type:" + (item.utType?.identifier ?? "public.data")
        }
        if let cached = cache[key] { return cached }
        let image: NSImage
        if let url = item.macURL {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: item.utType ?? .data)
        }
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = image
        return image
    }

    static func icon(forPath path: String) -> NSImage {
        let key = "path:" + path
        if let cached = cache[key] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[key] = image
        return image
    }

    static let phone: NSImage = NSImage(systemSymbolName: "smartphone", accessibilityDescription: "Phone") ?? NSImage()
}

/// Quick Look thumbnails for Mac files (photos, videos, PDFs), like Finder's.
enum MacThumbnails {
    static func make(for url: URL, size: CGFloat = 256) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

/// Reloads a Mac folder when its contents change on disk, so the view stays current like Finder.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?

    func watch(_ url: URL?, onChange: @escaping () -> Void) {
        source?.cancel()
        source = nil
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler(handler: onChange)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}
