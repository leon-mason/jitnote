import AppKit
import SwiftUI

/// Shared app objects, created once at launch.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let notebooks: Notebooks
    let updates: AppUpdates

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Jitnote", isDirectory: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let store = StateStore(file: support.appendingPathComponent("state.json"))
        notebooks = Notebooks(store: store, root: support.appendingPathComponent("notebooks", isDirectory: true), appVersion: version)
        updates = AppUpdates(store: store, currentVersion: version)
    }
}

/// Menu commands reach the main window through these notifications.
extension Notification.Name {
    static let newNote = Notification.Name("Jitnote.newNote")
    static let newFolder = Notification.Name("Jitnote.newFolder")
    static let syncNow = Notification.Name("Jitnote.syncNow")
    /// Save the open note and record a version, e.g. when the app goes to the background.
    static let saveNow = Notification.Name("Jitnote.saveNow")
    /// Switch the open Markdown note between editing and preview.
    static let toggleViewMode = Notification.Name("Jitnote.toggleViewMode")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if GN_DEBUG_HOOKS
        DebugHooks.install()
        #endif
    }

    func applicationWillResignActive(_ notification: Notification) {
        NotificationCenter.default.post(name: .saveNow, object: nil)
        Task { @MainActor in AppModel.shared.notebooks.onBackground() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.notebooks.onForeground() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct JitnoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var notebooks = AppModel.shared.notebooks
    @StateObject private var updates = AppModel.shared.updates

    var body: some Scene {
        Window("记特", id: "main") {
            MainView()
                .environmentObject(notebooks)
                .environmentObject(updates)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建笔记") { NotificationCenter.default.post(name: .newNote, object: nil) }
                    .keyboardShortcut("n")
                Button("新建文件夹") { NotificationCenter.default.post(name: .newFolder, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("同步") { NotificationCenter.default.post(name: .syncNow, object: nil) }
                    .keyboardShortcut("r")
            }
            CommandGroup(after: .toolbar) {
                Button("切换编辑/预览") { NotificationCenter.default.post(name: .toggleViewMode, object: nil) }
                    .keyboardShortcut("e")
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { updates.checkNow() }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(notebooks)
                .environmentObject(updates)
        }
    }
}
