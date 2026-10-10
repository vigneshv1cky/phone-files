import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let contentDropID = "content"
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if model.dropTargetID == contentDropID { DropOverlay(title: "Drop to put here: \(model.currentTitle)") }
                }
                .onDrop(of: [.phoneFilesItem, .fileURL],
                        delegate: FolderDrop(model: model, destination: model.location, targetID: contentDropID))
            Divider()
            PathBar(model: model)
            Divider()
            StatusBar(model: model)
        }
        .navigationTitle(model.currentTitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search this folder")
        .toolbar { BrowserToolbar(model: model) }
    }

    @ViewBuilder
    private var content: some View {
        if model.location.isPhone, let phoneState = phoneStateView {
            phoneState
        } else if let error = model.currentError {
            ContentUnavailableView {
                Label("Can’t open this folder", systemImage: "lock")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
                if !model.location.isPhone {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                    }
                }
            }
        } else if model.viewMode == .columns {
            FinderColumnView(model: model)  // the native column browser handles its own states
        } else if !model.hasListing {
            ProgressView()
        } else if model.visibleItems.isEmpty {
            if model.searchText.isEmpty {
                ContentUnavailableView("Empty Folder", systemImage: "folder",
                                       description: Text("Drag files here to put them in this folder."))
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

    /// What to show instead of a phone folder while the phone isn't usable.
    private var phoneStateView: AnyView? {
        switch model.connection {
        case .idle, .connecting:
            return AnyView(ProgressView("Connecting to \(model.phoneName)…"))
        case .failed(let message):
            return AnyView(ContentUnavailableView {
                Label("Phone not connected", systemImage: "cable.connector.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Connect") { Task { await model.connectPhone() } }.buttonStyle(.borderedProminent)
            })
        case .connected:
            guard model.storages.isEmpty else { return nil }
            return AnyView(ContentUnavailableView {
                Label("Phone is locked", systemImage: "lock")
            } description: {
                Text(model.storageError ?? "Unlock the phone to see its files.")
            } actions: {
                Button("Try Again") { Task { await model.connectPhone() } }.buttonStyle(.borderedProminent)
            })
        }
    }
}

struct BrowserToolbar: ToolbarContent {
    @ObservedObject var model: AppModel

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
                Button("Copy Files Here…") { model.pickFilesToCopyHere() }
                if model.canPaste { Button("Paste") { model.paste(move: false) } }
                Divider()
                Button("Reconnect Phone") { Task { await model.connectPhone() } }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .help("Perform tasks with the selected items")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.showPreviewPane.toggle() } label: { Label("Preview", systemImage: "sidebar.right") }
                .help(model.showPreviewPane ? "Hide preview" : "Show preview")
        }
    }
}

/// The right-click menu, shared by every view and the toolbar's Actions menu.
struct ItemMenu: View {
    let model: AppModel
    let items: [FileItem]

    var body: some View {
        if items.count == 1 {
            Button("Open") { model.open(items[0]) }
            if !items[0].isFolder { Button("Quick Look") { model.quickLook(items[0]) } }
            Button("Get Info") { model.selection = [items[0].id]; model.showPreviewPane = true }
            Button("Rename…") { model.renameTarget = items[0] }
            Divider()
        }
        if !items.isEmpty {
            Button("Copy") { model.copyToClipboard(items) }
            if items.contains(where: \.isPhone) {
                Button("Copy to Downloads") { model.transfer(items, to: .mac(AppModel.downloadsFolder), move: false) }
            }
            Button("Copy To…") { model.copy(items, toChosenFolder: true) }
            if let url = items.first?.macURL, items.count == 1 {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Divider()
            Button(items.contains(where: \.isPhone) ? "Delete…" : "Move to Trash", role: .destructive) {
                model.beginDelete(items)
            }
        }
    }
}

struct PathBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let crumbs = model.breadcrumbs
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button { model.navigate(to: crumb.location) } label: {
                        HStack(spacing: 4) {
                            crumbIcon(crumb.location, isRoot: index == 0)
                            Text(crumb.title).lineLimit(1)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(index == crumbs.count - 1 ? .primary : .secondary)
                    .onDrop(of: [.phoneFilesItem, .fileURL],
                            delegate: FolderDrop(model: model, destination: crumb.location, targetID: "crumb:\(index)"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func crumbIcon(_ location: Location, isRoot: Bool) -> some View {
        if let url = location.macURL {
            Image(nsImage: Icons.icon(forPath: url.path)).resizable().frame(width: 14, height: 14)
        } else {
            Image(systemName: isRoot ? "smartphone" : "folder.fill")
        }
    }
}

struct StatusBar: View {
    @ObservedObject var model: AppModel

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
        if let free = model.availableSpace { text += ", \(AppModel.format(bytes: free)) available" }
        return text
    }
}

/// Finder's icon-size slider. Drawn in SwiftUI: a native slider placed in this bar sent
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
    let title: String

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
            .overlay(Label(title, systemImage: "square.and.arrow.down.on.square").font(.title3).padding())
            .padding(10)
            .allowsHitTesting(false)
    }
}
