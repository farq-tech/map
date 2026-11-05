import SwiftUI

/// One entry of the «+» sheet.
struct LiveActionItem: Identifiable, Equatable {
    var id: String
    var title: String
    var systemImage: String
    /// Kept from the old control cluster / «المزيد» menu (UI tests and VoiceOver users rely on them).
    var accessibilityID: String
    var subtitle: String?
    var isActive = false
}

struct LiveActionGroup: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var items: [LiveActionItem]
}

/// «+»: every less frequent action of the live screen, grouped (docs/IA-REDESIGN.md §2.3).
enum LiveActionCatalog {
    struct State: Equatable {
        var backTracking = false
        var following = false
        var hasRoute = true
        var stuck = false
        /// The trip ended: only what still makes sense on this phone (map, search, weather…).
        var ended = false
        /// The leader: «وجّه الكل إلى …» (start / re-send guidance for everyone).
        var guideAllTarget: String?
        /// «المحادثات» only when the server has it (an older server: hidden, see ChatStore.availability).
        var chat = true
    }

    /// Entries that only make sense while the outing runs (they reach the group, or the group's channel).
    static let needsRunningTrip: Set<String> = ["note", "stuck", "waypoint", "youtube", "follow", "guideAll"]

    static func groups(_ s: State) -> [LiveActionGroup] {
        let all = [
            LiveActionGroup(title: "الطريق", items: [
                .init(id: "navigate", title: "ملاحة", systemImage: SaryIcon.directions, accessibilityID: "outing-navigate",
                      subtitle: "لواحد من العيال، للوجهة أو لنقطة التجمع"),
            ] + (s.guideAllTarget.map { t in
                [LiveActionItem(id: "guideAll", title: "وجّه الكل إلى \(t)", systemImage: "location.north.line.fill", accessibilityID: "outing-guide-all",
                                subtitle: "يبدأ التوجيه على جوال كل عضو · يقدر كل واحد يوقفه عنده")]
            } ?? []) + [
                .init(id: "search", title: "ابحث أو إحداثية", systemImage: "magnifyingglass", accessibilityID: "outing-search"),
                .init(id: "backtrack", title: s.backTracking ? "أنهِ طريق الرجعة" : "طريق الرجعة", systemImage: SaryIcon.backTrack,
                      accessibilityID: "outing-backtrack", subtitle: s.backTracking ? nil : "ارجع من نفس مسارك", isActive: s.backTracking),
                .init(id: "follow", title: s.following ? "أوقف اتباع الخطة" : "اتبع الخطة",
                      systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", accessibilityID: "plan.follow",
                      subtitle: s.hasRoute ? nil : "ارسم المسار في الخطة أولًا", isActive: s.following),
            ]),
            LiveActionGroup(title: "المجموعة", items: (s.chat ? [
                LiveActionItem(id: "chat", title: "المحادثات", systemImage: "bubble.left.and.bubble.right.fill", accessibilityID: "outing-chat",
                               subtitle: "دردشة الطلعة ورسائل خاصة"),
            ] : []) + [
                .init(id: "note", title: "رسالة فوق سيارتي", systemImage: SaryIcon.note, accessibilityID: "outing-note-open"),
                .init(id: "stuck", title: s.stuck ? "أنا مغرّز · التفاصيل" : "غرّزت", systemImage: SafetyIcon.stuck,
                      accessibilityID: "outing-stuck", isActive: s.stuck),
                .init(id: "waypoint", title: "أضف نقطة", systemImage: "mappin.and.ellipse", accessibilityID: "outing-waypoint-add"),
                .init(id: "copyme", title: "انسخ أو شارك موقعي", systemImage: "location.viewfinder", accessibilityID: "outing-copyme"),
            ]),
            LiveActionGroup(title: "الخريطة", items: [
                .init(id: "explore", title: "استكشاف", systemImage: "binoculars.fill", accessibilityID: "outing-explore",
                      subtitle: "الطبقات، التضاريس، الإحداثيات، أماكني، GPX، بلا إنترنت"),
            ]),
            LiveActionGroup(title: "الخدمات", items: [
                .init(id: "nearest", title: "أقرب محطة", systemImage: SaryIcon.nearest, accessibilityID: "outing-nearest-open"),
                .init(id: "weather", title: "الطقس", systemImage: "cloud.sun.fill", accessibilityID: "outing-weather"),
            ]),
            LiveActionGroup(title: "الترفيه", items: [
                .init(id: "radio", title: "إذاعة الطلعة", systemImage: "dot.radiowaves.left.and.right", accessibilityID: "outing-radio",
                      subtitle: "للكل، والشاشة مقفلة، وفي السيارة"),
                .init(id: "youtube", title: "يوتيوب", systemImage: "play.rectangle.fill", accessibilityID: "outing-youtube",
                      subtitle: "والتطبيق مفتوح فقط"),
            ]),
        ]
        guard s.ended else { return all }
        return all.compactMap { g in
            var g = g
            g.items.removeAll { needsRunningTrip.contains($0.id) }
            return g.items.isEmpty ? nil : g
        }
    }
}

struct LiveActionSheet: View {
    var groups: [LiveActionGroup]
    var action: (String) -> Void
    var close: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.l)) {
                HStack {
                    Text("أدوات الطلعة").saryText(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "outing-actions-close", action: close)
                }
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: theme.space(.xs)) {
                        Text(g.title).saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, theme.space(.xs))
                        VStack(spacing: 0) {
                            ForEach(Array(g.items.enumerated()), id: \.element.id) { i, item in
                                row(item)
                                if i < g.items.count - 1 { SaryDivider().padding(.leading, 56) }
                            }
                        }
                        .padding(.horizontal, theme.space(.m))
                        .sarySurface(radius: SaryRadius.l)
                    }
                }
            }
            .padding(theme.space(.l))
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outing-actions-sheet")
    }

    private func row(_ item: LiveActionItem) -> some View {
        let p = theme.palette
        return Button { action(item.id) } label: {
            HStack(spacing: theme.space(.m)) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.isActive ? p.onAccent : p.accentText)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(item.isActive ? p.accent : p.accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                    if let s = item.subtitle {
                        Text(s).saryText(.footnote).foregroundStyle(p.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryRowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(item.accessibilityID)
    }
}
