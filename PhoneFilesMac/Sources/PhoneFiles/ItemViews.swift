import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared pieces

/// Finder's icon for the item, or its picture thumbnail once loaded. Takes plain values only.
struct ItemIcon: View {
    let item: FileItem
    let thumbnail: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.06)))
            } else {
                Image(nsImage: Icons.icon(for: item)).resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
    }
}

/// Finder-style click handling: plain click selects, Command toggles, Shift extends a range.
@MainActor
struct SelectionClicks {
    let model: AppModel
    let items: [FileItem]

    func click(_ item: FileItem, anchor: inout String?) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
            anchor = item.id
        } else if flags.contains(.shift), let anchorID = anchor,
                  let from = items.firstIndex(where: { $0.id == anchorID }),
                  let to = items.firstIndex(where: { $0.id == item.id }) {
            model.selection = Set(items[min(from, to)...max(from, to)].map(\.id))
        } else {
            model.selection = [item.id]
            anchor = item.id
        }
    }

    /// Arrow-key movement through a flat sequence of items.
    func move(by offset: Int) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { model.selection.contains($0.id) }
        let next = current.map { min(max($0 + offset, 0), items.count - 1) } ?? 0
        model.selection = [items[next].id]
    }
}

extension View {
    /// Space = Quick Look, Return = rename: the Finder keys.
    func finderKeys(_ model: AppModel) -> some View {
        self
            .onKeyPress(.space) {
                guard !model.selection.isEmpty || model.quickLookURL != nil else { return .ignored }
                model.quickLookSelection()
                return .handled
            }
            .onKeyPress(.return) {
                guard model.selectedItems.count == 1 else { return .ignored }
                model.beginRename()
                return .handled
            }
    }

    /// Makes a folder accept drops (files go inside it); other items are left alone.
    @ViewBuilder
    func folderDropTarget(_ item: FileItem, in parent: Location, model: AppModel) -> some View {
        if item.isFolder {
            self
                .onDrop(of: [.phoneFilesItem, .fileURL],
                        delegate: FolderDrop(model: model, destination: model.child(item, of: parent), targetID: item.id))
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(model.dropTargetID == item.id ? Color.accentColor.opacity(0.3) : Color.clear))
        } else {
            self
        }
    }
}

// MARK: - List

struct ListBrowser: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let items = model.visibleItems
        let iconSize = model.listIconSize
        let here = model.location
        Table(of: FileItem.self, selection: $model.selection, sortOrder: sortOrder) {
            TableColumn("Name", value: \.displayName, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    ItemIcon(item: item, thumbnail: model.thumbnails[item.id], size: iconSize)
                        .onAppear { model.loadThumbnail(for: item) }
                    Text(item.displayName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .folderDropTarget(item, in: here, model: model)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.modified.timeIntervalSince1970 > 0
                     ? item.modified.formatted(date: .abbreviated, time: .shortened) : "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "—" : AppModel.format(bytes: item.size))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 130)
        } rows: {
            ForEach(items) { item in
                TableRow(item).itemProvider { model.dragProvider(for: item) }
            }
        }
        .font(.system(size: model.listFontSize))
        .environment(\.defaultMinListRowHeight, iconSize + 6)
        .contextMenu(forSelectionType: String.self) { ids in
            ItemMenu(model: model, items: items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let item = items.first(where: { ids.contains($0.id) }) { model.open(item) }
        }
        .finderKeys(model)
    }

    /// The column headers drive the same sort settings as the Sort menu.
    private var sortOrder: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            get: {
                let order: SortOrder = model.ascending ? .forward : .reverse
                switch model.sortKey {
                case .name: return [KeyPathComparator(\FileItem.displayName, comparator: .localizedStandard, order: order)]
                case .kind: return [KeyPathComparator(\FileItem.kind, comparator: .localizedStandard, order: order)]
                case .modified: return [KeyPathComparator(\FileItem.modified, order: order)]
                case .size: return [KeyPathComparator(\FileItem.size, order: order)]
                }
            },
            set: { comparators in
                guard let first = comparators.first else { return }
                model.ascending = first.order == .forward
                switch first.keyPath {
                case \FileItem.kind: model.sortKey = .kind
                case \FileItem.modified: model.sortKey = .modified
                case \FileItem.size: model.sortKey = .size
                default: model.sortKey = .name
                }
            })
    }
}

// MARK: - Icons

struct IconBrowser: View {
    @ObservedObject var model: AppModel
    @State private var anchor: String?
    @State private var width: CGFloat = 800
    @FocusState private var focused: Bool

