import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // "Make Bigger" is bound to Command-= so it works without Shift; this also catches
        // Command-Shift-= (the "+" character) the way Finder does.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), event.charactersIgnoringModifiers == "+" {
                MainActor.assumeIsolated { self?.model?.zoomIn() }
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Close the MTP session cleanly so the phone is free for other apps.
        MainActor.assumeIsolated { model?.service.shutdown() }
    }
}

@main
struct PhoneFilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Phone Files", id: "main") {
            ContentView(model: model)
                // Wide enough for sidebar (max 280) + file area + preview pane (max 360). When the
                // file area was squeezed below ~350 pt with the pane open, AppKit's split view
                // looped re-solving constraints and crashed the app.
                .frame(minWidth: 1000, minHeight: 480)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1240, height: 780)
        .commands { AppCommands(model: model) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    /// While typing (search box, rename field) Edit commands act on the text, as usual.
    private var editingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    private func textAction(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { model.askNewFolder = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Copy Files Here…") { model.pickFilesToCopyHere() }
                .keyboardShortcut("u")
            Divider()
            Button("Open") { model.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(model.selection.isEmpty)
            Button("Quick Look") { model.quickLookSelection() }
                .keyboardShortcut("y")
                .disabled(model.selection.isEmpty)
            Button("Get Info") { model.showPreviewPane = true }
                .keyboardShortcut("i")
            Button("Rename…") { model.beginRename() }
                .disabled(model.selection.count != 1)
            Divider()
            Button("Copy to Downloads") { model.copySelection(toChosenFolder: false) }
                .keyboardShortcut("d")
                .disabled(model.selection.isEmpty)
            Button("Copy To…") { model.copySelection(toChosenFolder: true) }
                .disabled(model.selection.isEmpty)
            Divider()
            Button(model.selectedItems.contains(where: \.isPhone) ? "Delete…" : "Move to Trash") { model.beginDelete() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)
            Divider()
            Button("Reconnect Phone") { Task { await model.connectPhone() } }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { textAction(#selector(NSText.cut(_:))) }
                .keyboardShortcut("x")
            Button("Copy") { editingText ? textAction(#selector(NSText.copy(_:))) : model.copySelectionToClipboard() }
                .keyboardShortcut("c")
            Button("Paste") { editingText ? textAction(#selector(NSText.paste(_:))) : model.paste(move: false) }
                .keyboardShortcut("v")
            Button("Move Item Here") { model.paste(move: true) }
                .keyboardShortcut("v", modifiers: [.command, .option])
            Button("Select All") { editingText ? textAction(#selector(NSText.selectAll(_:))) : model.selectAll() }
                .keyboardShortcut("a")
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button("as \(mode.title)") { model.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button(model.showPreviewPane ? "Hide Preview" : "Show Preview") { model.showPreviewPane.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(model.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { model.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Picker("Sort By", selection: $model.sortKey) {
                ForEach(SortKey.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Make Bigger") { model.zoomIn() }
                .keyboardShortcut("=")
            Button("Make Smaller") { model.zoomOut() }
                .keyboardShortcut("-")
            Button("Actual Size") { model.resetZoom() }
                .keyboardShortcut("0")
            Divider()
            Button("Refresh") { Task { await model.refresh() } }
                .keyboardShortcut("r")
            Divider()
        }

        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Button("Enclosing Folder") { model.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canGoUp)
            Divider()
            ForEach(AppModel.macFavorites) { place in
                Button(place.title) { model.open(.mac(place.url)) }
            }
            if let storage = model.storages.first {
                Divider()
                Button(model.phoneName) { model.open(.phone(storage: storage.id)) }
                ForEach(model.phoneFavorites) { folder in
                    Button(folder.name) { model.open(.phoneFolder(folder)) }
                }
            }
        }
    }
}
