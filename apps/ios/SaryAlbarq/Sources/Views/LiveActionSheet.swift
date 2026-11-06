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
    var tone: Tone = .normal

    enum Tone: Equatable { case normal, emergency }
}

struct LiveActionGroup: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var items: [LiveActionItem]
}

/// «أدوات الطلعة» («+»): every less frequent action of the live screen, as tiles in sections
/// («تخفيف الزحمة» ١٣, styled after the owner's Lovable prototype). Nothing was dropped:
/// «وجّه الكل» and «اتبع الخطة» live in the «الرحلة» tab, «انسخ موقعي» on «أنت».
enum LiveActionCatalog {
    struct State: Equatable {
        var backTracking = false
        var following = false
        var hasRoute = true
        var stuck = false
        /// The trip ended: only what still makes sense on this phone (map, search, weather…).
        var ended = false
        /// The leader: «وجّه الكل إلى …» (start / re-send guidance for everyone) — in «الرحلة» now.
        var guideAllTarget: String?
        /// «المحادثات» only when the server has it (an older server: hidden, see ChatStore.availability).
        var chat = true
        /// «الترددات» only when the server has walkie-talkie channels.
        var channels = false
    }

    /// Entries that only make sense while the outing runs (they reach the group, or the group's channel).
    static let needsRunningTrip: Set<String> = ["note", "stuck", "waypoint", "youtube", "follow", "guideAll", "channels", "enjad",
                                                "rally", "convoy", "timer"]

    /// Lovable's «أدوات الطلعة», tile for tile, in its order. Ours on top of it (never dropped):
    /// «رسالة فوق سيارتي»، «أضف نقطة»، «أقرب محطة»، «شوف الكل».
    static func groups(_ s: State) -> [LiveActionGroup] {
        let all = [
            LiveActionGroup(title: "الطريق", items: [
                .init(id: "navigate", title: "ملاحة", systemImage: "location.north.fill", accessibilityID: "outing-navigate",
                      subtitle: "لواحد من العيال، للوجهة أو لنقطة التجمع"),
                .init(id: "search", title: "ابحث أو إحداثية", systemImage: "magnifyingglass", accessibilityID: "outing-search"),
                .init(id: "backtrack", title: s.backTracking ? "أنهِ طريق الرجعة" : "طريق الرجعة", systemImage: "arrow.uturn.backward",
                      accessibilityID: "outing-backtrack", isActive: s.backTracking),
                .init(id: "follow", title: s.following ? "أوقف المسار" : "اسلك هذا المسار", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                      accessibilityID: "plan.follow", subtitle: s.hasRoute ? "اتبع مسار الخطة" : "ارسم المسار في الخطة أولًا", isActive: s.following),
            ]),
            LiveActionGroup(title: "الجماعة", items: (s.chat ? [
                LiveActionItem(id: "chat", title: "المحادثات", systemImage: "bubble.left.and.bubble.right", accessibilityID: "outing-chat"),
            ] : []) + (s.channels ? [
                LiveActionItem(id: "channels", title: "الترددات", systemImage: "dot.radiowaves.left.and.right", accessibilityID: "outing-ptt-channels"),
            ] : []) + (s.guideAllTarget.map { t in
                [LiveActionItem(id: "guideAll", title: "وجّه العيال لنقطة", systemImage: "scope", accessibilityID: "outing-guide-all",
                                subtitle: "وجّه الكل إلى \(t) · يبدأ التوجيه على جوال كل عضو")]
            } ?? []) + [
                .init(id: "rally", title: "نقطة التجمع", systemImage: "flag", accessibilityID: "outing-rally"),
                .init(id: "convoy", title: "القافلة", systemImage: "box.truck", accessibilityID: "outing-convoy", subtitle: "تنبيهات القافلة"),
                .init(id: "note", title: "رسالة فوق سيارتي", systemImage: SaryIcon.note, accessibilityID: "outing-note-open"),
            ]),
            LiveActionGroup(title: "السلامة", items: [
                .init(id: "stuck", title: s.stuck ? "أنا مغرّز" : "غرّزت", systemImage: "car.side.rear.and.collision.and.car.side.front",
                      accessibilityID: "outing-stuck", isActive: s.stuck, tone: .emergency),
                .init(id: "enjad", title: "اتصل بإنجاد", systemImage: "lifepreserver", accessibilityID: "outing-enjad", tone: .emergency),
                .init(id: "timer", title: "مؤقت الرجوع", systemImage: "timer", accessibilityID: "outing-timer"),
            ]),
            LiveActionGroup(title: "المكان", items: [
                .init(id: "brief", title: "بريف المكان", systemImage: "info.circle", accessibilityID: "outing-brief"),
                .init(id: "savePlace", title: "احفظ مكان", systemImage: "bookmark", accessibilityID: "outing-save-place"),
                .init(id: "weather", title: "طقس", systemImage: "sun.max", accessibilityID: "outing-weather"),
                .init(id: "waypoint", title: "أضف نقطة", systemImage: "mappin.and.ellipse", accessibilityID: "outing-waypoint-add"),
                .init(id: "nearest", title: "أقرب محطة", systemImage: SaryIcon.nearest, accessibilityID: "outing-nearest-open"),
            ]),
            LiveActionGroup(title: "الترفيه", items: [
                .init(id: "radio", title: "إذاعة الطلعة", systemImage: "radio", accessibilityID: "outing-radio"),
                .init(id: "youtube", title: "يوتيوب", systemImage: "play.rectangle", accessibilityID: "outing-youtube", subtitle: "واقفين فقط"),
            ]),
            LiveActionGroup(title: "الخريطة", items: [
                .init(id: "explore", title: "الطبقات", systemImage: "square.3.layers.3d", accessibilityID: "outing-explore"),
                .init(id: "hires", title: "صور عالية الوضوح", systemImage: "sparkles", accessibilityID: "outing-hires"),
                .init(id: "realistic", title: "الوضع الواقعي", systemImage: "mountain.2", accessibilityID: "outing-realistic"),
                .init(id: "effects", title: "المؤثرات", systemImage: "wand.and.stars", accessibilityID: "outing-effects"),
                .init(id: "fit", title: "شوف الكل", systemImage: SaryIcon.fitGroup, accessibilityID: "outing-fit"),
            ]),
        ]
        guard s.ended else { return all }
        return all.compactMap { g in
            var g = g
            g.items.removeAll { needsRunningTrip.contains($0.id) }
            return g.items.isEmpty ? nil : g
        }
    }

