import SwiftUI

@main
struct ULPackerTrailApp: App {
    @State private var library = TripLibrary()
    #if DEBUG
    /// Starts pushed, but is a real binding, so the back button pops it. A
    /// debug launch that *replaced* the list left the app with no way back —
    /// which is exactly what it looked like from the outside when the app was
    /// resumed from the switcher after one of those launches.
    @State private var debugPushed = true
    #endif

    var body: some Scene {
        WindowGroup {
            content
                // AirDrop, Files, a mail attachment: all of them arrive here.
                .onOpenURL { library.receive($0) }
                #if DEBUG
                .task {
                    // Stands in for a file arriving from elsewhere, which a
                    // headless run has no way to hand over.
                    guard ProcessInfo.processInfo.arguments.contains("-uiTestImport") else { return }
                    library.receive(
                        URL.documentsDirectory.appendingPathComponent("incoming.json")
                    )
                }
                #endif
        }
    }

    @ViewBuilder private var content: some View {
        Group {
            #if DEBUG
            // Automated-test hook, compiled out of release builds. The trail
            // screen is otherwise two taps deep, and driving those taps needs
            // accessibility permissions that CI and a headless simulator run do
            // not have. Launch with `-uiTestAutoStartTrail` to land on it.
            NavigationStack {
                TripListView(library: library)
                    .navigationDestination(isPresented: debugDestinationBinding) {
                        debugDestination
                    }
            }
            #else
            NavigationStack { TripListView(library: library) }
            #endif
        }
    }

    #if DEBUG
    private var debugArgument: String? {
        let arguments = ProcessInfo.processInfo.arguments
        return ["-uiTestAutoStartTrail", "-uiTestOpenTrail", "-uiTestOpenDetail"]
            .first { arguments.contains($0) }
    }

    /// Never pushes without a launch argument, so a normal run opens the list.
    private var debugDestinationBinding: Binding<Bool> {
        Binding(
            get: { debugArgument != nil && debugPushed },
            set: { debugPushed = $0 }
        )
    }

    @ViewBuilder private var debugDestination: some View {
        if case .loaded(let packages) = library.state, let first = packages.first {
            switch debugArgument {
            case "-uiTestAutoStartTrail": TrailMapScreen(package: first, autoStart: true)
            case "-uiTestOpenDetail": TripDetailView(package: first)
            default: TrailMapScreen(package: first)
            }
        }
    }
    #endif
}
