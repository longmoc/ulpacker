import SwiftUI

@main
struct ULPackerTrailApp: App {
    @State private var library = TripLibrary()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            // Automated-test hook, compiled out of release builds. The trail
            // screen is otherwise two taps deep, and driving those taps needs
            // accessibility permissions that CI and a headless simulator run do
            // not have. Launch with `-uiTestAutoStartTrail` to land on it.
            if ProcessInfo.processInfo.arguments.contains("-uiTestAutoStartTrail"),
               case .loaded(let packages) = library.state,
               let first = packages.first {
                NavigationStack { TrailMapScreen(package: first, autoStart: true) }
            } else {
                TripListView(library: library)
            }
            #else
            TripListView(library: library)
            #endif
        }
    }
}
