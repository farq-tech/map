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
    /// Where the map's own SOS is (window points): the floating copy sits exactly there.
    var frame: CGRect? = nil
    var size: CGFloat? = nil

    func makeUIView(context: Context) -> UIView { SOSAnchorView() }

    func updateUIView(_ v: UIView, context: Context) {
        guard let anchor = v as? SOSAnchorView else { return }
        anchor.model = .init(visible: visible, state: state, theme: theme, trigger: trigger, frame: frame, size: size)
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
        var frame: CGRect? = nil
        var size: CGFloat? = nil
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

/// A small window over the sheets that holds only the SOS button, in the dock's corner
/// (bottom left). It covers nothing else: the rest of the screen — touches and accessibility
/// alike — belongs to the sheets beneath.
final class SOSOverlayWindow: UIWindow {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    /// Whether the floating copy is wanted (a full sheet or a sheet on top covers the map's SOS).
    private var wanted = false
    /// The keyboard is up: the person is typing in that sheet, and a disc there would cover keys.
    private var keyboardUp = false
    private var observers: [NSObjectProtocol] = []

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert - 1
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        rootViewController = host
        isHidden = true
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardUp = true; self?.applyVisibility() }
        })
        observers.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardUp = false; self?.applyVisibility() }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func applyVisibility() { isHidden = !wanted || keyboardUp }

    required init?(coder: NSCoder) { fatalError() }

    /// Never the key window: keyboard focus, sheets and alerts stay with the app's own window.
    override var canBecomeKey: Bool { false }

    func update(_ m: SOSAnchorView.Model) {
        let disc = m.size ?? m.theme.bigButton
        let side = disc + 16
        let screen = windowScene?.coordinateSpace.bounds ?? UIScreen.main.bounds
        let safeBottom = windowScene?.windows.first(where: { $0 !== self && $0.isKeyWindow })?.safeAreaInsets.bottom ?? 34
        /* Over a full sheet the map's spot (top left, under the header) is where sheets put their
         * search field and first row (QA: it covered «ابحث أو أدخل إحداثية»): the copy sits in the
         * bottom-left corner instead, the least used part of a sheet. On the map itself the real
         * SOS never moves. */
        let f = CGRect(x: m.theme.space(.l) - 8, y: screen.height - safeBottom - m.theme.space(.s) - side, width: side, height: side)
        if frame != f { frame = f }
        host.rootView = AnyView(
            SarySOSButton(state: m.state, trigger: m.trigger, size: m.size, compactLabel: m.size != nil)
                .accessibilityIdentifier("sos.overlay")
                .frame(width: side, height: side)
                .environment(\.sary, m.theme)
                .environment(\.layoutDirection, .leftToRight)
        )
        wanted = m.visible
        applyVisibility()
    }
}
