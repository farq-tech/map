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
    /// Related secondary actions expand inside the group so the first sheet stays concise.
    var children: [LiveActionItem] = []

    enum Tone: Equatable { case normal, emergency }
}

struct LiveActionGroup: Identifiable, Equatable {
    var id: String { title }
    var title: String
    var items: [LiveActionItem]
}

/// The focused parts of the trip a tile or the quick row opens (UX simplification: the
/// sheet keeps only the essentials; these were the «الرحلة» and «العيال» tabs' sections).
enum LivePanel: String, Identifiable, Equatable {
    /// «الوجهة والخطة»: the trip's progress, the legs so far, the plan and «اتبع الخطة».
    case route
    /// «السلامة»: the return timer, «غرّزت», sunset.
    case safety
    /// «نقطة التجمع».
    case rally
    /// «ادعُ ربعك»: personal invites / the open link and its QR.
    case invite
    /// «رقم جوالي» (moved out of the trip tab).
    case phone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .route: return "الوجهة والخطة"
        case .safety: return "السلامة"
        case .rally: return "نقطة التجمع"
        case .invite: return "ادعُ ربعك"
        case .phone: return "رقم جوالي"
        }
    }
}

/// «المزيد» (was «أدوات الطلعة», ~٢٢ tiles in ٦ sections): only what the sheet's quick row
/// (ملاحة / وجّه الكل، المحادثة، التجمع، أخفِ موقعي، طريق الرجعة) does not already offer,
/// and no tile that repeats another screen (high-res / realistic live in «الطبقات», the effects
/// and radio / YouTube in «الإعدادات»). docs/ux-simplify-inventory.md.
enum LiveActionCatalog {
    struct State: Equatable {
        var backTracking = false
        var following = false
        var hasRoute = true
        var stuck = false
        /// The trip ended: only what still makes sense on this phone (map, search, weather…).
        var ended = false
        /// The leader: «وجّه الكل إلى …» (start / re-send guidance for everyone) — the quick row's primary.
        var guideAllTarget: String?
        /// «المحادثات» only when the server has it (an older server: hidden, see ChatStore.availability).
        var chat = true
        /// «الترددات» only when the server has walkie-talkie channels.
        var channels = false
    }

    /// Entries that only make sense while the outing runs (they reach the group, or the group's channel).
    static let needsRunningTrip: Set<String> = ["note", "stuck", "waypoint", "youtube", "follow", "guideAll", "channels", "enjad",
                                                "rally", "convoy", "timer", "invite"]

    /// What the quick row holds (never repeated as a tile; «ملاحة» is a tile only when «وجّه الكل» takes its place).
    static let inQuickRow: Set<String> = ["navigate", "guideAll", "chat", "rally", "backtrack", "hide"]

