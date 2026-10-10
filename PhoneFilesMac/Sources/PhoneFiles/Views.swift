import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: PhoneModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
        } detail: {
            Browser()
        }
        .quickLookPreview($model.previewURL)
        .alert("Something went wrong", isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .task { await model.connect() }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: PhoneModel

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.storageID },
                set: { if let id = $0 { model.selectStorage(id) } })
            ) {
                Section("Device") { DeviceCard(model: model) }
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
                TransfersPanel()
            }
        }
    }
}

/// A sidebar list row, so like the file rows it is handed the model rather than looking it up.
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
    @EnvironmentObject var model: PhoneModel

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

// MARK: - Browser

enum ViewMode: String { case list, grid }

struct Browser: View {
    @EnvironmentObject var model: PhoneModel
    @AppStorage("viewMode") private var mode: ViewMode = .list
    @State private var selection: Set<UInt32> = []
    @State private var sortOrder = [KeyPathComparator(\PhoneItem.name, comparator: .localizedStandard)]
    @State private var dropTargeted = false
    @State private var askFolderName = false
    @State private var newFolderName = ""
    @State private var pendingDelete: [PhoneItem] = []

    private var sortedItems: [PhoneItem] {
        let sorted = model.items.sorted(using: sortOrder)
        return sorted.filter(\.isFolder) + sorted.filter { !$0.isFolder }
    }

