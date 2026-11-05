import SwiftUI
import UIKit

/// SOS never disappears (build 15): while the live sheet is open full height or any sheet
/// covers the map's dock, the SOS button floats in its own window above every sheet, in the
/// dock's corner (bottom left). Touches anywhere else go through to the sheet beneath.
struct SOSOverlayHost: UIViewRepresentable {
    var visible: Bool
    var state: MySOSUI
    var theme: SaryTheme
    var trigger: () -> Void

    func makeUIView(context: Context) -> UIView { SOSAnchorView() }

    func updateUIView(_ v: UIView, context: Context) {
        guard let anchor = v as? SOSAnchorView else { return }
        anchor.model = .init(visible: visible, state: state, theme: theme, trigger: trigger)
    }

    static func dismantleUIView(_ v: UIView, coordinator: ()) {
        (v as? SOSAnchorView)?.tearDown()
    }
}

/// Finds the window scene once in a window, then owns the overlay window for it.
final class SOSAnchorView: UIView {
    struct Model {
        var visible: Bool
        var state: MySOSUI
        var theme: SaryTheme
        var trigger: () -> Void
    }

    var model: Model? { didSet { apply() } }
    private var overlay: SOSOverlayWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { tearDown() } else { apply() }
    }

    func tearDown() {
        overlay?.isHidden = true
        overlay = nil
    }

    private func apply() {
        guard let model, let scene = window?.windowScene else { return }
        if overlay == nil { overlay = SOSOverlayWindow(windowScene: scene) }
        overlay?.update(model)
    }
}

/// A pass-through window over the sheets that holds only the SOS button.
final class SOSOverlayWindow: UIWindow {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var buttonFrame: CGRect = .zero

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert - 1
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        rootViewController = host
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Never the key window: keyboard focus, sheets and alerts stay with the app's own window.
    override var canBecomeKey: Bool { false }

    func update(_ m: SOSAnchorView.Model) {
        host.rootView = AnyView(
            ZStack(alignment: .bottomLeading) {
                Color.clear
                SarySOSButton(state: m.state, trigger: m.trigger)
                    .accessibilityIdentifier("sos.overlay")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [weak self] in self?.buttonFrame = $0 }
                    .padding(.leading, m.theme.space(.l))
                    .padding(.bottom, m.theme.space(.l) + 64)
            }
            .ignoresSafeArea(.keyboard)
            .environment(\.sary, m.theme)
            .environment(\.layoutDirection, .leftToRight)
        )
        isHidden = !m.visible
    }

    /// Only the button takes touches; the rest falls through to the sheet below.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, buttonFrame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
