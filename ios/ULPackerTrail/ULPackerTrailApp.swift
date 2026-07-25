import SwiftUI

@main
struct ULPackerTrailApp: App {
    @State private var library = TripLibrary()

    var body: some Scene {
        WindowGroup {
            TripListView(library: library)
        }
    }
}
