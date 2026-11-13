import SwiftUI

/// Pages pushed from «طلعاتي».
enum HomeRoute: Hashable {
    case details(String)
    case summary(String)
    case history
    case profile
    case settings
    case recoveryCode
    case appearance
    case privacy
    case deleteAccount
    case notifications
    case offlineMaps
    case about
    case advanced
    case convoyAlerts
    case blocked
    /// «مفضلتك»: البيت، الشغل and the saved places.
    case favorites
}

/// The home: the map with its sheet; every other page is pushed from there.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance
    @State private var path: [HomeRoute] = []

    init(initial: [HomeRoute] = []) { _path = State(initialValue: initial) }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: HomeRoute.self) { route in
                    destination(route)
                        .navigationBarBackButtonHidden(true)
                }
        }
        .onAppear(perform: openPendingSummary)
        .onChange(of: model.pendingSummary) { _, _ in openPendingSummary() }
    }

    /// «ملخص الرحلة» pressed on the live map after the end.
    private func openPendingSummary() {
        guard let id = model.pendingSummary else { return }
        model.pendingSummary = nil
        path = [.summary(id)]
    }

    @ViewBuilder
    private func destination(_ r: HomeRoute) -> some View {
        HomeRouteDestination(route: r, path: $path)
    }

    /// The map first (UX simplification, after Hudhud's flow): search, categories, shortcuts and
    /// «طلعاتي» live in the home map's sheet (Sources/Home/MapHomeScreen.swift).
    private var content: some View {
        MapHomeScreen(push: { path.append($0) })
            .toolbar(.hidden, for: .navigationBar)
            .task { await model.refresh() }
    }
}

/// One outing in «طلعاتي».
struct OutingCard: View {
    let o: OutingSummary
    var open: () -> Void
    var details: (() -> Void)?
    /// A row inside a grouped list (no card of its own).
    var compact = false
    @Environment(\.sary) private var theme

    var body: some View {
        if NewUI.enabled { newRow } else { legacyRow }
    }

    /// Build 47 (`NewUI`) list row: icon on the right, the name (shrinks instead of «…»), status + people, time + weather,
    /// a disclosure chevron that points the Arabic way, one fixed minimum height; «تفاصيل» keeps its info button.
    private var newRow: some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.s)) {
            Button(action: open) {
                HStack(spacing: theme.space(.m)) {
                    Image(systemName: o.status == .ended ? "flag.checkered" : (o.status == .active ? "car.2.fill" : "car.2"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(o.status == .active ? p.liveText : p.textSecondary)
                        .frame(width: SaryMetrics.iconCircle, height: SaryMetrics.iconCircle)
                        .background(Circle().fill(o.status == .active ? p.live.opacity(0.16) : p.sunken))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(o.name).saryType(.body, weight: .bold).foregroundStyle(p.textPrimary)
                            .saryLongName(lines: 2, minScale: 0.75).multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            SaryOutingStatusPill(status: o.status)
                            Text(o.participantsLabel).saryType(.caption).foregroundStyle(p.textSecondary)
                            if o.role == "owner" {
                                Image(systemName: SaryIcon.crown).saryGlyph(10).foregroundStyle(p.warningText)
                                    .accessibilityLabel(Text("أمير الطلعة"))
                            }
                        }
                        HStack(spacing: 6) {
                            if let t = o.timeLabel() { Text(t).saryType(.caption).foregroundStyle(p.textTertiary) }
                            if o.status != .ended { OutingRowWeather(outingId: o.id) }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(p.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: SaryMetrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(SaryRowPressStyle())
            .accessibilityIdentifier("outing-row")
            .accessibilityHint(Text(o.status == .ended ? "يفتح ملخص الطلعة" : "يفتح الخريطة"))
            if let details {
                SaryIconButton(systemImage: "info", label: "تفاصيل \(o.name)", id: "outing-details", action: details)
            }
        }
        .padding(compact ? theme.space(.s) : theme.space(.m))
        .background {
            if !compact {
                RoundedRectangle(cornerRadius: SaryRadius.control, style: .continuous).fill(p.surface)
                    .overlay(RoundedRectangle(cornerRadius: SaryRadius.control, style: .continuous).strokeBorder(p.stroke, lineWidth: 1))
            }
        }
    }

    @ViewBuilder private var legacyRow: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.m)) {
            Button(action: open) {
                HStack(spacing: theme.space(.m)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous)
                            .fill(o.status == .active ? p.live.opacity(0.16) : p.sunken)
                        Image(systemName: o.status == .ended ? "flag.checkered" : (o.status == .active ? "car.2.fill" : "car.2"))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(o.status == .active ? p.liveText : p.textSecondary)
                    }
                    .frame(width: compact ? 40 : 48, height: compact ? 40 : 48)
                    VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                        Text(o.name).saryText(.headline).foregroundStyle(p.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            SaryOutingStatusPill(status: o.status)
                            Text(o.participantsLabel).saryText(.footnote).foregroundStyle(p.textSecondary)
                            if o.role == "owner" {
                                Image(systemName: SaryIcon.crown).saryGlyph(10).foregroundStyle(p.warningText)
                                    .accessibilityLabel(Text("أمير الطلعة"))
                            }
                        }
                        HStack(spacing: 6) {
                            if let t = o.timeLabel() {
                                Text(t).saryText(.caption).foregroundStyle(p.textTertiary)
                            }
                            if o.status != .ended { OutingRowWeather(outingId: o.id) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(SaryRowPressStyle())
            .accessibilityIdentifier("outing-row")
            .accessibilityHint(Text(o.status == .ended ? "يفتح ملخص الطلعة" : "يفتح الخريطة"))
            if let details {
                SaryIconButton(systemImage: "info", label: "تفاصيل \(o.name)", id: "outing-details", action: details)
            }
        }
        .padding(compact ? theme.space(.s) : theme.space(.m))
        .modifier(CardSurface(on: !compact))
    }
}

private struct CardSurface: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.sarySurface(radius: SaryRadius.m) } else { content }
    }
}

