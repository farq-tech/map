import SwiftUI

// MARK: - Launch hook (compiled in all configs, does nothing outside DEBUG)

extension View {
    /// Attach to the app's root view. In DEBUG builds launched with the
    /// `-SaryShowcase` argument it replaces the app UI with the Design
    /// Showcase; otherwise it returns the view untouched.
    ///
    /// Optional launch arguments (UserDefaults argument domain):
    ///   -SaryShowcaseSection <id>   open a section directly (see `ShowcaseSection`)
    ///   -SaryShowcaseScheme light|dark
    ///   -SaryShowcaseNight 1        -SaryShowcaseDrive 1
    ///   -SaryShowcaseFallback 1     force the iOS 17–25 material fallback on iOS 26+
    ///   -SaryShowcaseType <size>    xSmall…xxxLarge, AX1…AX5
    ///   -SaryShowcaseScroll <n>     scroll the section to block n
    ///   -SaryShowcaseSheet peek|half|full   (map stage) present the sheet
    ///   -SaryShowcaseBare 1         hide the showcase's own toolbar (clean shots)
    @ViewBuilder
    func saryShowcaseIfRequested() -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SaryShowcase") {
            SaryShowcaseRoot()
        } else if ProcessInfo.processInfo.arguments.contains("-SaryFoundations") {
            SaryFoundationsPreview()
        } else if ProcessInfo.processInfo.arguments.contains("-SaryComponents") {
            SaryComponentsGallery()
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG

enum ShowcaseSection: String, CaseIterable, Identifiable, Hashable {
    case tokens, buttons, controls, status, alerts, sos, ptt, sheet, participants, rally, overlays, states, inputs, dialogs, appearance, stage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: return "الأساسيات"
        case .buttons: return "الأزرار"
        case .controls: return "أزرار الخريطة"
        case .status: return "شريط الحالة"
        case .alerts: return "مسار التنبيهات"
        case .sos: return "الطوارئ"
        case .ptt: return "اضغط وتكلم"
        case .sheet: return "الورقة السفلية"
        case .participants: return "المشاركون"
        case .rally: return "التجمع والمحطات"
        case .overlays: return "على الخريطة"
        case .states: return "الحالات"
        case .inputs: return "الإدخال"
        case .dialogs: return "التأكيد"
        case .appearance: return "التخصيص"
        case .stage: return "مسرح الخريطة"
        }
    }

    var icon: String {
        switch self {
        case .tokens: return "swatchpalette.fill"
        case .buttons: return "rectangle.fill"
        case .controls: return "square.stack.3d.up.fill"
        case .status: return "capsule.fill"
        case .alerts: return "bell.badge.fill"
        case .sos: return SaryIcon.sos
        case .ptt: return SaryIcon.mic
        case .sheet: return "rectangle.bottomhalf.filled"
        case .participants: return "person.2.fill"
        case .rally: return SaryIcon.rally
        case .overlays: return "map.fill"
        case .states: return "tray.fill"
        case .inputs: return "character.cursor.ibeam"
        case .dialogs: return "exclamationmark.bubble.fill"
        case .appearance: return "paintbrush.fill"
        case .stage: return "car.2.fill"
        }
    }
}

/// Showcase-wide switches. Everything goes through a real `AppearanceSettings`
/// (in its own UserDefaults suite) so the showcase exercises the real system.
@Observable
final class ShowcaseLab {
    let settings: AppearanceSettings
    var typeSize: DynamicTypeSize
    var bare: Bool
    var scrollTarget: Int?
    var sheet: SheetDetentUI?
    var initialSection: ShowcaseSection?

