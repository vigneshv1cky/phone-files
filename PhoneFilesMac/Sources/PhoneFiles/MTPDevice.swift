import CMTP
import Foundation

struct PhoneInfo: Equatable {
    var model: String
    var name: String
    var serial: String
}

struct PhoneStorage: Identifiable, Hashable {
    let id: UInt32
    let name: String
    let capacity: UInt64
    let free: UInt64
}

struct PhoneItem: Identifiable, Hashable {
    let id: UInt32
    let parent: UInt32
    let storage: UInt32
    let name: String
    let size: UInt64
    let modified: Date
    let isFolder: Bool
}

struct MTPError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thread-safe cancel flag shared between the UI and a transfer running on the MTP queue.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Carries a Swift progress closure through libmtp's C callback.
private final class ProgressBox {
    let report: (UInt64, UInt64) -> Bool
    init(_ report: @escaping (UInt64, UInt64) -> Bool) { self.report = report }
}

private let progressTrampoline: LIBMTP_progressfunc_t = { sent, total, data in
    guard let data else { return 0 }
    let box = Unmanaged<ProgressBox>.fromOpaque(data).takeUnretainedValue()
    return box.report(sent, total) ? 0 : 1  // non-zero tells libmtp to abort
}

/// Thin wrapper over libmtp. Not thread-safe: only touch it from PhoneService's serial queue,
/// because an MTP session handles strictly one request at a time.
final class MTPDevice {
    static let root: UInt32 = 0xFFFF_FFFF

    private static let initialize: Void = { LIBMTP_Init() }()
    private var dev: UnsafeMutablePointer<LIBMTP_mtpdevice_t>?

    init() { _ = MTPDevice.initialize }

    var isConnected: Bool { dev != nil }

    // MARK: Connection

    func connect() throws -> PhoneInfo {
        disconnect(wait: false)
        for _ in 0..<4 {
            Self.freeUSBFromMacOS()
            Thread.sleep(forTimeInterval: 0.2)
            if let opened = Self.openFirstUncached() {
                dev = opened
                return PhoneInfo(
                    model: Self.take(LIBMTP_Get_Modelname(opened)) ?? "Phone",
                    name: Self.take(LIBMTP_Get_Friendlyname(opened)) ?? "",
                    serial: Self.take(LIBMTP_Get_Serialnumber(opened)) ?? "")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw MTPError(message: "No phone found, or it could not be opened. Plug it in, unlock it, and set USB to “File transfer”.")
    }

    func disconnect(wait: Bool = true) {
        guard let old = dev else { return }
        dev = nil
        if wait {
            LIBMTP_Release_Device(old)
        } else {
            // After the phone re-enumerates (USB mode switched, cable replugged) the old handle
            // is dead and closing it can block on USB timeouts, so do it off the MTP queue.
            let address = UInt(bitPattern: old)
            Thread.detachNewThread {
                LIBMTP_Release_Device(UnsafeMutablePointer(bitPattern: address))
            }
        }
    }

    /// macOS's photo-import daemon claims MTP phones as soon as they appear. Kill it right
    /// before opening; launchd restarts it on demand, but by then libmtp holds the interface.
    private static func freeUSBFromMacOS() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-9", "-x", "ptpcamerad"]
        try? p.run()
        p.waitUntilExit()
    }

    /// Opens without libmtp's up-front walk of every object, which takes minutes on a
    /// phone full of photos. Folders are listed on demand instead.
    private static func openFirstUncached() -> UnsafeMutablePointer<LIBMTP_mtpdevice_t>? {
        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        guard LIBMTP_Detect_Raw_Devices(&raw, &count) == LIBMTP_ERROR_NONE, count > 0, let raw else { return nil }
        defer { free(raw) }
        return LIBMTP_Open_Raw_Device_Uncached(raw)
    }

    // MARK: Queries

    func battery() -> Int? {
        guard let dev else { return nil }
        var maximum: UInt8 = 0, current: UInt8 = 0
        guard LIBMTP_Get_Batterylevel(dev, &maximum, &current) == 0, maximum > 0 else {
            LIBMTP_Clear_Errorstack(dev)
            return nil
        }
        return Int((Double(current) / Double(maximum) * 100).rounded())
    }

    func storages() throws -> [PhoneStorage] {
        let dev = try require()
        guard LIBMTP_Get_Storage(dev, 0) == 0 else { throw errors("Could not read storage.") }
        var out: [PhoneStorage] = []
        var node = dev.pointee.storage
        while let s = node {
            out.append(PhoneStorage(
                id: s.pointee.id,
                name: s.pointee.StorageDescription.map { String(cString: $0) } ?? "Storage",
                capacity: s.pointee.MaxCapacity,
                free: s.pointee.FreeSpaceInBytes))
            node = s.pointee.next
        }
        if out.isEmpty {
            throw MTPError(message: "The phone is hiding its storage. Unlock the phone, then press Reconnect.")
        }
        return out
    }

    func list(storage: UInt32, parent: UInt32) throws -> [PhoneItem] {
        let dev = try require()
        var out: [PhoneItem] = []
        var node = LIBMTP_Get_Files_And_Folders(dev, storage, parent)
        while let f = node {
            out.append(Self.item(f.pointee))
            node = f.pointee.next  // read the link before freeing this entry
            LIBMTP_destroy_file_t(f)
        }
        if out.isEmpty { LIBMTP_Clear_Errorstack(dev) }  // empty folders also report via the stack
        return out
    }

    func thumbnail(_ id: UInt32) -> Data? {
        guard let dev else { return nil }
        var data: UnsafeMutablePointer<UInt8>?
        var size: UInt32 = 0
        guard LIBMTP_Get_Thumbnail(dev, id, &data, &size) == 0, let data, size > 0 else {
            LIBMTP_Clear_Errorstack(dev)
            return nil
        }
        defer { free(data) }
        return Data(bytes: data, count: Int(size))
    }

    // MARK: Transfers

    /// Copies a phone file to `destination`. `progress` returns false to cancel.
    func download(_ id: UInt32, to destination: URL, progress: @escaping (UInt64, UInt64) -> Bool) throws {
        let dev = try require()
        let box = ProgressBox(progress)
        let context = UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque())
        let result = withExtendedLifetime(box) {
            LIBMTP_Get_File_To_File(dev, id, destination.path, progressTrampoline, context)
        }
        if result != 0 {
            try? FileManager.default.removeItem(at: destination)
            throw errors("Download failed.")
        }
    }

