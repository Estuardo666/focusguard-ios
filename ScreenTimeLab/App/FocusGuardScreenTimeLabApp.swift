import SwiftUI
import SwiftData

@main
struct FocusGuardScreenTimeLabApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try FocusGuardModelContainerFactory.make()
        } catch {
            // Never take down the app over storage setup: fall back to an
            // in-memory store so the UI can surface the problem instead.
            modelContainer = try! FocusGuardModelContainerFactory.makeInMemory()
        }
    }

    var body: some Scene {
        WindowGroup {
            ScreenTimeLabView()
        }
        .modelContainer(modelContainer)
    }
}