    init() {
        let d = UserDefaults.standard
        let suite = UserDefaults(suiteName: "sary.showcase") ?? .standard
        settings = AppearanceSettings(defaults: suite)
        settings.prefs = AppearancePreferences()
        switch d.string(forKey: "SaryShowcaseScheme") {
        case "light": settings.prefs.colorScheme = .light
        case "dark": settings.prefs.colorScheme = .dark
        default: settings.prefs.colorScheme = .dark
        }
        settings.prefs.nightMode = d.bool(forKey: "SaryShowcaseNight") ? .on : .off
        settings.prefs.driveMode = d.bool(forKey: "SaryShowcaseDrive") ? .on : .off
        settings.forceGlassFallback = d.bool(forKey: "SaryShowcaseFallback")
        typeSize = Self.parseType(d.string(forKey: "SaryShowcaseType")) ?? .large
        bare = d.bool(forKey: "SaryShowcaseBare")
        scrollTarget = d.object(forKey: "SaryShowcaseScroll") != nil ? d.integer(forKey: "SaryShowcaseScroll") : nil
        sheet = d.string(forKey: "SaryShowcaseSheet").flatMap { s in SheetDetentUI.allCases.first { "\($0)" == s } }
        initialSection = d.string(forKey: "SaryShowcaseSection").flatMap(ShowcaseSection.init(rawValue:))
    }

    static func parseType(_ s: String?) -> DynamicTypeSize? {
        switch s {
        case "xSmall": return .xSmall
        case "small": return .small
        case "medium": return .medium
        case "large": return .large
        case "xLarge": return .xLarge
        case "xxLarge": return .xxLarge
        case "xxxLarge": return .xxxLarge
        case "AX1": return .accessibility1
        case "AX2": return .accessibility2
        case "AX3": return .accessibility3
        case "AX4": return .accessibility4
        case "AX5": return .accessibility5
        default: return nil
        }
    }

    var modeSummary: String {
        var s: [String] = [settings.isNight ? "ليلي" : (settings.prefs.colorScheme == .light ? "نهاري" : "داكن")]
        if settings.isDriving { s.append("قيادة") }
        s.append(settings.forceGlassFallback ? "بديل ١٧" : "زجاج ٢٦")
        if typeSize != .large { s.append("نص \(typeSize.shortLabel)") }
        return s.joined(separator: " · ")
    }
}

extension DynamicTypeSize {
    var shortLabel: String {
        switch self {
        case .xSmall: return "XS"
        case .small: return "S"
        case .medium: return "M"
        case .large: return "L"
        case .xLarge: return "XL"
        case .xxLarge: return "XXL"
        case .xxxLarge: return "XXXL"
        case .accessibility1: return "AX1"
        case .accessibility2: return "AX2"
        case .accessibility3: return "AX3"
        case .accessibility4: return "AX4"
        case .accessibility5: return "AX5"
        @unknown default: return "?"
        }
    }
}

struct SaryShowcaseRoot: View {
    @State private var lab = ShowcaseLab()
    @State private var path: [ShowcaseSection] = []

    var body: some View {
        ShowcaseThemed(lab: lab) {
            NavigationStack(path: $path) {
                ShowcaseIndex(lab: lab)
                    .navigationDestination(for: ShowcaseSection.self) { section in
                        ShowcaseSectionView(section: section, lab: lab)
                    }
            }
        }
        .onAppear {
            if let s = lab.initialSection, path.isEmpty { path = [s] }
        }
    }
}

/// Applies the lab's Dynamic Type size and the appearance system.
struct ShowcaseThemed<Content: View>: View {
    var lab: ShowcaseLab
    @ViewBuilder var content: Content
    var body: some View {
        content
            .saryAppearance(lab.settings)
            .dynamicTypeSize(lab.typeSize)
    }
}

