import AppKit
import QuickLook
import SwiftUI

// Views take the model explicitly rather than through @EnvironmentObject: macOS rebuilds
// Table and List cells outside the environment, which crashed the app on folder changes.

struct ContentView: View {
    @ObservedObject var model: PhoneModel
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
            Text("This removes them from the phone permanently. Folders are deleted with everything inside.")
        }
        .onChange(of: model.renameTarget) { renameText = model.renameTarget?.name ?? "" }
        .onChange(of: model.askNewFolder) { if model.askNewFolder { newFolderName = "untitled folder" } }
        .task { await model.connect() }
    }

    private var deleteTitle: String {
        model.pendingDelete.count == 1
            ? "Delete “\(model.pendingDelete[0].name)”?"
            : "Delete \(model.pendingDelete.count) items?"
    }

    private func isPresent<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.storageID },
                set: { if let id = $0 { model.selectStorage(id) } })
            ) {
                Section("Device") { DeviceCard(model: model) }

                if !model.favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(model.favorites) { folder in
                            Button { model.navigate(to: [folder]) } label: {
                                Label(folder.name, systemImage: Self.symbol(for: folder.name))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .fontWeight(model.path.first?.id == folder.id ? .semibold : .regular)
                        }
                    }
                }

                if !model.storages.isEmpty {
                    Section("Storage") {
                        ForEach(model.storages) { storage in
                            StorageRow(storage: storage).tag(storage.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if !model.transfers.isEmpty {
                Divider()
                TransfersPanel(model: model)
            }
        }
    }

    static func symbol(for folder: String) -> String {
        switch folder {
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

struct DeviceCard: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "smartphone")
                    .font(.title2)
                    .foregroundStyle(model.connection == .connected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if model.connection == .connecting {
                ProgressView().controlSize(.small)
            } else {
                Button(model.connection == .connected ? "Reconnect" : "Connect") {
                    Task { await model.connect() }
                }
                .controlSize(.small)
                .disabled(model.hasActiveTransfer)
            }
        }
        .padding(.vertical, 4)
        .selectionDisabled()
    }

    private var title: String {
        switch model.connection {
        case .connected: return model.info.map { $0.name.isEmpty ? $0.model : $0.name } ?? "Phone"
        case .connecting: return "Connecting…"
        case .failed: return "Not connected"
        }
    }

    private var subtitle: String {
        switch model.connection {
        case .connected:
            var parts = [model.info?.model ?? ""]
            if let b = model.battery { parts.append("Battery \(b)%") }
            return parts.filter { !$0.isEmpty }.joined(separator: " · ")
        case .connecting: return "Looking for the phone over USB"
        case .failed: return "Plug in, unlock, choose File transfer"
        }
    }
}

struct StorageRow: View {
    let storage: PhoneStorage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(storage.name, systemImage: "internaldrive")
            ProgressView(value: used).controlSize(.small)
            Text("\(PhoneModel.format(bytes: storage.free)) free of \(PhoneModel.format(bytes: storage.capacity))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var used: Double {
        storage.capacity == 0 ? 0 : Double(storage.capacity - min(storage.free, storage.capacity)) / Double(storage.capacity)
    }
}

struct TransfersPanel: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.transfers.contains(where: { $0.state != .running }) {
                    Button("Clear") { model.clearFinishedTransfers() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.transfers) { TransferRow(transfer: $0) }
                }
            }
            .frame(maxHeight: 180)
        }
        .padding(12)
    }
}

struct TransferRow: View {
    @ObservedObject var transfer: Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(transfer.title).font(.caption).lineLimit(1).truncationMode(.middle)
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
