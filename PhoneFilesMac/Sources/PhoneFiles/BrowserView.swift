import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @ObservedObject var model: PhoneModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { if dropTargeted { DropOverlay() } }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    Self.loadFileURLs(providers) { model.upload($0) }
                    return model.storageID != nil
                }
            Divider()
            PathBar(model: model)
            Divider()
            StatusBar(model: model)
        }
        .navigationTitle(model.path.last?.name ?? model.currentStorage?.name ?? "Phone Files")
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search this folder")
        .toolbar { BrowserToolbar(model: model) }
        .onPasteCommand(of: [.fileURL]) { providers in
            Self.loadFileURLs(providers) { model.upload($0) }
        }
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
        } else if model.viewMode == .columns {
            ColumnBrowser(model: model)  // columns show their own loading and empty states
        } else if !model.hasListing {
            ProgressView()
        } else if model.visibleItems.isEmpty {
            if model.searchText.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder",
                                       description: Text("Drop files here to copy them to the phone."))
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        } else {
            switch model.viewMode {
            case .icons: IconBrowser(model: model)
            case .list: ListBrowser(model: model)
            case .gallery: GalleryBrowser(model: model)
            case .columns: EmptyView()
            }
        }
    }

    static func loadFileURLs(_ providers: [NSItemProvider], then handle: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.withLock { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) { if !urls.isEmpty { handle(urls) } }
    }
}

struct BrowserToolbar: ToolbarContent {
    @ObservedObject var model: PhoneModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .help("Back")
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .help("Forward")
                .disabled(!model.canGoForward)
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $model.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show items as icons, list, columns or gallery")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $model.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Picker("Order", selection: $model.ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Keep Folders on Top", isOn: $model.foldersOnTop)
                Toggle("Show Hidden Files", isOn: $model.showHidden)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Change the item sort order")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ItemMenu(model: model, items: model.selectedItems)
                Divider()
                Button("New Folder") { model.askNewFolder = true }
                Button("Upload to Phone…") { model.pickUploads() }
                Divider()
                Button("Reconnect Phone") { Task { await model.connect() } }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .help("Perform tasks with the selected items")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.pickUploads() } label: { Label("Upload", systemImage: "square.and.arrow.up") }
                .help("Copy files from this Mac to the phone")
                .disabled(model.storageID == nil)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.downloadSelection() } label: { Label("Download", systemImage: "square.and.arrow.down") }
                .help("Copy the selection to your Downloads folder")
                .disabled(model.selection.isEmpty)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showPreviewPane.toggle() } label: { Label("Preview", systemImage: "sidebar.right") }
                .help(model.showPreviewPane ? "Hide preview" : "Show preview")
        }
    }
}

/// The right-click menu, shared by every view and the toolbar's Actions menu.
struct ItemMenu: View {
    let model: PhoneModel
    let items: [PhoneItem]

    var body: some View {
        if items.count == 1 {
            Button("Open") { model.open(items[0]) }
            if !items[0].isFolder { Button("Quick Look") { model.quickLook(items[0]) } }
            Button("Get Info") { model.selection = [items[0].id]; model.showPreviewPane = true }
            Button("Rename…") { model.renameTarget = items[0] }
            Divider()
        }
        if !items.isEmpty {
            Button("Download to Downloads") { model.download(items, to: PhoneModel.downloadsFolder) }
            Button("Download To…") {
                model.selection = Set(items.map(\.id))
                model.downloadSelectionTo()
            }
            Divider()
            Button("Delete…", role: .destructive) { model.pendingDelete = items }
        }
    }
}

struct PathBar: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                crumb(model.currentStorage?.name ?? "Phone", systemImage: "internaldrive", depth: -1)
                ForEach(Array(model.path.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    crumb(folder.name, systemImage: "folder.fill", depth: index)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
        .font(.caption)
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
    @ObservedObject var model: PhoneModel

    // The bar must never demand width: when the window is narrow and the preview pane is open,
    // a bar wider than the space left made the split view re-solve its layout forever (crash).
    // So the size control drops out when it doesn't fit and the summary truncates.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(withSizeControl: model.viewMode == .icons)
            bar(withSizeControl: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func bar(withSizeControl: Bool) -> some View {
        HStack(spacing: 8) {
            if model.isLoadingCurrent { ProgressView().controlSize(.mini) }
            Spacer(minLength: 0)
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            Spacer(minLength: 0)
            if withSizeControl { IconSizeControl(size: $model.iconSize) }
        }
    }

    private var summary: String {
        let count = model.visibleItems.count
        var text = "\(count) item\(count == 1 ? "" : "s")"
        if !model.selection.isEmpty { text = "\(model.selection.count) of \(count) selected" }
        if let free = model.currentStorage?.free { text += ", \(PhoneModel.format(bytes: free)) available" }
        return text
    }
}

/// Finder's icon-size slider. Drawn in SwiftUI: a native slider placed in this bar sends
/// AppKit into an endless constraint pass inside the split view (it crashed the app).
struct IconSizeControl: View {
    @Binding var size: Double
    private let range: ClosedRange<Double> = 32...256

    var body: some View {
        HStack(spacing: 6) {
            Button { size = max(range.lowerBound, size - 16) } label: { Image(systemName: "photo").font(.system(size: 9)) }
                .buttonStyle(.plain).help("Smaller icons")
            GeometryReader { geo in
                let fraction = (size - range.lowerBound) / (range.upperBound - range.lowerBound)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 3)
                    Capsule().fill(Color.accentColor).frame(width: max(3, geo.size.width * fraction), height: 3)
                    Circle()
                        .fill(Color.white)
                        .shadow(radius: 1)
                        .frame(width: 12, height: 12)
                        .offset(x: (geo.size.width - 12) * fraction)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let f = min(max(value.location.x / geo.size.width, 0), 1)
                    size = (range.lowerBound + f * (range.upperBound - range.lowerBound)).rounded()
                })
            }
            .frame(width: 90, height: 14)
            Button { size = min(range.upperBound, size + 16) } label: { Image(systemName: "photo").font(.system(size: 13)) }
                .buttonStyle(.plain).help("Larger icons")
        }
        .foregroundStyle(.secondary)
        .help("Icon size")
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
