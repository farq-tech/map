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
        /* The app window's real inset (0 on an iPhone SE, 34 with a home indicator); was a fixed
         * 34 pt whenever no key window was found, which floated the disc 34 pt high on an SE. */
        let others = windowScene?.windows.filter { $0 !== self } ?? []
        let safeBottom = (others.first(where: \.isKeyWindow) ?? others.first)?.safeAreaInsets.bottom ?? safeAreaInsets.bottom
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

// MARK: - A friend's SOS (UI-AUDIT 0.1)

/// A friend's SOS covers everything, always. It used to be a `.fullScreenCover` on the live sheet,
/// the same view that presents the sheets (`modal`), the settings page, the share sheet and the
/// dialogs: SwiftUI presents one thing at a time from a view, so with any of those up the alert
/// silently did not appear. In its own window (like the floating SOS above) nothing holds it back.
/// The controller also clears what covers the map when it arrives
/// (`LiveOutingController.clearCoversForIncomingSOS`), so «أظهره على الخريطة» lands on the map.
struct FriendSOSAlertHost: UIViewRepresentable {
    /// The newest friend's SOS not acknowledged yet (nil: nothing to show).
    var alert: IncomingSOSUI?
    var theme: SaryTheme
    var show: (String) -> Void
    var call: (String) -> Void

    func makeUIView(context: Context) -> UIView { FriendSOSAnchorView() }

    func updateUIView(_ v: UIView, context: Context) {
        guard let anchor = v as? FriendSOSAnchorView else { return }
        anchor.model = .init(alert: alert, theme: theme, show: show, call: call)
    }

    static func dismantleUIView(_ v: UIView, coordinator: ()) {
        (v as? FriendSOSAnchorView)?.tearDown()
    }
}

/// Finds the window scene once in a window, then owns the alert's window for it.
final class FriendSOSAnchorView: UIView {
    struct Model {
        var alert: IncomingSOSUI?
        var theme: SaryTheme
        var show: (String) -> Void
        var call: (String) -> Void
    }

    var model: Model? { didSet { apply() } }
    private var overlay: FriendSOSAlertWindow?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { tearDown() } else { apply() }
    }

    func tearDown() {
        overlay?.close()
        overlay = nil
    }

    private func apply() {
        guard let model, let scene = window?.windowScene else { return }
        if overlay == nil { overlay = FriendSOSAlertWindow(windowScene: scene) }
        overlay?.update(model)
    }
}

/// The whole screen, over every sheet and the floating SOS (`.alert - 1`); my own SOS countdown
/// (`.alert + 1`) stays above it. Hidden (and empty) while there is no unacknowledged alert.
final class FriendSOSAlertWindow: UIWindow {
    private let host = UIHostingController(rootView: AnyView(EmptyView()))

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        rootViewController = host
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ m: FriendSOSAnchorView.Model) {
        guard let a = m.alert else {
            close()
            return
        }
        let id = a.id
        host.rootView = AnyView(
            SaryFriendSOSAlert(alert: a, now: Date(), show: { m.show(id) }, call: { m.call(id) })
                .id(id)
                .accessibilityIdentifier("friend-sos-alert")
                .saryTheme(m.theme)
        )
        guard isHidden else { return }
        isHidden = false
        /* VoiceOver moves to the alert at once (the sheets beneath are not where the person is). */
        UIAccessibility.post(notification: .screenChanged, argument: host.view)
    }

    func close() {
        guard !isHidden else { return }
        isHidden = true
        /* Emptied, so the next alert appears fresh (its buzz and pulse start on appear). */
        host.rootView = AnyView(EmptyView())
    }
}