    private var selectedItems: [PhoneItem] { sortedItems.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            PathBar()
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { if dropTargeted { DropOverlay() } }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
            Divider()
            StatusBar(count: model.items.count, folders: model.items.filter(\.isFolder).count,
                      selected: selection.count, loading: model.isLoading)
        }
        .navigationTitle(model.path.last?.name ?? model.currentStorage?.name ?? "Phone Files")
        .toolbar { toolbar }
        .onChange(of: model.path) { selection = [] }
        .onChange(of: model.storageID) { selection = [] }
        .onKeyPress(.space) {
            guard let item = selectedItems.first(where: { !$0.isFolder }) else { return .ignored }
            model.preview(item)
            return .handled
        }
        .onKeyPress(.return) {
            guard selectedItems.count == 1 else { return .ignored }
            model.open(selectedItems[0])
            return .handled
        }
        .onDeleteCommand { if !selectedItems.isEmpty { pendingDelete = selectedItems } }
        .alert("New Folder", isPresented: $askFolderName) {
            TextField("Name", text: $newFolderName)
            Button("Create") { model.makeFolder(named: newFolderName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                model.delete(pendingDelete)
                selection.subtract(pendingDelete.map(\.id))
                pendingDelete = []
            }
        } message: {
            Text("This removes them from the phone permanently. Folders are deleted with everything inside.")
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete “\(pendingDelete[0].name)”?" : "Delete \(pendingDelete.count) items?"
    }

    @ViewBuilder
    private var content: some View {
        if model.connection == .connecting {
            ProgressView("Connecting to phone…")
        } else if case .failed(let message) = model.connection {
            ContentUnavailableView {
                Label("Phone not connected", systemImage: "cable.connector.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Connect") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
            }
        } else if let error = model.folderError {
            ContentUnavailableView {
                Label("Can’t read this folder", systemImage: "lock")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
                Button("Reconnect") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
            }
        } else if model.items.isEmpty && model.isLoading {
            ProgressView()
        } else if model.items.isEmpty {
            ContentUnavailableView("Empty Folder", systemImage: "folder",
                                   description: Text("Drop files here to copy them to the phone."))
        } else if mode == .list {
            listView
        } else {
            gridView
        }
    }

    private var listView: some View {
        Table(sortedItems, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 8) {
                    ItemIcon(item: item, thumbnail: model.thumbnails[item.id], size: 20) {
                        model.loadThumbnail(for: item)
                    }
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "—" : PhoneModel.format(bytes: item.size))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90, max: 120)
            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.modified.timeIntervalSince1970 > 0
                     ? item.modified.formatted(date: .abbreviated, time: .shortened) : "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170, max: 220)
        }
        .contextMenu(forSelectionType: UInt32.self) { ids in
            menu(for: sortedItems.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let item = sortedItems.first(where: { ids.contains($0.id) }) { model.open(item) }
        }
    }

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14)], spacing: 14) {
                ForEach(sortedItems) { item in
                    GridTile(item: item, thumbnail: model.thumbnails[item.id],
                             selected: selection.contains(item.id)) { model.loadThumbnail(for: item) }
                        .onTapGesture(count: 2) { model.open(item) }
                        .simultaneousGesture(TapGesture().onEnded {
                            if NSEvent.modifierFlags.contains(.command) {
                                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                            } else {
                                selection = [item.id]
                            }
                        })
                        .contextMenu {
                            menu(for: selection.contains(item.id) ? selectedItems : [item])
                        }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onTapGesture { selection = [] }
    }

    @ViewBuilder
    private func menu(for items: [PhoneItem]) -> some View {
        if items.count == 1 {
            Button(items[0].isFolder ? "Open" : "Quick Look") { model.open(items[0]) }
            Divider()
        }
        if !items.isEmpty {
            Button("Download to Downloads") { model.download(items, to: downloadsFolder) }
            Button("Download To…") { chooseFolder { model.download(items, to: $0) } }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = items }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.goUp() } label: { Label("Up", systemImage: "chevron.left") }
                .help("Enclosing folder")
                .disabled(model.path.isEmpty)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $mode) {
                Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                Label("Thumbnails", systemImage: "square.grid.2x2").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .help("Switch between list and thumbnails")

            Button { newFolderName = ""; askFolderName = true } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("New folder on the phone")
            .disabled(model.storageID == nil)

            Button { pickUploads() } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .help("Copy files from this Mac to the phone")
                .disabled(model.storageID == nil)

            Button { model.download(selectedItems, to: downloadsFolder) } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .help("Copy the selection to your Downloads folder")
            .disabled(selection.isEmpty)

            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh")
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    private func chooseFolder(_ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        if panel.runModal() == .OK, let url = panel.url { done(url) }
    }

    private func pickUploads() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Phone"
        if panel.runModal() == .OK { model.upload(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.storageID != nil else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.withLock { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.upload(urls) }
        return true
    }
}

struct PathBar: View {
    @EnvironmentObject var model: PhoneModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                crumb(model.currentStorage?.name ?? "Phone", systemImage: "internaldrive", depth: -1)
                ForEach(Array(model.path.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    crumb(folder.name, systemImage: "folder", depth: index)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func crumb(_ title: String, systemImage: String, depth: Int) -> some View {
        Button { model.goTo(depth: depth) } label: {
            Label(title, systemImage: systemImage).lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(depth == model.path.count - 1 ? .primary : .secondary)
    }
}

struct StatusBar: View {
    let count: Int
    let folders: Int
    let selected: Int
    let loading: Bool

    var body: some View {
        HStack(spacing: 8) {
            if loading { ProgressView().controlSize(.mini) }
            Text(summary).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
    }

    private var summary: String {
        var text = "\(count) item\(count == 1 ? "" : "s")"
        if folders > 0 { text += ", \(folders) folder\(folders == 1 ? "" : "s")" }
        if selected > 0 { text += " · \(selected) selected" }
        return text
    }
}

/// File or folder icon, or the phone's thumbnail once loaded. Deliberately takes everything as
/// plain values: table cells are rebuilt outside the environment when the folder changes, so a
/// cell that looks up shared state from its surroundings crashes the app.
struct ItemIcon: View {
    let item: PhoneItem
    let thumbnail: NSImage?
    let size: CGFloat
    let onAppear: () -> Void

    var body: some View {
        let kind = FileKind(item)
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: kind.symbol)
                    .resizable().scaledToFit()
                    .padding(size * 0.12)
                    .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
        .onAppear(perform: onAppear)
    }
}

struct GridTile: View {
    let item: PhoneItem
    let thumbnail: NSImage?
    let selected: Bool
    let onAppear: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ItemIcon(item: item, thumbnail: thumbnail, size: 96, onAppear: onAppear)
                .frame(width: 104, height: 104)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(selected ? Color.accentColor : Color.clear))
                .foregroundStyle(selected ? Color.white : .primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
            .overlay(Label("Drop to copy to the phone", systemImage: "square.and.arrow.down.on.square")
                .font(.title3))
            .padding(10)
            .allowsHitTesting(false)
    }
}
