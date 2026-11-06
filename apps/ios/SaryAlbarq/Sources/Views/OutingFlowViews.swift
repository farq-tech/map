import SwiftUI

/// The one big button at the bottom of the live screen (ux/الطلعة-والمشوار.md): its label
/// follows the outing's state — «ابدأ الطلعة» → «وين رايحين؟» → «ابدأ المشوار» → «وصلنا» / «أنهِ الطلعة».
/// Members waiting for the leader see a calm, non-tappable «بانتظار أمير الرحلة يبدأ».
struct OutingPrimaryCTA: View {
    var ui: OutingFlowUI
    var tapped: (OutingCTA) -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: 8) {
            if let m = ui.arrivalMoment {
                Text(m)
                    .font(.sary(15, .heavy))
                    .foregroundStyle(p.textPrimary)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .saryGlass(Capsule(), role: .chrome)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityIdentifier("flow.moment")
            }
            if let c = ui.primary {
                HStack(spacing: 8) {
                    if c == .waitLeader {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(c.title).font(.sary(16, .bold)).foregroundStyle(p.textPrimary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .saryGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), role: .chrome)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(c.id)
                    } else {
                        Button { tapped(c) } label: {
                            SaryButtonLabel(title: c.title, systemImage: c.systemImage)
                                .font(.sary(18, .heavy))
                                .frame(minHeight: 34)
                        }
                        .buttonStyle(.saryPrimary)
                        .accessibilityIdentifier(c.id)
                    }
                    if let s = ui.secondary {
                        Button { tapped(s) } label: {
                            Image(systemName: s.systemImage).font(.system(size: 18, weight: .bold))
                                .foregroundStyle(p.textPrimary)
                                .frame(width: 54, height: 54)
                                .saryGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), role: .chrome)
                        }
                        .buttonStyle(SaryPressStyle())
                        .accessibilityLabel(Text(s.title))
                        .accessibilityIdentifier(s.id)
                    }
                }
            }
        }
        .animation(theme.animation(.snappy), value: ui)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flow.cta")
    }
}

/// «وين رايحين؟»: the next leg's destination — search any place (the shared place search),
/// earlier places, my saved places, and back to the start.
struct WhereToSheet: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject private var saved = SavedPlacesStore.shared
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                Text("وين رايحين؟").saryText(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(controller.session.view?.iLead == true
                     ? "اختر الوجهة، وبعدها «ابدأ المشوار» للكل. الطلعة تكمل بعد ما توصلون."
                     : "مشوارك أنت بس. وجهة الطلعة يحددها أمير الرحلة.")
                    .saryText(.footnote).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
                Button {
                    controller.modal = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { controller.modal = .plan(.search) }
                } label: { SaryButtonLabel(title: "ابحث عن مكان", systemImage: "magnifyingglass") }
                    .buttonStyle(.sary(.secondary))
                    .accessibilityIdentifier("whereTo.search")
                let recent = RecentPlaces.load()
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
                        if let d = distance(r.0) { Text(d).saryNumber(.caption).foregroundStyle(p.textTertiary) }
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
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: 0) {
            Text("سجل الطلعة").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
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
        if let d = l.distance_m, d > 0 { parts.append(SaryFormat.distance(meters: Double(d))) }
        if let s = l.duration_s { parts.append(SaryFormat.duration(seconds: s)) }
        else if l.isActive, let st = l.startedDate { parts.append(SaryFormat.duration(seconds: max(0, Int(now.timeIntervalSince(st))))) }
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
                OutingLegTimeline(legs: legs)
                    .padding(.vertical, theme.space(.s))
            }
            .accessibilityIdentifier("summary.legs")
        }
    }
}
