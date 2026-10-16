import C6Core
import SwiftUI

@main
struct C6App: App {
    @StateObject private var model = AppModel()
    @StateObject private var preview = AudioPreview()

    init() {
        #if DEBUG
        MainActor.assumeIsolated { PreviewRenderer.run(CommandLine.arguments) }
        #endif
    }

    var body: some Scene {
        WindowGroup("C2026") {
            ContentView().environmentObject(model).environmentObject(preview)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