    var body: some View {
        let clicks = SelectionClicks(model: model, items: model.visibleItems)
        let perRow = tilesPerRow
        grid(clicks)
            .background(Color(nsColor: .textBackgroundColor))
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { width = geo.size.width }
            })
            .contentShape(Rectangle())
            .onTapGesture { focused = true; model.selection = [] }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { clicks.move(by: -1); return .handled }
            .onKeyPress(.rightArrow) { clicks.move(by: 1); return .handled }
            .onKeyPress(.upArrow) { clicks.move(by: -perRow); return .handled }
            .onKeyPress(.downArrow) { clicks.move(by: perRow); return .handled }
            .finderKeys(model)
            .onAppear { focused = true }
    }

    /// How many tiles fit on a row, so Up/Down move by a whole row as in Finder.
    private var tilesPerRow: Int {
        let usable: CGFloat = width - 32 + 10
        let tile: CGFloat = CGFloat(model.iconSize) + 36 + 10
        return max(1, Int(usable / tile))
    }

    private func grid(_ clicks: SelectionClicks) -> some View {
        let size = CGFloat(model.iconSize)
        let columns = [GridItem(.adaptive(minimum: size + 36, maximum: size + 60), spacing: 10)]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(model.visibleItems) { item in
                        tile(item, size: size, clicks: clicks)
                    }
                }
                .padding(16)
            }
            .onChange(of: model.selection) {
                if model.selection.count == 1, let id = model.selection.first { proxy.scrollTo(id) }
            }
        }
    }

    private func tile(_ item: FileItem, size: CGFloat, clicks: SelectionClicks) -> some View {
        IconTile(item: item, thumbnail: model.thumbnails[item.id], size: size,
                 selected: model.selection.contains(item.id))
            .folderDropTarget(item, in: model.location, model: model)
            .id(item.id)
            .onAppear { model.loadThumbnail(for: item) }
            .onTapGesture(count: 2) { model.open(item) }
            .simultaneousGesture(TapGesture().onEnded { focused = true; clicks.click(item, anchor: &anchor) })
            .contextMenu {
                ItemMenu(model: model, items: model.selection.contains(item.id) ? model.selectedItems : [item])
            }
            .onDrag { model.dragProvider(for: item) }
    }
}

struct IconTile: View {
    let item: FileItem
    let thumbnail: NSImage?
    let size: CGFloat
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ItemIcon(item: item, thumbnail: thumbnail, size: size)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.secondary.opacity(0.25) : Color.clear))
            Text(item.displayName)
                .font(.system(size: size >= 96 ? 12 : 11))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor : Color.clear))
                .foregroundStyle(selected ? Color.white : .primary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

// MARK: - Columns

struct ColumnPreview: View {
    @ObservedObject var model: AppModel
    let item: FileItem

    var body: some View {
        VStack(spacing: 12) {
            PreviewContent(model: model, item: item)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
            Text(item.displayName).font(.headline).multilineTextAlignment(.center).lineLimit(3)
            Text("\(item.kind) · \(AppModel.format(bytes: item.size))").font(.caption).foregroundStyle(.secondary)
            InfoGrid(model: model, item: item)
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Gallery

struct GalleryBrowser: View {
    @ObservedObject var model: AppModel
    @State private var anchor: String?
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.visibleItems
        let here = model.location
        let clicks = SelectionClicks(model: model, items: items)
        let current = model.selectedItems.first ?? items.first
        VStack(spacing: 0) {
            Group {
                if let current {
                    PreviewContent(model: model, item: current)
                        .padding(20)
                        .onTapGesture(count: 2) { model.open(current) }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let current {
                Text(current.displayName).font(.headline).lineLimit(1).truncationMode(.middle).padding(.bottom, 2)
                Text("\(current.kind) · \(current.isFolder ? "Folder" : AppModel.format(bytes: current.size))")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 6) {
                        ForEach(items) { item in
                            ItemIcon(item: item, thumbnail: model.thumbnails[item.id], size: model.filmstripSize)
                                .padding(3)
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(item.id == current?.id ? Color.accentColor : .clear, lineWidth: 3))
                                .folderDropTarget(item, in: here, model: model)
                                .id(item.id)
                                .onAppear { model.loadThumbnail(for: item) }
                                .onTapGesture(count: 2) { model.open(item) }
                                .simultaneousGesture(TapGesture().onEnded { focused = true; clicks.click(item, anchor: &anchor) })
                                .contextMenu {
                                    ItemMenu(model: model, items: model.selection.contains(item.id) ? model.selectedItems : [item])
                                }
                                .onDrag { model.dragProvider(for: item) }
                                .help(item.displayName)
                        }
                    }
                    .padding(10)
                }
                .frame(height: model.filmstripSize + 30)
                .onChange(of: current?.id) { if let id = current?.id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { clicks.move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { clicks.move(by: 1); return .handled }
        .onKeyPress(.upArrow) { clicks.move(by: -1); return .handled }
        .onKeyPress(.downArrow) { clicks.move(by: 1); return .handled }
        .finderKeys(model)
        .onAppear {
            focused = true
            if model.selection.isEmpty, let first = items.first { model.selection = [first.id] }
        }
    }
}
