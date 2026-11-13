import SwiftUI
import UIKit

/// Owner's Build 48 report: during guidance no map control answered while the screen looked normal — a presentation left in a
/// state the person cannot see (an invisible container over the map). This looks at the presentation chain of the app window and
/// (1) logs every change of it in DEBUG (`SARY-SHEET`), (2) dismisses a presented controller on top of the chain that nothing asked for
/// and that cannot be seen (zero alpha / no size / no window), which is exactly what swallows touches without showing anything.
@MainActor
enum SheetWatchdog {
    private static var lastChain = ""

    /// The chain from the window's root: the live screen, the dock, whatever the dock presented.
    static func chain() -> [UIViewController] {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard let root = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return [] }
        var out: [UIViewController] = [root]
        while let next = out.last?.presentedViewController { out.append(next) }
        return out
    }

    /// `wanted`: whether the app itself has something presented on top of the dock right now (a modal, settings, share…).
    /// Returns true when it dismissed a stray.
    @discardableResult
    static func check(dockUp: Bool, appWantsOnTop: Bool) -> Bool {
        let c = chain()
        #if DEBUG
        let desc = c.map { vc -> String in
            let v = vc.viewIfLoaded
            return "\(type(of: vc))(a=\(v.map { String(format: "%.2f", $0.alpha) } ?? "-"),w=\(v?.window != nil),sz=\(v.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "-"),dis=\(vc.isBeingDismissed),pres=\(vc.isBeingPresented))"
        }.joined(separator: " > ")
        if desc != lastChain { lastChain = desc; NSLog("SARY-SHEET chain: %@ | dockUp=%d top=%d", desc, dockUp ? 1 : 0, appWantsOnTop ? 1 : 0) }
        #endif
        guard dockUp, !appWantsOnTop, c.count >= 3, let top = c.last, !top.isBeingDismissed, !top.isBeingPresented else { return false }
        let v = top.viewIfLoaded
        let invisible = v == nil || v!.window == nil || v!.alpha < 0.01 || v!.bounds.width < 1 || v!.bounds.height < 1
        guard invisible else { return false }
        NSLog("SARY-SHEET stray invisible presentation %@ over the dock: dismissing", "\(type(of: top))")
        top.dismiss(animated: false)
        return true
    }
}
