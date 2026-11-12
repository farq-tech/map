import SwiftUI

/// The new UI's theme choice («متقدم» → الواجهة الجديدة → المظهر): the three designer themes plus «تلقائي».
///  - داكن (dark): the default look, warm dark sand.
///  - نهاري (light): the daylight sand look for direct sun.
///  - خافت (dim): the dim, glare-free look for night driving.
///  - تلقائي (auto): dim at night while driving (after sunset AND moving), dark otherwise.
/// Pure and testable: the same `resolve` feeds the app root and the unit tests.
enum SaryThemeChoice: String, CaseIterable, Identifiable {
    case auto, dark, light, dim

    static let key = "sary.newUI.theme"
    static let argument = "-SaryNewUITheme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "تلقائي"
        case .dark: return "داكن"
        case .light: return "نهاري"
        case .dim: return "خافت"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "خافت بالليل وانت تسوق، وداكن غير كذا."
        case .dark: return "الشكل الأساسي."
        case .light: return "فاتح وواضح تحت الشمس المباشرة."
        case .dim: return "هادي للعين وقت السواقة بالليل."
        }
    }

    /// Which colour scheme and whether the dim (night) palette applies.
    func resolve(autoNight: Bool, driving: Bool) -> (scheme: ColorScheme, night: Bool) {
        switch self {
        case .auto: return (.dark, autoNight && driving)
        case .dark: return (.dark, false)
        case .light: return (.light, false)
        case .dim: return (.dark, true)
        }
    }

    /// DEBUG launch arguments: `-SaryNewUITheme auto|dark|light|dim` wins; otherwise the older
    /// `-SaryScheme` / `-SaryNight` pins keep working for the existing UI tests.
    static func fromArguments(_ args: [String]) -> SaryThemeChoice? {
        func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if let v = arg(argument) { return SaryThemeChoice(rawValue: v) }
        if arg("-SaryNight") == "1" { return .dim }
        switch arg("-SaryScheme") {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}
