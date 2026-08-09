import SwiftUI

@main
struct ULPackerTrailApp: App {
    @State private var library = TripLibrary()
    /// Owns the one recording that may be in progress. Held here, at the app,
    /// so a walk outlives the screen showing it — the whole point of moving the
    /// recorder off `TrailMapScreen`.
    @State private var coordinator = ActiveSessionCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(library: library, coordinator: coordinator)
                .environment(coordinator)
                // AirDrop, Files, a mail attachment: all of them arrive here.
                .onOpenURL { library.receive($0) }
                .task { BundledPacks.install() }
                // An unfinished walk is resolved once the trips are known, so it
                // can be matched to its exact route and revision.
                .task { coordinator.detectRecovery(in: library) }
                // Backgrounding is the last chance to shrink what a kill costs,
                // and it must fire regardless of which screen is up.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background || phase == .inactive {
                        coordinator.flushForBackgrounding()
                    }
                }
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
}

/// The navigation root: the trip list, the recovery prompt, and the programmatic
/// push that continuing a recovered walk performs.
private struct RootView: View {
    let library: TripLibrary
    @Bindable var coordinator: ActiveSessionCoordinator
    #if DEBUG
    /// Starts pushed, but is a real binding, so the back button pops it. A debug
    /// launch that *replaced* the list left the app with no way back.
    @State private var debugPushed = true
    #endif

    var body: some View {
        NavigationStack {
            TripListView(library: library)
                // Continuing a recovered walk resumes it in the background and
                // then opens its screen, which attaches to the now-running walk.
                .navigationDestination(item: $coordinator.openTarget) { _ in
                    if let package = coordinator.recorder?.package {
                        TrailMapScreen(package: package)
                    }
                }
                #if DEBUG
                .navigationDestination(isPresented: debugDestinationBinding) {
                    debugDestination
                }
                #endif
        }
        .alert(
            recoveryTitle,
            isPresented: recoveryPresented,
            presenting: coordinator.recovery
        ) { recovery in
            switch recovery {
            case .resumable(let journal, let package):
                Button("Continue") { coordinator.continueRecovery(journal, package: package) }
                Button("Discard", role: .destructive) { coordinator.discardRecovery(journal) }
                Button("Not now", role: .cancel) { coordinator.recovery = nil }
            case .orphaned(let journal):
                // No route to resume onto — never force it onto another. Keep it
                // for now (a matching trip could be imported) or discard it.
                Button("Keep", role: .cancel) { coordinator.recovery = nil }
                Button("Discard", role: .destructive) { coordinator.discardRecovery(journal) }
            }
        } message: { recovery in
            switch recovery {
            case .resumable:
                Text("A walk was left unfinished. Everything already saved is intact — continue where it stopped, or discard it.")
            case .orphaned:
                Text("A walk was left unfinished, but its trip is no longer on this phone. Import that trip to continue it, or discard the recording.")
            }
        }
    }

    private var recoveryTitle: String {
        switch coordinator.recovery {
        case .orphaned: "Unfinished walk"
        default: "Continue the interrupted walk?"
        }
    }

    private var recoveryPresented: Binding<Bool> {
        Binding(
            get: { coordinator.recovery != nil },
            set: { if !$0 { coordinator.recovery = nil } }
        )
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
        if case .loaded(let packages) = library.state, !packages.isEmpty {
            // Which trip a screenshot run opens. The list is sorted, so this is
            // stable between runs.
            let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiTestTrip")
                .flatMap { $0 + 1 < ProcessInfo.processInfo.arguments.count
                    ? Int(ProcessInfo.processInfo.arguments[$0 + 1]) : nil } ?? 0
            let first = packages[min(index, packages.count - 1)]
            switch debugArgument {
            case "-uiTestAutoStartTrail": TrailMapScreen(package: first, autoStart: true)
            case "-uiTestOpenDetail": TripDetailView(package: first)
            default: TrailMapScreen(package: first)
            }
        }
    }
    #endif
}
