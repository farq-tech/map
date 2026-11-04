import SwiftUI

/// Loading state for a page that reads one outing from the server.
enum SnapshotPhase: Equatable {
    case loading
    case loaded(OutingSnapshot)
    case failed(String)
}

/// An outing before (or instead of) opening the live map: state, who is in it,
/// when it started, the invite (owner), and «غادر الطلعة».
struct OutingDetailsView: View {
    let outingId: String
    var back: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var phase: SnapshotPhase = .loading
    @State private var confirmLeave = false
    @State private var leaving = false
    @State private var share: URL?

    var body: some View {
        let p = theme.palette
        SaryPage(title: title, back: back) {
            switch phase {
            case .loading:
                SaryStateView(kind: .loading("نجيب تفاصيل الطلعة…"))
            case .failed(let m):
                SaryStateView(kind: model.online ? .error(title: "تعذّر التحميل", message: m) : .offline(message: nil),
                              actionTitle: "حاول مرة ثانية", actionID: "details.retry") { Task { await load() } }
            case .loaded(let s):
                HStack(spacing: theme.space(.s)) {
                    SaryOutingStatusPill(status: s.outing.status)
                    if s.me.role == "owner" { SaryRoleChip(role: .leader) } else if s.me.co_leader == true { SaryRoleChip(role: .coLeader) }
                    Spacer()
                }
                SarySection(title: "الطلعة") {
                    infoRow("person.2.fill", "المشاركون", SaryFormat.number(s.members.count))
                    SaryDivider()
                    infoRow(SaryIcon.crown, "صاحب الطلعة", s.members.first { $0.user_id == s.outing.owner_id }?.display_name ?? "—")
                    if let d = ISODate.parse(s.outing.started_at) {
                        SaryDivider()
                        infoRow("clock", "بدأت", SaryFormat.elapsed(since: d, now: Date()))
                    } else if let d = ISODate.parse(s.outing.created_at) {
                        SaryDivider()
                        infoRow("clock", "أُنشئت", SaryFormat.elapsed(since: d, now: Date()))
                    }
                    if s.outing.join_locked == true {
                        SaryDivider()
                        infoRow("lock.fill", "الانضمام", "مقفول")
                    }
                }
                let colors = CarColors.assign(s.members)
                SarySection(title: "من في الطلعة") {
                    ForEach(Array(s.members.enumerated()), id: \.element.user_id) { i, m in
                        if i > 0 { SaryDivider() }
                        HStack(spacing: theme.space(.m)) {
                            SaryAvatar(name: m.display_name, color: colors[m.user_id] ?? CarColors.palette[i % CarColors.palette.count], photo: AvatarCodec.image(from: m.avatar), size: 36)
                            Text(m.user_id == s.me.user_id ? "\(m.display_name) (أنت)" : m.display_name)
                                .saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                            Spacer()
                            if m.user_id == s.outing.owner_id { SaryRoleChip(role: .leader) } else if m.co_leader == true { SaryRoleChip(role: .coLeader) }
                        }
                        .padding(.vertical, theme.space(.xs))
                    }
                }
                if s.outing.status != .ended {
                    DetailsWeatherSection(snapshot: s, myFix: model.location.lastFix)
                }
                if s.outing.status != .ended {
                    Button { model.open(outingId) } label: { SaryButtonLabel(title: "افتح الخريطة", systemImage: "map.fill") }
                        .buttonStyle(.sary(.primary))
                        .accessibilityIdentifier("details.open")
                    if s.me.role == "owner", let t = InviteTokenStore.load(outingId) {
                        let u = InviteLink.url(for: t)
                        Button { share = u } label: { SaryButtonLabel(title: "شارك رابط الدعوة", systemImage: SaryIcon.share) }
                            .buttonStyle(.sary(.secondary))
                    }
                } else {
                    Button { back() } label: { SaryButtonLabel(title: "ملخص الطلعة", systemImage: "flag.checkered") }
                        .buttonStyle(.sary(.secondary))
                }
                Button { confirmLeave = true } label: { SaryButtonLabel(title: "غادر الطلعة", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(.sary(.plainDestructive))
                    .accessibilityIdentifier("details.leave")
            }
        }
        .task { await load() }
        .saryDialog($confirmLeave, systemImage: "rectangle.portrait.and.arrow.right", title: "تغادر الطلعة؟",
                    message: "يتوقف إرسال موقعك وتخرج منها. ترجع فقط برابط دعوة جديد.", confirmTitle: "غادر", busy: leaving) {
            leaving = true
            Task {
                if await model.leave(outingId) { confirmLeave = false; back() }
                leaving = false
            }
        }
        .sheet(item: Binding(get: { share.map(ShareTarget.init) }, set: { if $0 == nil { share = nil } })) { s in
            ShareSheet(items: [s.url]).presentationDetents([.medium, .large])
        }
    }

    private var title: String {
        if case .loaded(let s) = phase { return s.outing.name }
        return model.current.first { $0.id == outingId }?.name ?? "تفاصيل الطلعة"
    }

    private func infoRow(_ icon: String, _ k: String, _ v: String) -> some View {
        HStack(spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: icon)
            Text(k).saryText(.body).foregroundStyle(theme.palette.textSecondary)
            Spacer()
            Text(v).saryText(.body, weight: .bold).foregroundStyle(theme.palette.textPrimary)
        }
        .frame(minHeight: theme.minTarget)
    }

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do { phase = .loaded(try await model.snapshot(outingId)) } catch let e as OutingAPIError {
            if case .loaded = phase { return }
            phase = .failed(e.arabic)
        } catch {}
    }
}