private struct ShowcaseIndex: View {
    var lab: ShowcaseLab
    @Environment(\.sary) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.l)) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("سَرى البارق").saryText(.display).foregroundStyle(theme.palette.textPrimary)
                    Text("نظام التصميم · iOS").saryText(.callout).foregroundStyle(theme.palette.textSecondary)
                }
                ShowcaseLabBar(lab: lab)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(ShowcaseSection.allCases) { s in
                        NavigationLink(value: s) {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: s.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(s == .sos ? theme.palette.emergencyText : theme.palette.accentText)
                                Text(s.title).saryText(.headline).foregroundStyle(theme.palette.textPrimary)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(theme.space(.l))
                            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                            .sarySurface(radius: SaryRadius.m)
                        }
                        .buttonStyle(SaryPressStyle())
                        .accessibilityIdentifier("showcase-\(s.rawValue)")
                    }
                }
            }
            .padding(theme.space(.l))
        }
        .background(theme.palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Quick switches shown at the top of every page (hidden with -SaryShowcaseBare).
struct ShowcaseLabBar: View {
    @Bindable var lab: ShowcaseLab
    @Environment(\.sary) private var theme

    var body: some View {
        let s = lab.settings
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(s.prefs.colorScheme == .light ? "نهاري" : "داكن", icon: s.prefs.colorScheme == .light ? "sun.max.fill" : "moon.fill", on: true) {
                    s.prefs.colorScheme = s.prefs.colorScheme == .light ? .dark : .light
                }
                chip("ليلي", icon: SaryIcon.night, on: s.isNight) { s.prefs.nightMode = s.isNight ? .off : .on }
                chip("قيادة", icon: SaryIcon.drive, on: s.isDriving) { s.prefs.driveMode = s.isDriving ? .off : .on }
                chip("بديل ١٧", icon: "square.on.square.dashed", on: s.forceGlassFallback) { s.forceGlassFallback.toggle() }
                Menu {
                    ForEach(DynamicTypeSize.allCases, id: \.self) { size in
                        Button(size.shortLabel) { lab.typeSize = size }
                    }
                } label: {
                    chipLabel("نص \(lab.typeSize.shortLabel)", icon: "textformat.size", on: lab.typeSize != .large)
                }
            }
            .padding(.vertical, 2)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func chip(_ title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(title, icon: icon, on: on) }.buttonStyle(SaryPressStyle())
    }

    private func chipLabel(_ title: String, icon: String, on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
            Text(title).saryText(.footnote, weight: .bold)
        }
        .foregroundStyle(on ? theme.palette.onAccent : theme.palette.textSecondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(on ? theme.palette.accent : theme.palette.sunken))
    }
}

/// One section page: header with lab bar, then the blocks.
struct ShowcaseSectionView: View {
    var section: ShowcaseSection
    var lab: ShowcaseLab
    @Environment(\.sary) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if section == .stage {
            MapStage(lab: lab, close: { dismiss() })
                .toolbar(.hidden, for: .navigationBar)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: theme.space(.xxl)) {
                        if !lab.bare {
                            ShowcaseLabBar(lab: lab)
                        }
                        ShowcaseBlocks(section: section, lab: lab)
                    }
                    .padding(.horizontal, theme.space(.l))
                    .padding(.bottom, 40)
                }
                .onAppear {
                    if let t = lab.scrollTarget {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { proxy.scrollTo("block-\(t)", anchor: .top) }
                    }
                }
            }
            .background(theme.palette.background.ignoresSafeArea())
            .navigationTitle(section.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(section.title).saryText(.headline).foregroundStyle(theme.palette.textPrimary)
                        Text(lab.modeSummary).saryText(.micro, weight: .medium).foregroundStyle(theme.palette.textTertiary)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                }
            }
            .toolbarBackground(theme.palette.background, for: .navigationBar)
        }
    }
}

/// A titled demo block.
struct ShowcaseBlock<Content: View>: View {
    var index: Int
    var title: String
    var note: String?
    @ViewBuilder var content: Content
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).saryText(.title2).foregroundStyle(theme.palette.textPrimary)
                if let note {
                    Text(note).saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                }
            }
            content
        }
        .id("block-\(index)")
    }
}

/// A strip of procedural terrain to judge chrome over the map.
struct ShowcaseMapStrip<Content: View>: View {
    var height: CGFloat = 220
    var alignment: Alignment = .center
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: alignment) {
            DesertTerrainView()
            content.padding(14)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous))
    }
}
#endif