    static func groups(_ s: State) -> [LiveActionGroup] {
        let all = [
            LiveActionGroup(title: "الطريق", items: (s.guideAllTarget == nil && !s.ended ? [] : [
                /* The leader's quick row leads with «وجّه الكل», and after the end there is no quick row:
                 * then «ملاحة» (to a friend, the rally point, back) is here. */
                LiveActionItem(id: "navigate", title: "ملاحة", systemImage: "location.north.fill", accessibilityID: "outing-navigate",
                               subtitle: "لواحد من العيال، للوجهة أو لنقطة التجمع"),
            ]) + [
                .init(id: "route", title: "الوجهة والخطة", systemImage: "map", accessibilityID: "outing-route",
                      subtitle: s.following ? "تتبع الخطة الآن" : "سجل الطلعة، الخطة، اتبع المسار", isActive: s.following),
                .init(id: "search", title: "ابحث أو إحداثية", systemImage: "magnifyingglass", accessibilityID: "outing-search"),
            ]),
            LiveActionGroup(title: "الجماعة", items: (s.channels ? [
                LiveActionItem(id: "channels", title: "الترددات", systemImage: "dot.radiowaves.left.and.right", accessibilityID: "outing-ptt-channels"),
            ] : []) + [
                .init(id: "invite", title: "ادعُ ربعك", systemImage: "person.badge.plus", accessibilityID: "outing-invite"),
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
                .init(id: "locationTools", title: "مكاني", systemImage: "mappin.and.ellipse", accessibilityID: "outing-location-tools",
                      subtitle: "تفاصيل الموقع، حفظه أو إضافته للخطة", children: [
                        .init(id: "brief", title: "بريف المكان", systemImage: "info.circle", accessibilityID: "outing-brief"),
                        .init(id: "savePlace", title: "احفظ مكان", systemImage: "bookmark", accessibilityID: "outing-save-place"),
                        .init(id: "waypoint", title: "أضف نقطة", systemImage: "mappin.and.ellipse", accessibilityID: "outing-waypoint-add"),
                      ]),
                .init(id: "nearest", title: "أقرب محطة", systemImage: SaryIcon.nearest, accessibilityID: "outing-nearest-open"),
            ]),
            LiveActionGroup(title: "الخريطة", items: [
                .init(id: "weatherTools", title: "طقس واتجاه", systemImage: "sun.horizon", accessibilityID: "outing-weather-tools",
                      subtitle: "الطقس والسحاب والقبلة", children: [
                        .init(id: "weather", title: "الطقس", systemImage: "sun.max", accessibilityID: "outing-weather"),
                        .init(id: "qibla", title: "القبلة", systemImage: "location.north.circle", accessibilityID: "outing-qibla"),
                      ]),
                .init(id: "explore", title: "الطبقات", systemImage: "square.3.layers.3d", accessibilityID: "outing-explore",
                      subtitle: "قمر صناعي، طبوغرافي، صور عالية الوضوح، الوضع الواقعي"),
                .init(id: "fit", title: "شوف الكل", systemImage: SaryIcon.fitGroup, accessibilityID: "outing-fit"),
            ]),
        ]
        guard s.ended else { return all }
        return all.compactMap { g in
            var g = g
            g.items = g.items.compactMap { original in
                var item = original
                guard !item.children.isEmpty else { return needsRunningTrip.contains(item.id) ? nil : item }
                item.children.removeAll { needsRunningTrip.contains($0.id) }
                return item.children.isEmpty ? nil : item
            }
            return g.items.isEmpty ? nil : g
        }
    }

    /// The quick row's first, accent button: «وجّه الكل إلى …» for the leader of a running trip
    /// with a next stop, else «ملاحة» (to a friend, the destination or the rally point).
    static func primary(_ s: State) -> LiveActionItem {
        if !s.ended, let t = s.guideAllTarget {
            return LiveActionItem(id: "guideAll", title: "وجّه الكل", systemImage: "location.north.line.fill", accessibilityID: "outing-guide-all",
                                  subtitle: "وجّه الكل إلى \(t) · يبدأ التوجيه على جوال كل عضو")
        }
        return LiveActionItem(id: "navigate", title: "ملاحة", systemImage: "location.north.fill", accessibilityID: "outing-navigate",
                              subtitle: "لواحد من العيال، للوجهة أو لنقطة التجمع")
    }

    /// The route actions of «الوجهة والخطة»: «اتبع الخطة» and, for the leader, «وجّه الكل».
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

/// «المزيد» → «الطلعة»: the trip's own buttons, once (they were in the trip tab twice).
struct LiveTripRows {
    var canPause = false
    var paused = false
    var canEnd = false
    var canLeave = true
    var pauseOrResume: () -> Void = {}
    var end: () -> Void = {}
    var leave: () -> Void = {}
    var settings: () -> Void = {}
}

struct LiveActionSheet: View {
    var groups: [LiveActionGroup]
    var action: (String) -> Void
    var close: () -> Void
    var trip = LiveTripRows()
    @Environment(\.sary) private var theme
    @State private var confirm: Confirm?
    @State private var expandedActionID: String?

    enum Confirm: Identifiable { case pause, end, leave; var id: Self { self } }

