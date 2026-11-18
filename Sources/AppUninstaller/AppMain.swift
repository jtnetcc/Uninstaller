import AppKit
import SwiftUI

@main
struct AppUninstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup("App Uninstaller") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1060, minHeight: 660)
                .task { model.bootstrap() }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .sidebar) {
                Button("刷新应用列表") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isScanning)

                Button("撤销上次卸载") { model.undoLastUninstall() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.lastTrashMap.isEmpty)

                Divider()

                Button("操作日志…") { model.showLogs = true }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 无头自测模式：不显示窗口，直接跑完退出
        if CommandLine.arguments.contains("--selftest") {
            NSApp.setActivationPolicy(.prohibited)
            Task { @MainActor in
                await SelfTest.run()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
