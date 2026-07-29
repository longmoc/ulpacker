import SwiftUI
import UIKit

/// Two fingers dragged sideways, reported as a translation.
///
/// SwiftUI's `DragGesture` cannot say how many fingers are down, so a pan that
/// must not be confused with moving a point has to come from UIKit. One finger
/// places a point on the chart and two fingers scroll it — the same division of
/// labour every map on the phone already uses.
///
/// The view itself is never hit: `hitTest` returns nil, so touches reach the
/// SwiftUI gestures underneath as if this were not here. The recogniser is
/// attached to the host view instead, where it can watch the same touches
/// without taking them.
struct TwoFingerPan: UIViewRepresentable {
    var onBegan: () -> Void
    /// Horizontal translation since the last call, in points.
    var onChange: (CGFloat) -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughView()
        view.coordinator = context.coordinator
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.owner = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: TwoFingerPan
        private var last: CGFloat = 0

        init(owner: TwoFingerPan) { self.owner = owner }

        @objc func handle(_ recogniser: UIPanGestureRecognizer) {
            switch recogniser.state {
            case .began:
                last = 0
                owner.onBegan()
            case .changed:
                let x = recogniser.translation(in: recogniser.view).x
                owner.onChange(x - last)
                last = x
            case .ended, .cancelled, .failed:
                owner.onEnded()
            default:
                break
            }
        }

        /// The one-finger drag and this must coexist; the touch count is what
        /// keeps them apart, not exclusivity.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
    }

    private final class PassthroughView: UIView {
        weak var coordinator: Coordinator?
        private var attached = false

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !attached, let host = superview, let coordinator else { return }
            let pan = UIPanGestureRecognizer(
                target: coordinator, action: #selector(Coordinator.handle(_:))
            )
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.delegate = coordinator
            host.addGestureRecognizer(pan)
            attached = true
        }
    }
}
