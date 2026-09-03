import SwiftUI
import SwiftData

@main
struct FocusGuardScreenTimeLabApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try FocusGuardModelContainerFactory.make()
        } catch {
            fatalError("Unable to initialize the local FocusGuard store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ScreenTimeLabView()
        }
        .modelContainer(modelContainer)
    }
}
