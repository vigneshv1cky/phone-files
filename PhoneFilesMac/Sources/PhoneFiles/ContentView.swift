import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// Views take the model explicitly rather than through @EnvironmentObject: macOS rebuilds
// Table and List cells outside the environment, which crashed the app on folder changes.

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var renameText = ""
    @State private var newFolderName = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            BrowserView(model: model)
                .inspector(isPresented: $model.showPreviewPane) {
                    PreviewPane(model: model)
                        .inspectorColumnWidth(min: 220, ideal: 280, max: 360)
                }
        }
        .quickLookPreview($model.quickLookURL)
        .alert("Something went wrong", isPresented: isPresent($model.alertMessage)) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .alert("Rename", isPresented: isPresent($model.renameTarget)) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let item = model.renameTarget { model.rename(item, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for “\(model.renameTarget?.name ?? "")”.")
        }
        .alert("New Folder", isPresented: $model.askNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { model.makeFolder(named: newFolderName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { !model.pendingDelete.isEmpty }, set: { if !$0 { model.pendingDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { model.confirmDelete() }
        } message: {
            Text("Phones have no Trash, so this removes them permanently. Folders are deleted with everything inside.")
        }
        .onChange(of: model.renameTarget) { renameText = model.renameTarget?.name ?? "" }
        .onChange(of: model.askNewFolder) { if model.askNewFolder { newFolderName = "untitled folder" } }
        .task { await model.start() }
    }

    private var deleteTitle: String {
        model.pendingDelete.count == 1
            ? "Delete “\(model.pendingDelete[0].name)” from \(model.phoneName)?"
            : "Delete \(model.pendingDelete.count) items from \(model.phoneName)?"
    }

    private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List(selection: Binding(
                get: { model.sidebarSelection },
                set: { if let target = $0 { model.open(target) } })
            ) {
                Section("Favorites") {
                    ForEach(AppModel.macFavorites) { place in
                        Label(place.title, systemImage: place.symbol)
                            .tag(SidebarTarget.mac(place.url))
                            .onDrop(of: [.phoneFilesItem, .fileURL],
                                    delegate: FolderDrop(model: model, destination: .mac(place.url), targetID: "side:" + place.id))
                    }
                }
                Section("Locations") {
                    ForEach(AppModel.volumes) { place in
                        Label(place.title, systemImage: place.symbol)
                            .tag(SidebarTarget.mac(place.url))
                            .onDrop(of: [.phoneFilesItem, .fileURL],
                                    delegate: FolderDrop(model: model, destination: .mac(place.url), targetID: "side:" + place.id))
                    }
                    PhoneRow(model: model)
                }
                if model.connection == .connected, !model.phoneFavorites.isEmpty {
                    Section(model.phoneName) {
                        ForEach(model.phoneFavorites) { folder in
                            let destination = Location.phone(storage: folder.storage, path: [folder])
                            Label(folder.name, systemImage: Self.symbol(forPhoneFolder: folder.name))
                                .tag(SidebarTarget.phoneFolder(folder))
                                .onDrop(of: [.phoneFilesItem, .fileURL],
                                        delegate: FolderDrop(model: model, destination: destination, targetID: "side:phone:\(folder.id)"))
                        }
                    }
                }
                if !model.transfers.isEmpty {
                    Section {
                        ForEach(model.transfers) { TransferRow(transfer: $0).selectionDisabled() }
                    } header: {
                        HStack {
                            Text("Transfers")
                            Spacer()
                            if model.transfers.contains(where: { $0.state != .running }) {
                                Button("Clear") { model.clearFinishedTransfers() }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
        }
        .listStyle(.sidebar)
    }

    static func symbol(forPhoneFolder name: String) -> String {
        switch name {
        case "DCIM": return "camera"
        case "Pictures": return "photo.on.rectangle"
        case "Download": return "arrow.down.circle"
        case "Documents": return "doc"
        case "Movies": return "film"
        case "Music": return "music.note"
        case "Recordings": return "waveform"
        case "WhatsApp": return "message"
        default: return "folder"
        }
    }
}

/// The phone, listed under Locations like an external drive.
struct PhoneRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let storage = model.storages.first
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.phoneName).lineLimit(1)
                    Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } icon: {
                Image(systemName: "smartphone")
            }
            Spacer(minLength: 0)
            switch model.connection {
            case .connecting:
                ProgressView().controlSize(.mini)
            case .connected:
                Button { Task { await model.connectPhone() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reconnect").disabled(model.hasActiveTransfer)
            case .idle, .failed:
                Button("Connect") { Task { await model.connectPhone() } }
                    .buttonStyle(.borderless).controlSize(.small)
            }
        }
        .tag(storage.map { SidebarTarget.phone(storage: $0.id) } ?? SidebarTarget.phone(storage: 0))
        .selectionDisabled(storage == nil)
        .onDrop(of: [.phoneFilesItem, .fileURL], delegate: FolderDrop(
            model: model, destination: .phone(storage: storage?.id ?? 0, path: []), targetID: "side:phone",
            enabled: storage != nil))
        .contextMenu {
            Button("Reconnect Phone") { Task { await model.connectPhone() } }
        }
    }

    private var status: String {
        switch model.connection {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .failed: return "Plug in, unlock, File transfer"
        case .connected:
            if model.storages.isEmpty { return "Unlock the phone" }
            var parts: [String] = []
            if let free = model.storages.first?.free { parts.append("\(AppModel.format(bytes: free)) free") }
            if let battery = model.battery { parts.append("\(battery)%") }
            return parts.joined(separator: " · ")
        }
    }
}

struct TransferRow: View {
    @ObservedObject var transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(transfer.title).font(.caption).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 4)
                switch transfer.state {
                case .running:
                    Button { transfer.cancel() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .cancelled:
                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
            }
            if transfer.state == .running { ProgressView(value: transfer.fraction).controlSize(.small) }
            if !transfer.detail.isEmpty {
                Text(transfer.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
    }
}

/// Drop target for a folder, the open window, or a sidebar entry. Highlights while hovered and
/// shows a move or copy cursor the way Finder does.
struct FolderDrop: DropDelegate {
    let model: AppModel
    let destination: Location
    let targetID: String
    var enabled = true

    func validateDrop(info: DropInfo) -> Bool {
        enabled && info.hasItemsConforming(to: [.phoneFilesItem, .fileURL])
    }

    func dropEntered(info: DropInfo) { model.dropTargetID = targetID }

    func dropExited(info: DropInfo) {
        if model.dropTargetID == targetID { model.dropTargetID = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let isInternal = info.hasItemsConforming(to: [.phoneFilesItem])
        return DropProposal(operation: model.dropOperation(to: destination, isInternal: isInternal) == .move ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        model.dropTargetID = nil
        return model.handleDrop(info.itemProviders(for: [.phoneFilesItem, .fileURL]), to: destination)
    }
}