    /// What moved out of «+» into the «الرحلة» tab: «اتبع الخطة» and, for the leader, «وجّه الكل».
    static func tripRouteActions(_ s: State) -> [LiveActionItem] {
        guard !s.ended else { return [] }
        return (s.guideAllTarget.map { t in
            [LiveActionItem(id: "guideAll", title: "وجّه الكل إلى \(t)", systemImage: "location.north.line.fill", accessibilityID: "outing-guide-all",
                            subtitle: "يبدأ التوجيه على جوال كل عضو · يقدر كل واحد يوقفه عنده")]
        } ?? []) + [
            .init(id: "follow", title: s.following ? "أوقف اتباع الخطة" : "اتبع الخطة",
                  systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", accessibilityID: "plan.follow",
                  subtitle: s.hasRoute ? nil : "ارسم المسار في الخطة أولًا", isActive: s.following),
        ]
    }
}

struct LiveActionSheet: View {
    var groups: [LiveActionGroup]
    var action: (String) -> Void
    var close: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        /* Tiles fit one screen; the scroll view is only for the largest text sizes. */
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.s)) {
                HStack {
                    Text("أدوات الطلعة").font(.sary(18, .bold)).foregroundStyle(p.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(p.textPrimary)
                            .frame(width: 36, height: 36).background(Circle().fill(p.sunken))
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityLabel(Text("إغلاق"))
                    .accessibilityIdentifier("outing-actions-close")
                }
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(g.title).font(.sary(12, .bold)).foregroundStyle(p.textSecondary)
                            .accessibilityAddTraits(.isHeader)
                            .padding(.horizontal, theme.space(.xs))
                        /* Not lazy: every tile exists (VoiceOver and UI tests reach the ones below the fold). */
                        VStack(spacing: theme.space(.s)) {
                            ForEach(Array(stride(from: 0, to: g.items.count, by: 4)), id: \.self) { i in
                                HStack(spacing: theme.space(.s)) {
                                    ForEach(g.items[i..<min(i + 4, g.items.count)]) { tile($0) }
                                    ForEach(0..<(4 - min(4, g.items.count - i)), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, minHeight: 1) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, theme.space(.l))
            .padding(.vertical, theme.space(.s))
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outing-actions-sheet")
    }

    /// Lovable tile: 80×78, 24 pt corners, the icon in orange (red for safety), an 11 pt label.
    private func tile(_ item: LiveActionItem) -> some View {
        let p = theme.palette
        let red = item.tone == .emergency
        let ink = red ? p.emergencyText : p.accentText
        let fill = red ? p.emergency.opacity(0.15) : p.sunken.opacity(0.6)
        return Button { action(item.id) } label: {
            VStack(spacing: 6) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(item.isActive ? p.onAccent : ink)
                    .frame(width: 34, height: 30)
                    .background { if item.isActive { Circle().fill(red ? p.emergency : p.accent).frame(width: 34, height: 34) } }
                VStack(spacing: 0) {
                    Text(item.title)
                        .font(.sary(11, .regular))
                        .foregroundStyle(p.textPrimary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                    if item.id == "youtube", let sub = item.subtitle {
                        Text(sub).font(.sary(9, .regular)).foregroundStyle(p.textTertiary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.title))
        .accessibilityHint(Text(item.subtitle ?? ""))
        .accessibilityAddTraits(item.isActive ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(item.accessibilityID)
    }
}
