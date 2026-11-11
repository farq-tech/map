import SwiftUI

/// The one primary button of the live screen (ux/الطلعة-والمشوار.md): its label follows the
/// outing's state — «ابدأ الطلعة» → «وين رايحين؟» → «ابدأ المشوار» → «وصلنا». ONE at a time.
/// Stopped, it is the big one (the walkie-talkie shrinks to a round button beside it); driving,
/// it is `compact` and the walkie-talkie is the big one. Members waiting for the leader see a
/// calm «ننتظر أمير الطلعة» (the one waiting message; a tap refreshes the outing's state).
struct OutingPrimaryCTA: View {
    var ui: OutingFlowUI
    var compact = false
    var tapped: (OutingCTA) -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        if let c = ui.primary {
            Group {
                if c == .waitLeader {
                    /* Calm (not accent): nothing to do but wait; a tap asks the server again. */
                    Button { tapped(c) } label: {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title).font(.sary(compact ? 14 : 16, .bold)).foregroundStyle(p.textPrimary)
                                    .lineLimit(1).minimumScaleFactor(0.8)
                                /* Build 36 item 9: the leader's presence and «الأصدقاء» under the message
                                 * (stopped only; the compact pill keeps one line). */
                                if !compact, let w = ui.waiting {
                                    HStack(spacing: 4) {
                                        Circle().fill(w.connection != nil ? p.warning : w.leaderOnline ? p.live : p.textTertiary)
                                            .frame(width: 7, height: 7)
                                        Text(w.line).font(.sary(12, .medium))
                                            .foregroundStyle(w.connection != nil ? p.warningText : p.textSecondary)
                                            .lineLimit(1).minimumScaleFactor(0.75)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, ui.waiting != nil && !compact ? 6 : 0)
                        .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 48 : 56)
                        .saryGlass(Capsule(), role: .chrome)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(ui.waiting.map { "\(c.title)، \($0.accessibility)" } ?? c.title))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("يحدّث حالة الطلعة"))
                } else if compact {
                    Button { tapped(c) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: c.systemImage).font(.system(size: 16, weight: .heavy))
                                .contentTransition(.symbolEffect(.replace))
                            Text(c.title).font(.sary(15, .heavy)).lineLimit(1)
                        }
                        .foregroundStyle(p.onAccent)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .background(Capsule().fill(p.accent))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(SaryPressStyle())
                    .contentShape(Capsule())
                    .accessibilityIdentifier(c.id)
                } else {
                    Button { tapped(c) } label: {
                        SaryButtonLabel(title: c.title, systemImage: c.systemImage)
                            .font(.sary(18, .heavy))
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.saryPrimary)
                    .contentShape(Capsule())
                    .accessibilityIdentifier(c.id)
                }
            }
            .accessibilityIdentifier(c.id)
            /* A new state morphs the same button: the title cross-morphs and the width follows
             * (the dock animates its layout on the same change, `LiveOutingScreen`). */
            .contentTransition(theme.reduceMotion ? .opacity : .interpolate)
            .transition(SaryTransition.appear(theme))
            .animation(theme.animation(LiveMotion.primaryMorph(drive: theme.drive)), value: ui)
        }
    }
}