struct ShareTarget: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Trip summary

/// After the outing: how long it ran, who took part, the totals members chose to
/// share (never routes), and my own totals from this device with «شارك ملخصي».
struct TripSummaryView: View {
    let outingId: String
    var back: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var phase: SnapshotPhase = .loading
    @State private var busy = false
    @State private var shareText: String?

    var body: some View {
        let p = theme.palette
        SaryPage(title: "ملخص الطلعة", subtitle: subtitle, back: back) {
            switch phase {
            case .loading:
                SaryStateView(kind: .loading("نجهّز الملخص…"))
            case .failed(let m):
                SaryStateView(kind: model.online ? .error(title: "تعذّر التحميل", message: m) : .offline(message: nil),
                              actionTitle: "حاول مرة ثانية", actionID: "summary.retry") { Task { await load() } }
            case .loaded(let s):
                let shares = s.summaries ?? []
                let mine = shares.first { $0.user_id == s.me.user_id }
                let local = model.myTrip(outingId)
                let span = spanSeconds(s)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: theme.space(.s)), GridItem(.flexible(), spacing: theme.space(.s))], spacing: theme.space(.s)) {
                    stat("clock.fill", "مدة الطلعة", span.map { SaryFormat.duration(seconds: $0) } ?? "—")
                    stat("person.2.fill", "المشاركون", SaryFormat.number(s.members.count))
                    stat("road.lanes", "مسافتي", (mine.map { $0.distance_m } ?? local.map { Double($0.distanceM) }).map { SaryFormat.distance(meters: $0) } ?? "—")
                    stat("gauge.with.needle", "وقت الحركة", (mine.map { Int($0.moving_s) } ?? local?.movingS).map { SaryFormat.duration(seconds: $0) } ?? "—")
                }
                .accessibilityIdentifier("summary.stats")
                SarySection(title: "ملخصات شاركها الأعضاء", footer: "كل واحد يشارك مجاميعه فقط (المسافة والوقت)، لا المسار ولا النقاط.") {
                    if shares.isEmpty {
                        Text("ما شارك أحد ملخصه بعد.").saryText(.subhead).foregroundStyle(p.textSecondary).padding(.vertical, theme.space(.s))
                    }
                    ForEach(Array(shares.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { SaryDivider() }
                        HStack(spacing: theme.space(.m)) {
                            Text(SaryFormat.number(i + 1)).saryNumber(.subhead, weight: .bold).foregroundStyle(p.textTertiary).frame(width: 18)
                            Text(t.user_id == s.me.user_id ? "\(t.display_name) (أنت)" : t.display_name).saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(SaryFormat.distance(meters: t.distance_m)).saryNumber(.body, weight: .bold).foregroundStyle(p.textPrimary)
                                Text(SaryFormat.duration(seconds: Int(t.moving_s)) + " حركة").saryText(.caption).foregroundStyle(p.textSecondary)
                            }
                        }
                        .padding(.vertical, theme.space(.xs))
                    }
                }
                if s.outing.status == .ended {
                    mySummary(mine: mine, local: local, endedAt: ISODate.parse(s.outing.ended_at))
                }
                Button {
                    shareText = text(s, mine: mine, local: local)
                } label: { SaryButtonLabel(title: "شارك الملخص كنص", systemImage: SaryIcon.share) }
                    .buttonStyle(.sary(.secondary))
            }
        }
        .task { await load() }
        .sheet(item: Binding(get: { shareText.map(ShareText.init) }, set: { if $0 == nil { shareText = nil } })) { t in
            ShareSheet(items: [t.text]).presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func mySummary(mine: TripShare?, local: TripTotals?, endedAt: Date?) -> some View {
        let open = endedAt.map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false
        SarySection(title: "ملخصي", footer: "محسوب على جوالك من مشاركتك فقط. يبقى عندك إلا إذا اخترت مشاركته مع أعضاء الطلعة (خلال أسبوع من نهايتها).") {
            VStack(alignment: .leading, spacing: theme.space(.s)) {
                if mine != nil {
                    Label("شاركت ملخصك مع أعضاء الطلعة", systemImage: SaryIcon.checkCircle).saryText(.subhead, weight: .bold).foregroundStyle(theme.palette.liveText)
                    Button {
                        busy = true
                        Task { if await model.withdrawSummary(outingId) { await load() }; busy = false }
                    } label: { SaryButtonLabel(title: "اسحب ملخصي", busy: busy) }
                        .buttonStyle(.sary(.plainDestructive))
                } else if local == nil {
                    Text("ما شاركت موقعك في هذه الطلعة من هذا الجهاز، فلا يوجد ملخص لك.").saryText(.subhead).foregroundStyle(theme.palette.textSecondary)
                } else if !open {
                    Text("مضى أكثر من أسبوع على نهاية الطلعة؛ يبقى ملخصك على جوالك فقط.").saryText(.subhead).foregroundStyle(theme.palette.textSecondary)
                } else {
                    Button {
                        busy = true
                        Task { if await model.shareSummary(outingId) != nil { await load() }; busy = false }
                    } label: { SaryButtonLabel(title: "شارك ملخصي مع الأعضاء", systemImage: "square.and.arrow.up.on.square", busy: busy) }
                        .buttonStyle(.sary(.primary))
                        .accessibilityIdentifier("summary.shareMine")
                }
            }
            .padding(.vertical, theme.space(.s))
        }
    }

    private var subtitle: String? {
        if case .loaded(let s) = phase { return s.outing.name }
        return nil
    }

    private func spanSeconds(_ s: OutingSnapshot) -> Int? {
        guard let a = ISODate.parse(s.outing.started_at), let b = ISODate.parse(s.outing.ended_at) ?? (s.outing.status == .ended ? nil : Date()) else { return nil }
        return max(0, Int(b.timeIntervalSince(a)))
    }

    private func stat(_ icon: String, _ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: theme.space(.xs)) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.palette.accentText)
            Text(v).saryNumber(.title2, weight: .bold).foregroundStyle(theme.palette.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            Text(k).saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.m)
        .accessibilityElement(children: .combine)
    }

    private func text(_ s: OutingSnapshot, mine: TripShare?, local: TripTotals?) -> String {
        var lines = ["ملخص «\(s.outing.name)» — سَرى البارق"]
        if let span = spanSeconds(s) { lines.append("المدة: \(SaryFormat.duration(seconds: span))") }
        lines.append("المشاركون: \(SaryFormat.number(s.members.count))")
        if let d = mine?.distance_m ?? local.map({ Double($0.distanceM) }) { lines.append("مسافتي: \(SaryFormat.distance(meters: d))") }
        return lines.joined(separator: "\n")
    }

    private func load() async {
        do { phase = .loaded(try await model.snapshot(outingId)) } catch let e as OutingAPIError {
            if case .loaded = phase { return }
            phase = .failed(e.arabic)
        } catch {}
    }
}

private struct ShareText: Identifiable {
    let text: String
    var id: String { text }
}
