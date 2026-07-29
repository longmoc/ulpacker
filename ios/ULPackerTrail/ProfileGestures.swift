import SwiftUI
import UIKit

/// Every touch on the elevation chart, arbitrated in one place.
///
/// The three gestures the chart needs do not coexist under SwiftUI. A
/// `DragGesture(minimumDistance: 0)` claims a touch the instant it lands, which
/// is exactly right for placing a point and exactly wrong for everything else:
/// a pinch begins with one finger, so the drag had already won by the time the
/// second arrived, and zooming almost never got a look in. Adding the two
/// finger pan through a separate representable made it worse — its recogniser
/// was attached to whatever `superview` happened to be at the time and never
/// removed, so every trip through the tab bar left another one behind, which is
/// why switching tabs changed the behaviour.
///
/// UIKit arbitrates this properly, so all three live here on one view:
///
///   * a long press of zero duration, which reports touch-down and every move
///     after it — `DragGesture(minimumDistance: 0)` without the greed
///   * a pinch
///   * a pan that wants exactly two touches
///
/// They are allowed to recognise simultaneously, and the point simply refuses
/// to move while a pinch or a two-finger pan is running. A point nudged by the
/// first finger of a pinch is put back where it was.
struct ProfileGestures: UIViewRepresentable {
    /// Fraction across the view, 0…1.
    var onPoint: (CGFloat) -> Void
    var onPointEnded: () -> Void
    /// Multiplier since the pinch began.
    var onZoom: (CGFloat) -> Void
    var onZoomEnded: () -> Void
    /// Horizontal translation since the last call, in points.
    var onPan: (CGFloat) -> Void
    var onPanEnded: () -> Void
    /// Called when a multi-touch gesture takes over, so a point moved by the
    /// first finger can be undone.
    var onMultiTouchBegan: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let coordinator = context.coordinator

        let point = UILongPressGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handlePoint(_:))
        )
        point.minimumPressDuration = 0
        point.allowableMovement = .greatestFiniteMagnitude

        let pinch = UIPinchGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handlePinch(_:))
        )
        let pan = UIPanGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.handlePan(_:))
        )
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2

        for recogniser in [point, pinch, pan] as [UIGestureRecognizer] {
            recogniser.delegate = coordinator
            view.addGestureRecognizer(recogniser)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.owner = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: ProfileGestures
        private var multiTouch = false
        private var lastPan: CGFloat = 0

        init(owner: ProfileGestures) { self.owner = owner }

        @objc func handlePoint(_ recogniser: UILongPressGestureRecognizer) {
            guard let view = recogniser.view else { return }
            switch recogniser.state {
            case .began, .changed:
                guard !multiTouch else { return }
                let x = recogniser.location(in: view).x
                owner.onPoint(min(max(0, x / max(1, view.bounds.width)), 1))
            case .ended, .cancelled, .failed:
                owner.onPointEnded()
            default:
                break
            }
        }

        @objc func handlePinch(_ recogniser: UIPinchGestureRecognizer) {
            switch recogniser.state {
            case .began:
                beginMultiTouch()
            case .changed:
                owner.onZoom(recogniser.scale)
            case .ended, .cancelled, .failed:
                multiTouch = false
                owner.onZoomEnded()
            default:
                break
            }
        }

        @objc func handlePan(_ recogniser: UIPanGestureRecognizer) {
            guard let view = recogniser.view else { return }
            switch recogniser.state {
            case .began:
                beginMultiTouch()
                lastPan = 0
            case .changed:
                let x = recogniser.translation(in: view).x
                owner.onPan(x - lastPan)
                lastPan = x
            case .ended, .cancelled, .failed:
                multiTouch = false
                owner.onPanEnded()
            default:
                break
            }
        }

        private func beginMultiTouch() {
            guard !multiTouch else { return }
            multiTouch = true
            // The first finger of a pinch has already placed a point by now.
            // Put it back: nobody pinching meant to move it.
            owner.onMultiTouchBegan()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }
}
