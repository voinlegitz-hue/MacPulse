import SwiftUI

@main
struct MacPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Task { @MainActor in
            await FanControlService.shared.start()
        }
    }

    var body: some Scene {
        Window("MacPulse", id: "main") {
            MonitorWindowView(monitor: .shared, preferences: .shared)
        }
        .defaultSize(width: 980, height: 700)
        .commands {
            MacPulseCommands()
        }

        Settings {
            EmptyView()
        }
    }
}

private struct MacPulseCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Open MacPulse") {
                openWindow(id: "main")
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
