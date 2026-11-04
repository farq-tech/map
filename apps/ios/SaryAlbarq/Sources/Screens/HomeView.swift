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
}

/// «طلعاتي»: my outings by state (جارية / متوقفة / لم تبدأ), the latest ended
/// ones, an empty state that says what to do, and honest offline / error states.
struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance
    @State private var path: [HomeRoute] = []
    @State private var creating = false
    @State private var joining = false

    init(initial: [HomeRoute] = []) { _path = State(initialValue: initial) }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: HomeRoute.self) { route in
                    destination(route)
                        .navigationBarBackButtonHidden(true)
                }
        }
        .sheet(isPresented: $creating) { CreateOutingWizard().saryPresented(appearance) }
        .onAppear(perform: openPendingSummary)
        .onChange(of: model.pendingSummary) { _, _ in openPendingSummary() }
        .sheet(isPresented: $joining) { JoinByLinkSheet().saryPresented(appearance) }
    }

    /// «ملخص الرحلة» pressed on the live map after the end.
    private func openPendingSummary() {
        guard let id = model.pendingSummary else { return }
        model.pendingSummary = nil
        path = [.summary(id)]
    }

    @ViewBuilder
    private func destination(_ r: HomeRoute) -> some View {
        let pop = { if !path.isEmpty { path.removeLast() } }
        switch r {
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
        }
    }

    private var content: some View {
        let p = theme.palette
        let me = model.identity?.user
        return SaryPage(title: "طلعاتي", subtitle: me.map { "أهلًا \($0.display_name)" }) {
            HStack(spacing: theme.space(.s)) {
                SaryIconButton(systemImage: SaryIcon.settings, label: "الإعدادات", id: "home.settings") { path.append(.settings) }
                Button { path.append(.profile) } label: {
                    SaryAvatar(name: me?.display_name ?? "؟", color: theme.accent.fill, photo: AvatarCodec.image(from: me?.avatar), size: 38)
                }
                .buttonStyle(SaryPressStyle())
                .accessibilityLabel(Text("ملفي"))
                .accessibilityIdentifier("home.profile")
            }
        } content: {
            if !model.online { SaryOfflineStrip() }
            /* ONE primary action; joining is a quiet link under it (docs/IA-REDESIGN.md §2.7). */
            VStack(spacing: 2) {
                Button { creating = true } label: { SaryButtonLabel(title: "طلعة جديدة", systemImage: "plus") }
                    .buttonStyle(.sary(.primary))
                    .accessibilityIdentifier("list.create")
                Button { joining = true } label: { Label("عندك رابط دعوة؟ انضم", systemImage: "link") }
                    .buttonStyle(.sary(.plain, compact: true))
                    .accessibilityIdentifier("list.join")
            }
            switch model.listPhase {
            case .loading where model.current.isEmpty && model.history.isEmpty:
                VStack(spacing: 0) { ForEach(0..<3, id: \.self) { _ in SarySkeletonRow() } }
                    .sarySurface(radius: SaryRadius.m)
            case .failed(let m) where model.current.isEmpty && model.history.isEmpty:
                SaryStateView(kind: model.online ? .error(title: "تعذّر تحميل طلعاتك", message: m) : .offline(message: "طلعاتك تظهر أول ما يرجع الاتصال."),
                              actionTitle: "حاول مرة ثانية", actionID: "home.retry") { Task { await model.refresh() } }
                    .sarySurface(radius: SaryRadius.l)
            default:
                if model.current.isEmpty && model.history.isEmpty {
                    SaryStateView(kind: .empty(title: "ما عندك طلعات بعد", message: "أنشئ طلعة وأرسل رابطها لأصحابك، أو افتح رابط دعوة وصلك.", systemImage: "car.2.fill"))
                        .sarySurface(radius: SaryRadius.l)
                        .accessibilityIdentifier("home.empty")
                }
                if let live = activeOuting {
                    ActiveOutingCard(o: live, open: { model.open(live.id) }, details: { path.append(.details(live.id)) })
                }
                let others = sortedCurrent.filter { $0.id != activeOuting?.id }
                if !others.isEmpty {
                    section(activeOuting == nil ? "طلعاتك" : "طلعات ثانية", ids: "home.current") {
                        VStack(spacing: 0) {
                            ForEach(others) { o in
                                OutingCard(o: o, open: { model.open(o.id) }, details: { path.append(.details(o.id)) }, compact: true)
                                if o.id != others.last?.id { SaryDivider().padding(.leading, 56) }
                            }
                        }
                        .sarySurface(radius: SaryRadius.m)
                    }
                }
                if !model.history.isEmpty {
                    section("انتهت مؤخرًا", ids: "home.history") {
                        VStack(spacing: 0) {
                            let recent = Array(model.history.prefix(3))
                            ForEach(recent) { o in
                                OutingCard(o: o, open: { path.append(.summary(o.id)) }, details: nil, compact: true)
                                if o.id != recent.last?.id { SaryDivider().padding(.leading, 56) }
                            }
                        }
                        .sarySurface(radius: SaryRadius.m)
                        if model.history.count > 3 {
                            Button("كل الطلعات السابقة (\(SaryFormat.number(model.history.count)))") { path.append(.history) }
                                .buttonStyle(.sary(.plain))
                                .accessibilityIdentifier("home.allHistory")
                        }
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
    }

    /// The outing happening now (the big card on top): the first active one.
    private var activeOuting: OutingSummary? { sortedCurrent.first { $0.status == .active } }

    /// Active first, then paused, then not started.
    private var sortedCurrent: [OutingSummary] {
        let rank: [OutingStatus: Int] = [.active: 0, .paused: 1, .created: 2, .ended: 3]
        return model.current.sorted { (rank[$0.status] ?? 9) < (rank[$1.status] ?? 9) }
    }

    private func section<C: View>(_ title: String, ids: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            Text(title).saryText(.footnote, weight: .bold).foregroundStyle(theme.palette.textSecondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: theme.space(.s)) { c() }
        }
        .accessibilityIdentifier(ids)
    }
}

/// The outing happening now, on top of «طلعاتي»: big, one clear «افتح الخريطة».
struct ActiveOutingCard: View {
    let o: OutingSummary
    var open: () -> Void
    var details: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack(alignment: .top, spacing: theme.space(.m)) {
                ZStack {
                    RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous).fill(p.live.opacity(0.16))
                    Image(systemName: "car.2.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(p.liveText)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    SaryOutingStatusPill(status: o.status)
                    Text(o.name).saryText(.title2).foregroundStyle(p.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(o.participantsLabel).saryText(.footnote).foregroundStyle(p.textSecondary)
                        if o.role == "owner" {
                            Image(systemName: SaryIcon.crown).font(.system(size: 10)).foregroundStyle(p.warningText)
                                .accessibilityLabel(Text("صاحب الطلعة"))
                        }
                        OutingRowWeather(outingId: o.id)
                    }
                }
                Spacer(minLength: 0)
                SaryIconButton(systemImage: "info", label: "تفاصيل \(o.name)", id: "outing-details", action: details)
            }
            Button(action: open) { SaryButtonLabel(title: "افتح الخريطة", systemImage: "map.fill") }
                .buttonStyle(.sary(.primary))
                .accessibilityIdentifier("outing-row")
                .accessibilityHint(Text("يفتح الخريطة"))
        }
        .padding(theme.space(.l))
        .sarySurface(radius: SaryRadius.l)
        .overlay(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(p.live.opacity(0.45), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.active")
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
                                Image(systemName: SaryIcon.crown).font(.system(size: 10)).foregroundStyle(p.warningText)
                                    .accessibilityLabel(Text("صاحب الطلعة"))
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
        SaryPage(title: "الطلعات السابقة", back: back) {
            if model.history.isEmpty {
                SaryStateView(kind: .empty(title: "لا توجد طلعات منتهية", message: "تظهر هنا بعد ما تنتهي الطلعة.", systemImage: "flag.checkered"))
            }
            VStack(spacing: theme.space(.s)) {
                ForEach(model.history) { o in OutingCard(o: o, open: { open(o.id) }, details: nil) }
            }
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
                        Image(systemName: "flag.checkered").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
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
