import AppKit
import SwiftUI

@main
struct ShiyiApp: App {
    @StateObject private var model = AppModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        MainActor.assumeIsolated { Notifier.shared.setup() }
    }

    var body: some Scene {
        Window("拾忆", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                .task { model.start() }
        }
        .defaultSize(width: 1120, height: 720)

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
