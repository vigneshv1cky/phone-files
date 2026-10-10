import AppKit
import QuickLookUI
import SwiftUI

/// Embeds the system Quick Look renderer: images, video, audio, PDF, text and anything else
/// macOS can preview — the same engine as Finder's preview pane.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.shouldCloseWithWindow = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    // No explicit close() here: switching views can tear a preview down before Quick Look has
    // finished activating it, and closing it then trips a Quick Look assertion (crash). Clearing
    // the item releases the file; the view closes with the window.
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
    }
}

/// Preview of one item for the preview pane, gallery and column view. Mac files preview
/// directly. Small phone files load automatically; large ones show their thumbnail and a
/// button, so a 2 GB video isn't copied off the phone just because it was selected.
struct PreviewContent: View {
    @ObservedObject var model: AppModel
    let item: FileItem

    var body: some View {
        Group {
            if item.isFolder {
                bigIcon
            } else if let url = item.macURL {
                QuickLookView(url: url)
            } else if let load = model.previews[item.id] {
                LoadedPreview(load: load, placeholder: bigIcon) { model.requestPreview(item, force: true) }
            } else {
                bigIcon
            }
        }
        .task(id: item.id) {
            model.loadThumbnail(for: item)
            model.requestPreview(item, force: false)
        }
    }

    private var bigIcon: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Group {
                if let thumb = model.thumbnails[item.id] {
                    Image(nsImage: thumb).resizable().scaledToFit()
                } else {
                    Image(nsImage: Icons.icon(for: item)).resizable().scaledToFit()
                        .frame(width: side * 0.6, height: side * 0.6)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct LoadedPreview<Placeholder: View>: View {
    @ObservedObject var load: PreviewLoad
    let placeholder: Placeholder
    let loadNow: () -> Void

    var body: some View {
        switch load.state {
        case .ready(let url):
            QuickLookView(url: url)
        case .loading:
            placeholder
                .opacity(0.5)
                .overlay {
                    VStack(spacing: 8) {
                        ProgressView(value: load.fraction).frame(width: 160)
                        Text("Loading preview…").font(.caption).foregroundStyle(.secondary)
                    }
                }
        case .idle:
            placeholder
                .overlay(alignment: .bottom) {
                    Button("Load Preview (\(AppModel.format(bytes: load.item.size)))", action: loadNow)
                        .padding(10)
                }
        case .failed(let message):
            ContentUnavailableView("No Preview", systemImage: "eye.slash", description: Text(message))
        }
    }
}

/// Finder's preview pane: a large preview plus the item's details and quick actions.
struct PreviewPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let selected = model.selectedItems
        ScrollView {
            VStack(spacing: 12) {
                if selected.count == 1 {
                    single(selected[0])
                } else if selected.count > 1 {
                    multiple(selected)
                } else {
                    folderSummary
                }
            }
            .padding(16)
        }
    }

    private func single(_ item: FileItem) -> some View {
        VStack(spacing: 12) {
            PreviewContent(model: model, item: item)
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            Text(item.displayName).font(.headline).multilineTextAlignment(.center).lineLimit(3)
            Text(item.isFolder ? "Folder" : "\(item.kind) · \(AppModel.format(bytes: item.size))")
                .font(.caption).foregroundStyle(.secondary)
            InfoGrid(model: model, item: item)
            HStack {
                Button("Open") { model.open(item) }
                if !item.isFolder { Button("Quick Look") { model.quickLook(item) } }
                if item.isPhone {
                    Button("Copy to Downloads") { model.transfer([item], to: .mac(AppModel.downloadsFolder), move: false) }
                }
            }
            .controlSize(.small)
        }
    }

    private func multiple(_ items: [FileItem]) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.on.doc").font(.system(size: 56)).foregroundStyle(.secondary).padding(.top, 30)
            Text("\(items.count) items").font(.headline)
            let files = items.filter { !$0.isFolder }
            Text("\(AppModel.format(bytes: files.reduce(0) { $0 + $1.size })) in \(files.count) file\(files.count == 1 ? "" : "s")"
                 + (files.count < items.count ? ", plus \(items.count - files.count) folder\(items.count - files.count == 1 ? "" : "s")" : ""))
                .font(.caption).foregroundStyle(.secondary)
            if items.contains(where: \.isPhone) {
                Button("Copy All to Downloads") { model.transfer(items, to: .mac(AppModel.downloadsFolder), move: false) }
                    .controlSize(.small)
            }
        }
    }

    private var folderSummary: some View {
        VStack(spacing: 10) {
            Group {
                if let url = model.location.macURL {
                    Image(nsImage: Icons.icon(forPath: url.path)).resizable().scaledToFit()
                } else {
                    Image(systemName: "smartphone").resizable().scaledToFit().foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 72, height: 72)
            .padding(.top, 30)
            Text(model.currentTitle).font(.headline)
            let items = model.visibleItems
            Text("\(items.count) items · \(AppModel.format(bytes: items.filter { !$0.isFolder }.reduce(0) { $0 + $1.size })) in files")
                .font(.caption).foregroundStyle(.secondary)
            Text("Select an item to preview it.").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// The Information section: kind, size, date, dimensions and where the item lives.
struct InfoGrid: View {
    @ObservedObject var model: AppModel
    let item: FileItem

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            row("Kind", item.kind)
            if !item.isFolder { row("Size", "\(AppModel.format(bytes: item.size)) (\(item.size.formatted()) bytes)") }
            if item.modified.timeIntervalSince1970 > 0 {
                row("Modified", item.modified.formatted(date: .long, time: .shortened))
            }
            if let size = model.dimensions(of: item) {
                row("Dimensions", "\(Int(size.width)) × \(Int(size.height))")
            }
            row("Where", item.macURL?.deletingLastPathComponent().path
                ?? model.breadcrumbs.map(\.title).joined(separator: " › "))
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }
}