    @discardableResult
    func upload(_ source: URL, name: String, storage: UInt32, parent: UInt32,
                progress: @escaping (UInt64, UInt64) -> Bool) throws -> UInt32 {
        let dev = try require()
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard let file = LIBMTP_new_file_t() else { throw MTPError(message: "Out of memory.") }
        defer { LIBMTP_destroy_file_t(file) }  // also frees the strdup'd filename
        file.pointee.filename = strdup(name)
        file.pointee.filesize = size
        file.pointee.filetype = LIBMTP_FILETYPE_UNKNOWN
        file.pointee.parent_id = parent == Self.root ? 0 : parent
        file.pointee.storage_id = storage
        let box = ProgressBox(progress)
        let context = UnsafeRawPointer(Unmanaged.passUnretained(box).toOpaque())
        let result = withExtendedLifetime(box) {
            LIBMTP_Send_File_From_File(dev, source.path, file, progressTrampoline, context)
        }
        guard result == 0 else { throw errors("Upload of \(name) failed.") }
        return file.pointee.item_id
    }

    func makeFolder(_ name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let dev = try require()
        guard let cName = strdup(name) else { throw MTPError(message: "Out of memory.") }
        defer { free(cName) }
        let id = LIBMTP_Create_Folder(dev, cName, parent == Self.root ? 0 : parent, storage)
        guard id != 0 else { throw errors("Could not create folder “\(name)”.") }
        return id
    }

    func delete(_ id: UInt32) throws {
        let dev = try require()
        guard LIBMTP_Delete_Object(dev, id) == 0 else { throw errors("Delete failed.") }
    }

    // MARK: Helpers

    private func require() throws -> UnsafeMutablePointer<LIBMTP_mtpdevice_t> {
        guard let dev else { throw MTPError(message: "Phone is not connected.") }
        return dev
    }

    private func errors(_ fallback: String) -> MTPError {
        guard let dev else { return MTPError(message: fallback) }
        var messages: [String] = []
        var node = LIBMTP_Get_Errorstack(dev)
        while let e = node {
            if let text = e.pointee.error_text { messages.append(String(cString: text)) }
            node = e.pointee.next
        }
        LIBMTP_Clear_Errorstack(dev)
        return MTPError(message: messages.isEmpty ? fallback : messages.joined(separator: "; "))
    }

    private static func item(_ f: LIBMTP_file_t) -> PhoneItem {
        PhoneItem(
            id: f.item_id,
            parent: f.parent_id,
            storage: f.storage_id,
            name: f.filename.map { String(cString: $0) } ?? "",
            size: f.filesize,
            modified: Date(timeIntervalSince1970: TimeInterval(f.modificationdate)),
            isFolder: f.filetype == LIBMTP_FILETYPE_FOLDER)
    }

    /// Copies a libmtp-allocated string and frees it.
    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { free(p) }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }
}

/// Runs every MTP call on one serial queue and exposes it as async/await.
final class PhoneService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "phonefiles.mtp", qos: .userInitiated)
    private let device = MTPDevice()
    private let lock = NSLock()
    private var generationValue = 0

    /// Bumped on every navigation so queued thumbnail requests for the old folder are skipped.
    var generation: Int { lock.withLock { generationValue } }
    func nextGeneration() -> Int { lock.withLock { generationValue += 1; return generationValue } }

    func run<T>(_ work: @escaping (MTPDevice) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work(self.device) }) }
        }
    }

    func shutdown() {
        queue.sync { device.disconnect(wait: true) }
    }
}