/// All ended outings.
struct HistoryView: View {
    var back: () -> Void
    var open: (String) -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme

    var body: some View {
        if NewUI.enabled {
            NewUIPage(title: "الطلعات السابقة", back: back) { rows }
        } else {
            SaryPage(title: "الطلعات السابقة", back: back) { rows }
        }
    }

    @ViewBuilder private var rows: some View {
        if model.history.isEmpty {
            if NewUI.enabled {
                SaryScreenState(kind: .empty, systemImage: "flag.checkered", message: "ما فيه طلعات منتهية. تظهر هنا بعد ما تنتهي الطلعة.", actionTitle: nil)
            } else {
                SaryStateView(kind: .empty(title: "ما فيه طلعات منتهية", message: "تظهر هنا بعد ما تنتهي الطلعة.", systemImage: "flag.checkered"))
            }
        }
        VStack(spacing: theme.space(.s)) {
            ForEach(model.history) { o in OutingCard(o: o, open: { open(o.id) }, details: nil) }
        }
    }
}

/// The destination's weather on an outing row (only when the outing has one; plan loaded lazily).
private struct OutingRowWeather: View {
    let outingId: String
    @EnvironmentObject private var model: AppModel

    var body: some View { Inner(plan: model.plans.model(outingId)) }

    private struct Inner: View {
        @ObservedObject var plan: PlanModel
        var body: some View {
            Group {
                if let d = plan.plan.destination {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.checkered").saryGlyph(9, weight: .bold).accessibilityHidden(true)
                        DestinationWeatherBadge(destination: d)
                    }
                } else {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            .task { if plan.planPhase == .loading { await plan.loadPlan() } }
        }
    }
}

/// The page behind a `HomeRoute`: shared by the home's stack and the idle map's profile flow (EM3).
struct HomeRouteDestination: View {
    let route: HomeRoute
    @Binding var path: [HomeRoute]
    /// The idle map's profile flow hands a chosen favourite to the map itself; the legacy home goes through `HomePlaceRequest`.
    var choosePlace: ((OutingDestination) -> Void)? = nil

    var body: some View {
        let pop = { if !path.isEmpty { path.removeLast() } }
        switch route {
        case .details(let id): OutingDetailsView(outingId: id, back: pop)
        case .summary(let id): TripSummaryView(outingId: id, back: pop)
        case .history: HistoryView(back: pop, open: { path.append(.summary($0)) })
        case .profile: ProfileView(back: pop, open: { path.append($0) })
        case .settings: SettingsView(back: pop, open: { path.append($0) })
        case .recoveryCode: RecoveryCodeScreen(back: pop)
        case .appearance: AppearanceScreen(back: pop)
        case .privacy: PrivacySettingsView(back: pop, open: { path.append($0) })
        case .deleteAccount: DeleteAccountView(back: pop)
        case .notifications: NotificationSettingsView(back: pop)
        case .offlineMaps: OfflineMapsView(back: pop)
        case .about: AboutView(back: pop)
        case .advanced: AdvancedSettingsView(back: pop)
        case .convoyAlerts: ConvoyAlertSettingsView(back: pop)
        case .blocked: BlockedUsersView(back: pop)
        case .favorites:
            FavoritesView(back: pop, choose: { d, subtitle, icon in
                if let choosePlace { choosePlace(d); return }
                path.removeAll()
                HomePlaceRequest.post(d, subtitle: subtitle, icon: icon)
            })
        }
    }
}

/// A place chosen on another page (the favourites) that the home map should show: posted here, picked up by
/// `MapHomeScreen` once the route stack has popped back to it.
enum HomePlaceRequest {
    static let name = Notification.Name("sary.home.placeRequest")
    static func post(_ d: OutingDestination, subtitle: String, icon: String) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["dest": d, "subtitle": subtitle, "icon": icon])
    }
}
