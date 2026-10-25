import SwiftUI
import AppKit
import InterviewCore

@main
struct InterviewAssistantApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Interview Assistant") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { delegate.model = model; DebugScenario.runIfRequested(model) }
        }
        .commands {
            CommandMenu("Session") {
                Button("Ask for help") { model.coordinator?.ask() }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Pause / Resume") { if let c = model.coordinator { if c.status.phase == .paused { Task { await c.resume() } } else { c.pause() } } }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Stop") { model.coordinator?.stop() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Pin suggestion") { model.coordinator?.pin() }.keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Recapture screen") { Task { await model.coordinator?.recapture() } }.keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Compact panel") { CompactPanelController.shared.toggle(model: model) }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environmentObject(model).frame(width: 640, height: 560)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // IA_NO_ACTIVATE keeps verification runs from stealing the user's Space or focus.
        if ProcessInfo.processInfo.environment["IA_NO_ACTIVATE"] == "1" {
            NSApp.setActivationPolicy(.accessory)
            NSApp.deactivate()
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop capture before quitting so nothing keeps recording; pending drafts are discarded (§5.4).
        if let c = model?.coordinator, c.status.isCapturing { c.stop() }
        return .terminateNow
    }
}
