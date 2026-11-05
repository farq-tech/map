import SwiftUI
import UIKit

/// Observes whether any finger is on the window, without taking part in any gesture:
/// a recognizer that never recognizes, cancels nothing and delays nothing.
final class TouchWatcherRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onChange: (Bool) -> Void = { _ in }
    private var down = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if down == 0 { onChange(true) }
        down += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches.count) }

    private func lift(_ n: Int) {
        down = max(0, down - n)
        if down == 0 {
            onChange(false)
            state = .failed
        }
    }

    override func reset() { down = 0 }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
}

/// Installs a `TouchWatcherRecognizer` on the window it lives in (removed again with the view).
struct TouchWatcherView: UIViewRepresentable {
    var onChange: (Bool) -> Void

    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ v: Host, context: Context) { v.recognizer.onChange = onChange }
    static func dismantleUIView(_ v: Host, coordinator: ()) { v.recognizer.view?.removeGestureRecognizer(v.recognizer) }

    final class Host: UIView {
        let recognizer = TouchWatcherRecognizer(target: nil, action: nil)
        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }
}
