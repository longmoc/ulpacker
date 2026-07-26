import SwiftUI

/// The app's colours, in one place because two apps share them.
///
/// The web planner and this app are one product to the person using them, and
/// a route that is green on the laptop and violet on the phone reads as two
/// different tools. These values mirror `src/styles.css` and
/// `src/features/trips/TrackMap.jsx`; changing one side without the other is
/// the thing this file exists to make obvious.
extension Color {
    /// The accent, mirroring `--accent` in `src/styles.css`.
    static let brand = Color(uiColor: .brand)

    /// Secondary text that survives being drawn on a material.
    ///
    /// `.secondary` — as a shape style or as `Color.secondary`, they are the
    /// same thing — is hierarchical, and over a material SwiftUI renders it as
    /// vibrancy rather than as grey ink. Vibrancy takes its contrast from
    /// whatever lies *behind* the material, and behind the info panel is the
    /// map: on a pale valley floor it is nearly white, and every subtitle, stat
    /// heading and close button dissolved into it while the titles beside them
    /// stayed black. The smaller the type the worse it got, which is exactly
    /// backwards.
    ///
    /// A plain colour is not reinterpreted, so it stays legible whatever the
    /// map is doing underneath.
    static let subtle = Color(uiColor: .secondaryLabel)
}

extension UIColor {
    /// Forest green `#1b5e3f` — the planner's accent.
    ///
    /// Light mode takes the web's value unchanged. Dark mode cannot: at 35%
    /// lightness this green disappears into a dark background, so it lifts to
    /// `#2e9e5b`, which is the same family and is already the planner's own
    /// start-marker green rather than a colour invented here.
    static let brand = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x2e / 255, green: 0x9e / 255, blue: 0x5b / 255, alpha: 1)
            : .brandOnMap
    }

    /// The accent as drawn on the map, which has no dark mode.
    ///
    /// The offline basemap is a single light style — pale earth, near-white
    /// roads — so a route line over it is always against that, whatever the
    /// phone's appearance setting is doing to the rest of the interface. Using
    /// the dynamic colour here would light the route up to a bright green on a
    /// pale map the moment the walker switched to dark mode.
    static let brandOnMap = UIColor(red: 0x1b / 255, green: 0x5e / 255, blue: 0x3f / 255, alpha: 1)
}
