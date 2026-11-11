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
                    infoRow(SaryIcon.crown, "أمير الطلعة", s.members.first { $0.user_id == s.outing.owner_id }?.display_name ?? "—")
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
                PlanDetailsSections(snapshot: s, plan: model.plans.model(outingId))
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
                    DetailsWeatherSection(snapshot: s, myFix: model.location.lastFix, plan: model.plans.model(outingId))
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
    @Environment(AppearanceSettings.self) private var appearance
    @State private var phase: SnapshotPhase = .loading
    @State private var busy = false
    @State private var shareText: String?
    @State private var story: StoryFacts?
    /// Build 10: my trail as a precise, followable track (built once, off the body).
    @State private var track: FollowSubject?
    /// One cover for both (two `.fullScreenCover`s on one view do not both present).
    @State private var trackCover: TrackCover?

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
                    if let sp = model.mySpeed(outingId) {
                        /* On this device only: never in the shared summary or the share text. */
                        stat("speedometer", "أعلى سرعة", SaryFormat.speed(kmh: sp.maxKmh))
                        stat("car.side.fill", "متوسط السرعة أثناء الحركة", SaryFormat.speed(kmh: sp.avgMovingKmh))
                    }
                }
                .accessibilityIdentifier("summary.stats")
                if let facts = model.tripFacts(outingId) {
                    TripSummarySection(facts: facts, snapshot: s, destination: model.plans.model(outingId).plan.destination,
                                       trail: model.myTrailPoints(outingId), online: model.online || model.isDemo)
                }
                TripLegsSection(outingId: outingId)
                /* A solo outing (docs/SOLO-OUTING.md): on this phone only — no shared points, nobody's
                 * summaries, nothing to share with friends, no server return trip (yet). */
                if !solo {
                    TripWaypointsSection(outingId: outingId, outingName: s.outing.name)
                    SarySection(title: "ملخصات شاركها الأصدقاء", footer: "كل واحد يشارك مجاميعه فقط (المسافة والوقت)، لا المسار ولا النقاط.") {
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
                }
                if let track {
                    SarySection(title: "مساري", footer: "مرسوم من جوالك فقط، بلون السرعة. ما نرسله لأحد، وما يدخل في «شارك ملخصي».") {
                        TrackSummaryCard(subject: track, trail: model.myTrailPoints(outingId), online: model.online || model.isDemo,
                                         open: { trackCover = .detail(track) }, follow: { trackCover = TrackFollowModel(track).map(TrackCover.follow) })
                            .padding(.vertical, theme.space(.s))
                    }
                } else if let trail = model.myTrailPoints(outingId), trail.points.count >= 2 {
                    SarySection(title: "مساري", footer: "مرسوم من جوالك فقط. ما نرسله لأحد، وما يدخل في «شارك ملخصي».") {
                        TrailSketch(trail: trail, color: theme.palette.accent)
                            .saryFitHeight(180)
                            .padding(.vertical, theme.space(.s))
                            .accessibilityIdentifier("summary.trail")
                    }
                }
                if s.outing.status == .ended {
                    Button { story = storyFacts(s, mine: mine, local: local) } label: {
                        SaryButtonLabel(title: "اصنع قصة الطلعة", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.sary(.primary))
                    .accessibilityIdentifier("summary.story")
                    if !solo { mySummary(mine: mine, local: local, endedAt: ISODate.parse(s.outing.ended_at)) }
                    if !solo, model.tripFacts(outingId)?.start != nil || (model.myTrailPoints(outingId)?.points.count ?? 0) >= 2 {
                        Button {
                            busy = true
                            Task {
                                if await model.startReturnTrip(from: outingId) == nil { busy = false }
                            }
                        } label: { SaryButtonLabel(title: SaryCopy.returnOuting, systemImage: SaryIcon.backTrack, busy: busy) }
                            .buttonStyle(.sary(.secondary))
                            .accessibilityIdentifier("summary.returnTrip")
                        Text("«طلعة الرجعة» طلعة جديدة من الوجهة إلى نقطة بدايتك: على مسارك المسجّل أو بالملاحة.")
                            .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button {
                    shareText = text(s, mine: mine, local: local)
                } label: { SaryButtonLabel(title: "شارك الملخص كنص", systemImage: SaryIcon.share) }
                    .buttonStyle(.sary(.secondary))
            }
        }
        .task { await load() }
        .task(id: subtitle) {
            guard track == nil, let name = subtitle else { return }
            track = await model.trackSubject(outingId, name: name)
        }
        .sheet(item: Binding(get: { shareText.map(ShareText.init) }, set: { if $0 == nil { shareText = nil } })) { t in
            ShareSheet(items: [t.text]).presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: Binding(get: { story.map(StorySheet.init) }, set: { if $0 == nil { story = nil } })) { st in
            StoryComposerView(facts: st.facts) { story = nil }
                .saryPresented(appearance)
        }
        .background {
            /* Its own host view: a second `.fullScreenCover` on the same view would never present. */
            Color.clear.fullScreenCover(item: $trackCover) { c in
                switch c {
                case let .detail(s):
                    TrackDetailView(subject: s, close: { trackCover = nil }) { chosen in
                        trackCover = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { trackCover = TrackFollowModel(chosen).map(TrackCover.follow) }
                    }
                    .saryPresented(appearance)
                case let .follow(m):
                    TrackFollowScreen(model: m) { trackCover = nil }
                        .saryPresented(appearance)
                }
            }
        }
    }

    /// What «قصة الطلعة» may say: the outing's totals, my trail from this device, and only a count of the others.
    private func storyFacts(_ s: OutingSnapshot, mine: TripShare?, local: TripTotals?) -> StoryFacts {
        let trail = model.storyTrail(outingId)
        var len = 0.0
        for i in trail.indices.dropFirst() where !trail[i].gap { len += Vehicle.distanceMeters(trail[i - 1].position, trail[i].position) }
        return StoryFacts(outingName: s.outing.name, startedAt: ISODate.parse(s.outing.started_at), endedAt: ISODate.parse(s.outing.ended_at),
                          distanceM: mine?.distance_m ?? local.map { Double($0.distanceM) } ?? (len > 0 ? len : nil),
                          durationS: spanSeconds(s), movingS: mine.map { Int($0.moving_s) } ?? local?.movingS,
                          memberCount: s.members.count,
                          companionNames: s.members.filter { $0.user_id != s.me.user_id }.map(\.display_name),
                          trail: trail, waypoints: model.storyWaypoints(outingId))
    }

    @ViewBuilder
    private func mySummary(mine: TripShare?, local: TripTotals?, endedAt: Date?) -> some View {
        let open = endedAt.map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false
        SarySection(title: "ملخصي", footer: "محسوب على جوالك من مشاركتك فقط. يبقى عندك إلا إذا اخترت مشاركته مع أصدقاء الطلعة (خلال أسبوع من نهايتها).") {
            VStack(alignment: .leading, spacing: theme.space(.s)) {
                if mine != nil {
                    Label("شاركت ملخصك مع الأصدقاء", systemImage: SaryIcon.checkCircle).saryText(.subhead, weight: .bold).foregroundStyle(theme.palette.liveText)
                    Button {
                        busy = true
                        Task { if await model.withdrawSummary(outingId) { await load() }; busy = false }
                    } label: { SaryButtonLabel(title: "اسحب ملخصي", busy: busy) }
                        .buttonStyle(.sary(.plainDestructive))
                } else if local == nil {
                    Text("ما شاركت موقعك في هذه الطلعة من هذا الجوال، فما فيه ملخص لك.").saryText(.subhead).foregroundStyle(theme.palette.textSecondary)
                } else if !open {
                    Text("مضى أكثر من أسبوع على نهاية الطلعة؛ يبقى ملخصك على جوالك فقط.").saryText(.subhead).foregroundStyle(theme.palette.textSecondary)
                } else {
                    Button {
                        busy = true
                        Task { if await model.shareSummary(outingId) != nil { await load() }; busy = false }
                    } label: { SaryButtonLabel(title: "شارك ملخصي مع الأصدقاء", systemImage: "square.and.arrow.up.on.square", busy: busy) }
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

    /// A solo outing («اتجه» on my own): its summary is on this phone only.
    private var solo: Bool { SoloOuting.isSoloId(outingId) }

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

/// «مساري» in the summary (build 10): the track on clean satellite imagery, coloured by speed,
/// with the three big numbers and «اسلك هذا المسار» on a dark card at its foot. Offline: the
/// tile-free sketch instead of the imagery (the numbers and the button still work).
struct TrackSummaryCard: View {
    var subject: FollowSubject
    var trail: Trail?
    var online: Bool
    var open: () -> Void
    var follow: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                if online {
                    TrackMapView(line: subject.line, interactive: false)
                } else if let trail, trail.points.count >= 2 {
                    TrailSketch(trail: trail, color: theme.palette.accent)
                }
                Button(action: open) {
                    Label("كبّر", systemImage: "arrow.up.left.and.arrow.down.right")
                        .saryText(.caption, weight: .bold)
                        .padding(.horizontal, theme.space(.s)).padding(.vertical, 6)
                }
                .foregroundStyle(theme.palette.textPrimary)
                .saryGlass(Capsule(), role: .control, interactive: true)
                .padding(theme.space(.s))
                .accessibilityIdentifier("summary.trackOpen")
            }
            .saryFitHeight(300)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            TrackStatsCard(stats: subject.stats, speedLegend: subject.line.hasSpeeds, follow: follow)
                .padding(.top, -28)
                .padding(.horizontal, theme.space(.s))
        }
        .clipShape(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summary.trail")
    }
}

/// My trail drawn small, offline (no map tiles): recorded runs solid, unrecorded stretches dashed,
/// «نقطة البداية» and the end marked.
struct TrailSketch: View {
    var trail: Trail
    var color: Color
    @Environment(\.sary) private var theme

    var body: some View {
        GeometryReader { g in
            let pts = trail.points
            let ref = pts[0].position
            let xy = pts.map { TrailGeo.xy($0.position, ref: ref) }
            let minX = xy.map(\.x).min()!, maxX = xy.map(\.x).max()!
            let minY = xy.map(\.y).min()!, maxY = xy.map(\.y).max()!
            let pad: CGFloat = 18
            let w = g.size.width - pad * 2, h = g.size.height - pad * 2
            let span = max(maxX - minX, maxY - minY, 1)
            let k = min(w, h) / CGFloat(span)
            let ox = pad + (w - CGFloat(maxX - minX) * k) / 2, oy = pad + (h - CGFloat(maxY - minY) * k) / 2
            /* North up, east right — a map, so it is not mirrored in RTL. */
            let screen = xy.map { CGPoint(x: ox + CGFloat($0.x - minX) * k, y: oy + CGFloat(maxY - $0.y) * k) }
            ZStack {
                RoundedRectangle(cornerRadius: SaryRadius.m).fill(theme.palette.sunken)
                Path { path in
                    for (i, p) in screen.enumerated() {
                        if i == 0 || pts[i].gap { path.move(to: p) } else { path.addLine(to: p) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                Path { path in
                    for i in pts.indices where i > 0 && pts[i].gap {
                        path.move(to: screen[i - 1])
                        path.addLine(to: screen[i])
                    }
                }
                .stroke(color.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 6]))
                Circle().fill(Color(rgb: 0x16110B)).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2.5))
                    .position(screen[0])
                Circle().fill(color).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2.5))
                    .position(screen[screen.count - 1])
                Text("نقطة البداية").saryText(.micro, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(theme.palette.chromeOpaque))
                    .position(x: min(max(screen[0].x, 44), g.size.width - 44), y: max(screen[0].y - 16, 10))
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("رسم مسارك: \(SaryFormat.distance(meters: trail.recordedLengthM)) مسجّلة"))
    }
}

private enum TrackCover: Identifiable {
    case detail(FollowSubject)
    case follow(TrackFollowModel)

    var id: String {
        switch self {
        case let .detail(s): return "detail:\(s.id)"
        case let .follow(m): return "follow:\(m.id)"
        }
    }
}

private struct StorySheet: Identifiable {
    let facts: StoryFacts
    var id: String { facts.outingName }
}

private struct ShareText: Identifiable {
    let text: String
    var id: String { text }
}

/// «الرحلة» in the summary: from my start point to the destination, the clock (moving,
/// stopped, the longest stop), the route on the map and who arrived when. All from this
/// phone; the shared summaries above are the only thing other members ever see.
struct TripSummarySection: View {
    var facts: TripSummaryFacts
    var snapshot: OutingSnapshot
    var destination: OutingDestination?
    var trail: Trail?
    var online: Bool
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let m = facts.motion
        SarySection(title: "مشواري", footer: "من أول موقع لك بعد بداية الطلعة إلى \(facts.arrivedAt != nil ? "وصولك" : "نهايتها"). محسوب على جوالك فقط.") {
            VStack(alignment: .leading, spacing: theme.space(.s)) {
                row("flag.fill", "البداية", facts.start.map { NavText.clock(Date(timeIntervalSince1970: $0.atMs / 1000)) } ?? "—")
                SaryDivider()
                row("flag.checkered", facts.arrivedAt != nil ? "الوصول إلى \(destination?.name ?? "الوجهة")" : "النهاية",
                    (facts.arrivedAt ?? facts.endedAt).map { NavText.clock($0) } ?? "—")
                SaryDivider()
                row("clock.fill", "مدة المشوار", SaryFormat.duration(seconds: m.elapsedS))
                SaryDivider()
                row("car.side.fill", "وقت الحركة", SaryFormat.duration(seconds: m.movingS))
                SaryDivider()
                row("pause.circle.fill", "وقت الوقوف", SaryFormat.duration(seconds: m.stoppedS))
                if let l = m.longestStopS {
                    SaryDivider()
                    row("hourglass", "أطول وقفة", SaryFormat.duration(seconds: l))
                }
                if let a = m.avgMovingKmh {
                    SaryDivider()
                    row("speedometer", "متوسط السرعة · أعلى سرعة", SaryFormat.speed(kmh: a) + (m.maxKmh.map { " · " + SaryFormat.speed(kmh: $0) } ?? ""))
                }
            }
            .padding(.vertical, theme.space(.xs))
            .accessibilityIdentifier("summary.trip")
        }
        if let route = routeLine, route.count >= 2 {
            SarySection(title: "من البداية إلى النهاية", footer: "مرسوم من مسارك على جوالك فقط.") {
                Group {
                    if online {
                        PlanMapView(route: route, destination: destination, interactive: false,
                                    camera: PlanCamera(kind: .fit(route + (destination.map { [LngLat(lng: $0.lng, lat: $0.lat)] } ?? [])), id: 1), theme: theme)
                    } else if let trail {
                        TrailSketch(trail: trail, color: p.accent)
                    }
                }
                .saryFitHeight(200)
                .clipShape(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous))
                .padding(.vertical, theme.space(.s))
                .accessibilityIdentifier("summary.route")
            }
        }
        let names = snapshot.members.map { (id: $0.user_id, name: $0.user_id == snapshot.me.user_id ? "\($0.display_name) (أنت)" : $0.display_name) }
        let order = ArrivalOrder.split(arrivals: facts.arrivals, members: names)
        if !order.arrived.isEmpty {
            SarySection(title: "ترتيب الوصول", footer: "كما رآه جوالك من مواقعهم المباشرة.") {
                VStack(spacing: 0) {
                    ForEach(Array(order.arrived.enumerated()), id: \.element.id) { i, e in
                        if i > 0 { SaryDivider() }
                        HStack(spacing: theme.space(.m)) {
                            Text(SaryFormat.number(i + 1)).saryNumber(.headline, weight: .heavy).foregroundStyle(i == 0 ? p.accentText : p.textTertiary).frame(width: 22)
                            Text(e.name).saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                            Spacer()
                            Text(NavText.clock(Date(timeIntervalSince1970: e.atMs / 1000))).saryNumber(.subhead).foregroundStyle(p.textSecondary)
                        }
                        .frame(minHeight: theme.minTarget)
                    }
                    if !order.waiting.isEmpty {
                        SaryDivider()
                        Text("ما وصلوا (أو ما وصلنا موقعهم): " + order.waiting.joined(separator: "، "))
                            .saryText(.footnote).foregroundStyle(p.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, theme.space(.s))
                    }
                }
                .accessibilityIdentifier("summary.arrivalOrder")
            }
        }
    }

    /// My trail from the start point on, thinned for the map.
    private var routeLine: [LngLat]? {
        guard let t = trail else { return nil }
        let from = facts.start?.atMs ?? 0
        let pts = t.points.filter { $0.t >= from - 1000 }.map(\.position)
        return PlanSimplify.capped(pts, max: 600)
    }

    private func row(_ icon: String, _ k: String, _ v: String) -> some View {
        HStack(spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: icon)
            Text(k).saryText(.body).foregroundStyle(theme.palette.textSecondary).lineLimit(2)
            Spacer()
            Text(v).saryNumber(.body, weight: .bold).foregroundStyle(theme.palette.textPrimary)
        }
        .frame(minHeight: theme.minTarget)
        .accessibilityElement(children: .combine)
    }
}
