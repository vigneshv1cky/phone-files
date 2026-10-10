import AppKit
import SwiftUI

// MARK: - Shared pieces

/// File or folder icon, or the phone's thumbnail once loaded. Takes plain values only.
struct ItemIcon: View {
    let item: PhoneItem
    let thumbnail: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: FileKind(item).symbol)
                    .resizable().scaledToFit()
                    .padding(size * 0.12)
                    .foregroundStyle(item.isFolder ? Color.accentColor : .secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(2, size * 0.12)))
    }
}

/// Finder-style click handling: plain click selects, Command toggles, Shift extends a range.
@MainActor
struct SelectionClicks {
    let model: PhoneModel
    let items: [PhoneItem]

    func click(_ item: PhoneItem, anchor: inout UInt32?) {
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
    /// Space = Quick Look, Return = rename, Command-Down = open: the Finder keys.
    func finderKeys(_ model: PhoneModel) -> some View {
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
}

// MARK: - List

struct ListBrowser: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        let items = model.visibleItems
        let iconSize = model.listIconSize
        Table(of: PhoneItem.self, selection: $model.selection, sortOrder: sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { item in
                HStack(spacing: 6) {
                    ItemIcon(item: item, thumbnail: model.thumbnails[item.id], size: iconSize)
                        .onAppear { model.loadThumbnail(for: item) }
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 180, ideal: 320)
            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.modified.timeIntervalSince1970 > 0
                     ? item.modified.formatted(date: .abbreviated, time: .shortened) : "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 170)
            TableColumn("Size", value: \.size) { item in
                Text(item.isFolder ? "—" : PhoneModel.format(bytes: item.size))
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
        .contextMenu(forSelectionType: UInt32.self) { ids in
            ItemMenu(model: model, items: items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let item = items.first(where: { ids.contains($0.id) }) { model.open(item) }
        }
        .finderKeys(model)
    }

    /// The column headers drive the same sort settings as the Sort menu.
    private var sortOrder: Binding<[KeyPathComparator<PhoneItem>]> {
        Binding(
            get: {
                let order: SortOrder = model.ascending ? .forward : .reverse
                switch model.sortKey {
                case .name: return [KeyPathComparator(\PhoneItem.name, comparator: .localizedStandard, order: order)]
                case .kind: return [KeyPathComparator(\PhoneItem.kind, comparator: .localizedStandard, order: order)]
                case .modified: return [KeyPathComparator(\PhoneItem.modified, order: order)]
                case .size: return [KeyPathComparator(\PhoneItem.size, order: order)]
                }
            },
            set: { comparators in
                guard let first = comparators.first else { return }
                model.ascending = first.order == .forward
                switch first.keyPath {
                case \PhoneItem.kind: model.sortKey = .kind
                case \PhoneItem.modified: model.sortKey = .modified
                case \PhoneItem.size: model.sortKey = .size
                default: model.sortKey = .name
                }
            })
    }
}

// MARK: - Icons

struct IconBrowser: View {
    @ObservedObject var model: PhoneModel
    @State private var anchor: UInt32?

    var body: some View {
        let items = model.visibleItems
        let size = CGFloat(model.iconSize)
        let clicks = SelectionClicks(model: model, items: items)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: size + 36, maximum: size + 60), spacing: 10)], spacing: 14) {
                ForEach(items) { item in
                    IconTile(item: item, thumbnail: model.thumbnails[item.id], size: size,
                             selected: model.selection.contains(item.id))
                        .onAppear { model.loadThumbnail(for: item) }
                        .onTapGesture(count: 2) { model.open(item) }
                        .simultaneousGesture(TapGesture().onEnded { clicks.click(item, anchor: &anchor) })
                        .contextMenu {
                            ItemMenu(model: model, items: model.selection.contains(item.id) ? model.selectedItems : [item])
                        }
                        .onDrag { model.dragProvider(for: item) }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [] }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { clicks.move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { clicks.move(by: 1); return .handled }
        .finderKeys(model)
    }
}

struct IconTile: View {
    let item: PhoneItem
    let thumbnail: NSImage?
    let size: CGFloat
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ItemIcon(item: item, thumbnail: thumbnail, size: size)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.secondary.opacity(0.25) : Color.clear))
            Text(item.name)
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

struct ColumnBrowser: View {
    @ObservedObject var model: PhoneModel

