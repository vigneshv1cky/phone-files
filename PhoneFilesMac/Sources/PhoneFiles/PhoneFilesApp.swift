import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: PhoneModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        Window("Phone Files", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { delegate.model = model }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Reconnect Phone") { Task { await model.connect() } }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}