/// «وين رايحين؟»: the next leg's destination — search any place (the shared place search),
/// earlier places, my saved places, and back to the start.
struct WhereToSheet: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject private var saved = SavedPlacesStore.shared
    @Environment(\.sary) private var theme
    /// Loaded on appear (not in `body`, which re-runs on every location fix), refreshed when renamed.
    @State private var recent: [OutingDestination] = []

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                Text("وين رايحين؟").saryText(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(controller.session.view?.iLead == true
                     ? "اختر الوجهة، وبعدها «ابدأ المشوار» للكل. الطلعة تكمل بعد ما توصلون."
                     : "مشوارك أنت بس. وجهة الطلعة يحددها أمير الطلعة.")
                    .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    /* A direct swap: `sheet(item:)` replaces the presented sheet when the item's identity
                     * changes (no nil → 0.35 s → reopen flicker). */
                    controller.modal = .plan(.search)
                } label: { SaryButtonLabel(title: "ابحث عن مكان", systemImage: "magnifyingglass") }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("whereTo.search")
                if !recent.isEmpty {
                    section("أماكن سابقة", recent.map { ($0, "clock.arrow.circlepath") })
                }
                if !saved.places.isEmpty {
                    section("أماكني", saved.places.map { (OutingDestination(name: $0.name, lat: $0.lat, lng: $0.lng), "mappin") })
                }
                if let s = controller.trip.record.groupStart ?? controller.trip.record.start {
                    section("الرجعة", [(OutingDestination(name: "نقطة البداية", lat: s.lat, lng: s.lng), "house.fill")])
                }
            }
            .padding(theme.space(.l))
        }
        .onAppear { recent = RecentPlaces.load() }
        .onReceive(NotificationCenter.default.publisher(for: .saryRecentPlacesChanged)) { _ in
            recent = RecentPlaces.load()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("whereTo.sheet")
    }

    private func section(_ title: String, _ rows: [(OutingDestination, String)]) -> some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 0) {
            Text(title).saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary).padding(.bottom, 4)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                if i > 0 { SaryDivider() }
                Button { controller.pickLegDestination(r.0) } label: {
                    HStack(spacing: theme.space(.m)) {
                        Image(systemName: r.1).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.accentText).frame(width: 24)
                        Text(r.0.name).saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                        Spacer()
                        if let d = distance(r.0) { Text(d).saryNumber(.caption).foregroundStyle(p.textSecondary) }
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("whereTo.place")
            }
        }
    }

    private func distance(_ d: OutingDestination) -> String? {
        guard let f = controller.location.lastFix else { return nil }
        return SaryFormat.distance(meters: Vehicle.distanceMeters(LngLat(lng: f.lng, lat: f.lat), LngLat(lng: d.lng, lat: d.lat)))
    }
}

/// «سجل الطلعة»: every leg, in order, with when and how far.
struct OutingLegTimeline: View {
    var legs: [OutingLeg]
    var now: Date = Date()
    /// Off where a section already titles it («المشاوير» in the summary).
    var showsTitle = true
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                Text("سجل الطلعة").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 6)
            }
            if legs.isEmpty {
                Text("ما فيه مشاوير بعد. «وين رايحين؟» تبدأ أول مشوار.")
                    .saryText(.subhead).foregroundStyle(p.textSecondary)
            }
            ForEach(Array(legs.enumerated()), id: \.element.id) { i, l in
                HStack(alignment: .top, spacing: theme.space(.m)) {
                    VStack(spacing: 0) {
                        Circle().fill(l.isActive ? p.live : p.accent).frame(width: 10, height: 10).padding(.top, 5)
                        if i < legs.count - 1 { Rectangle().fill(p.separator).frame(width: 2).frame(maxHeight: .infinity) }
                    }
                    .frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LegText.title(l)).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                        Text(LegText.detail(l, now: now)).saryText(.caption).foregroundStyle(p.textSecondary)
                    }
                    .padding(.bottom, 10)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("legs.row")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("legs.timeline")
    }
}

/// The words for one leg (unit-tested in OutingFlowTests).
enum LegText {
    static func title(_ l: OutingLeg) -> String {
        switch l.state {
        case .active: return "في الطريق إلى \(l.destination.name)"
        case .arrived: return "وصلنا \(l.destination.name)"
        case .ended, .cancelled: return "إلى \(l.destination.name) (ما كمل)"
        }
    }

    static func detail(_ l: OutingLeg, now: Date) -> String {
        var parts: [String] = []
        if let s = l.startedDate {
            parts.append(l.arrivedDate.map { "\(NavText.clock(s)) ← \(NavText.clock($0))" } ?? NavText.clock(s))
        }
        /* Only real numbers: no «٠ م», no «٠ د». */
        if let d = l.distance_m, d >= 50 { parts.append(SaryFormat.distance(meters: Double(d))) }
        let secs = l.duration_s ?? (l.isActive ? l.startedDate.map { Int(now.timeIntervalSince($0)) } : nil)
        if let s = secs, s >= 60 { parts.append(SaryFormat.duration(seconds: s)) }
        if l.scope == .personal { parts.append("مشواري") }
        return parts.joined(separator: " · ")
    }
}

/// The summary's «المشاوير»: all legs of the outing.
struct TripLegsSection: View {
    let outingId: String
    @Environment(\.sary) private var theme

    var body: some View {
        let legs = OutingLegsCenters.storedTimeline(outingId)
        if !legs.isEmpty {
            SarySection(title: "المشاوير (\(SaryFormat.number(legs.count)))", footer: nil) {
                OutingLegTimeline(legs: legs, showsTitle: false)
                    .padding(.vertical, theme.space(.s))
            }
            .accessibilityIdentifier("summary.legs")
        }
    }
}