    var body: some View {
        let folders = [MTPDevice.root] + model.path.map(\.id)
        let selectedFile = model.selectedItems.count == 1 && !model.selectedItems[0].isFolder ? model.selectedItems[0] : nil
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                        FolderColumn(model: model, folder: folder, index: index)
                            .frame(width: 240)
                            .id(index)
                        Divider()
                    }
                    if let file = selectedFile {
                        ColumnPreview(model: model, item: file)
                            .frame(width: 320)
                            .id("preview")
                    }
                }
            }
            .onChange(of: model.path) {
                withAnimation { proxy.scrollTo(model.path.count, anchor: .trailing) }
            }
            .onChange(of: selectedFile?.id) {
                if selectedFile != nil { withAnimation { proxy.scrollTo("preview", anchor: .trailing) } }
            }
        }
        .task(id: folders) { await model.ensureLoaded(folders) }
    }
}

struct FolderColumn: View {
    @ObservedObject var model: PhoneModel
    let folder: UInt32
    let index: Int

    var body: some View {
        let items = model.visible(folder)
        let iconSize = model.listIconSize
        Group {
            if model.children[folder] == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text(model.searchText.isEmpty ? "Empty" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { highlighted },
                    set: { id in if let id, let item = items.first(where: { $0.id == id }) { model.columnSelect(item, at: index) } })
                ) {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            ItemIcon(item: item, thumbnail: model.thumbnails[item.id], size: iconSize)
                                .onAppear { model.loadThumbnail(for: item) }
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if item.isFolder {
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: model.listFontSize))
                        .tag(item.id)
                        .onDrag { model.dragProvider(for: item) }
                    }
                }
                .listStyle(.plain)
                .contextMenu(forSelectionType: UInt32.self) { ids in
                    ItemMenu(model: model, items: items.filter { ids.contains($0.id) })
                } primaryAction: { ids in
                    if let item = items.first(where: { ids.contains($0.id) }), !item.isFolder { model.open(item) }
                }
                .finderKeys(model)
            }
        }
    }

    /// The folder chosen in this column, or the selected file in the last column.
    private var highlighted: UInt32? {
        index < model.path.count ? model.path[index].id : model.selection.first
    }
}

struct ColumnPreview: View {
    @ObservedObject var model: PhoneModel
    let item: PhoneItem

    var body: some View {
        VStack(spacing: 12) {
            PreviewContent(model: model, item: item)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 320)
            Text(item.name).font(.headline).multilineTextAlignment(.center).lineLimit(3)
            Text("\(item.kind) · \(PhoneModel.format(bytes: item.size))").font(.caption).foregroundStyle(.secondary)
            InfoGrid(model: model, item: item)
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - Gallery

struct GalleryBrowser: View {
    @ObservedObject var model: PhoneModel
    @State private var anchor: UInt32?

    var body: some View {
        let items = model.visibleItems
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
                Text(current.name).font(.headline).lineLimit(1).truncationMode(.middle).padding(.bottom, 2)
                Text("\(current.kind) · \(current.isFolder ? "Folder" : PhoneModel.format(bytes: current.size))")
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
                                .id(item.id)
                                .onAppear { model.loadThumbnail(for: item) }
                                .onTapGesture(count: 2) { model.open(item) }
                                .simultaneousGesture(TapGesture().onEnded { clicks.click(item, anchor: &anchor) })
                                .contextMenu {
                                    ItemMenu(model: model, items: model.selection.contains(item.id) ? model.selectedItems : [item])
                                }
                                .onDrag { model.dragProvider(for: item) }
                                .help(item.name)
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
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { clicks.move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { clicks.move(by: 1); return .handled }
        .finderKeys(model)
        .onAppear { if model.selection.isEmpty, let first = items.first { model.selection = [first.id] } }
    }
}