    var body: some View {
        let p = theme.palette
        /* Tiles fit one screen; the scroll view is only for the largest text sizes. */
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.s)) {
                HStack {
                    Text("المزيد").font(.sary(18, .bold)).foregroundStyle(p.textPrimary)
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
                                    ForEach(g.items[i..<min(i + 4, g.items.count)]) { item in
                                        tile(item)
                                    }
                                    ForEach(0..<(4 - min(4, g.items.count - i)), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, minHeight: 1) }
                                }
                            }
                        }
                        if let item = g.items.first(where: { $0.id == expandedActionID }), !item.children.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(item.children) { child in
                                    tripRow(child.title, icon: child.systemImage, id: child.accessibilityID) {
                                        action(child.id)
                                    }
                                    if child.id != item.children.last?.id { SaryDivider() }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.sunken.opacity(0.6)))
                            .padding(.top, theme.space(.xs))
                            /* A parent accessibility identifier is inherited by SwiftUI children
                             * on iOS 27, which overwrites each tripRow's own ID (weather, qibla,
                             * place details). Keep the container discoverable by its children. */
                            .accessibilityElement(children: .contain)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                tripSection
            }
            .padding(.horizontal, theme.space(.l))
            .padding(.vertical, theme.space(.s))
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outing-actions-sheet")
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { k in
            switch k {
            case .pause: Button(trip.paused ? "استأنف" : "أوقف مؤقتًا") { close(); trip.pauseOrResume() }
            case .end: Button("أنهِ الطلعة للجميع", role: .destructive) { close(); trip.end() }
            case .leave: Button("غادر", role: .destructive) { close(); trip.leave() }
            }
            Button("إلغاء", role: .cancel) {}
        } message: { k in
            switch k {
            case .pause: Text(trip.paused ? "يرجع الأعضاء يشاركون مواقعهم." : "تتوقف مشاركة المواقع عند الجميع وتُحذف المواقع حتى تستأنف.")
            case .end: Text("بتنتهي الطلعة عند الكل ويتوقف تتبع المواقع. ما تقدر ترجعها.")
            case .leave: Text("تتوقف مشاركة موقعك فورًا ويُحذف آخر موقع لك من الخادم. ترجع لها فقط بدعوة جديدة.")
            }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .pause?: return trip.paused ? "استئناف الطلعة؟" : "إيقاف الطلعة مؤقتًا؟"
        case .end?: return "أنهِ الطلعة؟"
        case .leave?: return "تغادر الطلعة؟"
        case nil: return ""
        }
    }

    /// «الطلعة»: settings, pause / resume, end (the leader), leave — each once.
    private var tripSection: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: 4) {
            Text("الطلعة").font(.sary(12, .bold)).foregroundStyle(p.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, theme.space(.xs))
            VStack(spacing: 0) {
                tripRow("الإعدادات", icon: SaryIcon.settings, id: "outing-settings") { close(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: trip.settings) }
                if trip.canPause {
                    SaryDivider()
                    tripRow(trip.paused ? "استأنف الطلعة" : "أوقف مؤقتًا", icon: trip.paused ? SaryIcon.play : SaryIcon.pause, id: "settings-pause-outing") { confirm = .pause }
                }
                if trip.canEnd {
                    SaryDivider()
                    tripRow("أنهِ الطلعة", icon: "flag.checkered", destructive: true, id: "settings-end") { confirm = .end }
                }
                if trip.canLeave {
                    SaryDivider()
                    tripRow("غادر الطلعة", icon: "rectangle.portrait.and.arrow.right", destructive: true, id: "settings-leave") { confirm = .leave }
                }
            }
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.sunken.opacity(0.6)))
        }
        .padding(.top, theme.space(.s))
    }

    private func tripRow(_ title: String, icon: String, destructive: Bool = false, id: String, _ run: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: run) {
            HStack(spacing: theme.space(.m)) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(destructive ? p.emergencyText : p.accentText).frame(width: 26)
                Text(title).font(.sary(15, .bold)).foregroundStyle(destructive ? p.emergencyText : p.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, theme.space(.m))
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// Lovable tile: 80×78, 24 pt corners, the icon in orange (red for safety), an 11 pt label.
    private func tile(_ item: LiveActionItem) -> some View {
        let p = theme.palette
        let red = item.tone == .emergency
        let ink = red ? p.emergencyText : p.accentText
        let fill = red ? p.emergency.opacity(0.15) : p.sunken.opacity(0.6)
        return Button {
            if item.children.isEmpty {
                action(item.id)
            } else {
                withAnimation(theme.animation(.snappy)) {
                    expandedActionID = expandedActionID == item.id ? nil : item.id
                }
            }
        } label: {
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
        .accessibilityValue(Text(item.children.isEmpty ? "" : (expandedActionID == item.id ? "مفتوح" : "مغلق")))
        .accessibilityIdentifier(item.accessibilityID)
    }
}
