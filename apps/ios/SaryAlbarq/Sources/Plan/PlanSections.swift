import SwiftUI

/// The outing details screen's «خطة الطلعة» and «قائمة التجهيز» (shown before the start too).
struct PlanDetailsSections: View {
    let snapshot: OutingSnapshot
    @ObservedObject var plan: PlanModel
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance
    @State private var editorOpen = false
    @State private var share: URL?

    private var iLead: Bool { snapshot.me.role == "owner" || snapshot.me.co_leader == true || snapshot.me.can_lead == true }

    var body: some View {
        planSection
        ChecklistSection(plan: plan, members: snapshot.members, me: snapshot.me.user_id, iLead: iLead)
            .task { await plan.load() }
            .onAppear { plan.startPolling() }
            .onDisappear { plan.stopPolling() }
            .fullScreenCover(isPresented: $editorOpen) {
                PlanEditorView(plan: plan, outingName: snapshot.outing.name, canEdit: iLead, myFix: location.lastFix, close: { editorOpen = false })
                    .saryPresented(appearance)
            }
            .sheet(item: Binding(get: { share.map(ShareTarget.init) }, set: { if $0 == nil { share = nil } })) { s in
                ShareSheet(items: [s.url]).presentationDetents([.medium, .large])
            }
    }

    @ViewBuilder
    private var planSection: some View {
        let p = theme.palette
        SarySection(title: "خطة الطلعة", footer: iLead ? "أنت تقدر ترسم المسار وتحدد الوجهة. يشوفها كل الأعضاء." : "يرسمها أمير الطلعة أو نائبه.") {
            switch plan.planPhase {
            case .loading:
                SarySkeletonRow().padding(.vertical, theme.space(.s))
            case .unavailable:
                unavailable("تخطيط الطلعة غير متاح بعد", "الخادم لم يُحدَّث لهذه الميزة. جرّب لاحقًا.")
            case .failed(let m):
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    SaryInlineMessage(text: m, tone: .error)
                    Button("حاول مرة ثانية") { Task { await plan.loadPlan() } }.buttonStyle(.sary(.plain, width: .hug, compact: true))
                }
                .padding(.vertical, theme.space(.s))
            case .loaded:
                let tp = plan.plan
                VStack(alignment: .leading, spacing: theme.space(.m)) {
                    if tp.hasRoute || tp.destination != nil {
                        PlanMapView(route: tp.points, destination: tp.destination, interactive: false,
                                    camera: PlanCamera(kind: .fit(tp.points + (tp.destination.map { [LngLat(lng: $0.lng, lat: $0.lat)] } ?? [])), id: tp.points.count &+ (tp.updated_at?.hashValue ?? 0)),
                                    theme: theme)
                            .frame(height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous))
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("details.planMap")
                    }
                    if tp.hasRoute {
                        HStack(spacing: theme.space(.l)) {
                            stat("المسافة", SaryFormat.distance(meters: plan.routeLengthM))
                            stat("الوقت التقديري", "≈ " + SaryFormat.duration(seconds: plan.etaSeconds))
                        }
                        .accessibilityIdentifier("details.planStats")
                    }
                    if let d = tp.destination {
                        DestinationRow(destination: d, myFix: location.lastFix)
                    }
                    if !tp.notes.isEmpty {
                        Text(tp.notes).saryText(.subhead).foregroundStyle(p.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if tp.isEmpty {
                        Text(iLead ? "ما فيه خطة بعد. ارسم المسار أو استورد ملف مسار." : "ما فيه خطة بعد.").saryText(.subhead).foregroundStyle(p.textSecondary)
                    }
                    HStack(spacing: theme.space(.s)) {
                        if iLead || !tp.isEmpty {
                            Button { editorOpen = true } label: {
                                SaryButtonLabel(title: iLead ? (tp.isEmpty ? "ارسم المسار" : "عدّل الخطة") : "افتح الخطة", systemImage: iLead ? "pencil.tip" : "map")
                            }
                            .buttonStyle(.sary(iLead && tp.isEmpty ? .primary : .secondary, compact: true))
                            .accessibilityIdentifier("details.planOpen")
                        }
                        if tp.hasRoute {
                            Button {
                                share = try? RouteFile.exportFile(name: snapshot.outing.name, plan: tp)
                                TrackLibrary.shared.add(name: snapshot.outing.name, origin: .exported, points: tp.points)
                            } label: { SaryButtonLabel(title: "ملف المسار", systemImage: SaryIcon.share) }
                                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                                .accessibilityIdentifier("details.planExport")
                        }
                    }
                }
                .padding(.vertical, theme.space(.s))
            }
        }
    }

    private func unavailable(_ t: String, _ m: String) -> some View {
        HStack(spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: "clock.badge.questionmark")
            VStack(alignment: .leading, spacing: 2) {
                Text(t).saryText(.body, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                Text(m).saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
            }
        }
        .padding(.vertical, theme.space(.s))
        .accessibilityIdentifier("plan.unavailable")
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).saryNumber(.title2, weight: .bold).foregroundStyle(theme.palette.textPrimary)
            Text(k).saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// «الوجهة»: distance, direction and a rough time from me. Before the start there is no live map to
/// guide on, so it says plainly «افتح في تطبيق ثاني» (Google Maps / Waze), never «اتجه».
struct DestinationRow: View {
    var destination: OutingDestination
    var myFix: DeviceFix?
    var compact = false
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let dest = LngLat(lng: destination.lng, lat: destination.lat)
        let me = myFix.map { LngLat(lng: $0.lng, lat: $0.lat) }
        let fresh = myFix.map { Date().timeIntervalSince1970 - $0.atMs / 1000 <= FollowPlan.maxFixAgeS } ?? false
        HStack(spacing: theme.space(.m)) {
            if let me, fresh {
                let b = PlanGeo.bearing(me, dest)
                let rel = myFix?.heading.map { b - $0 } ?? b
                Image(systemName: "location.north.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color(UIColor(rgb: PlanMapStyle.color)))
                    .rotationEffect(.degrees(rel))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(p.sunken))
                    .accessibilityLabel(myFix?.heading == nil ? "باتجاه \(Geo.directionLabel(b))" : "اتجاه الوجهة بالنسبة لك")
            } else {
                SaryRowIcon(systemImage: "flag.checkered")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.name).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                if let me, fresh {
                    let d = PlanGeo.meters(me, dest)
                    Text("\(SaryFormat.distance(meters: d)) · \(Geo.directionLabel(PlanGeo.bearing(me, dest))) · ≈ \(SaryFormat.duration(seconds: PlanETA.seconds(meters: d * 1.3)))")
                        .saryNumber(.footnote).foregroundStyle(p.textSecondary)
                        .accessibilityIdentifier("destination.distance")
                } else {
                    Text(myFix == nil ? "الوجهة" : "بانتظار موقعك الحالي").saryText(.footnote).foregroundStyle(p.textSecondary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(ExternalNav.App.allCases) { app in
                    Button(app.openTitle) { ExternalNav.open(app, dest) }
                }
            } label: { SaryButtonLabel(title: "افتح في تطبيق ثاني", systemImage: SaryIcon.directions) }
                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                .accessibilityIdentifier("destination.go")
        }
        .accessibilityIdentifier("destination.row")
    }
}

// MARK: - checklist

struct ChecklistSection: View {
    @ObservedObject var plan: PlanModel
    var members: [Member]
    var me: String
    var iLead: Bool
    @Environment(\.sary) private var theme
    @State private var newTitle = ""

    var body: some View {
        let p = theme.palette
        let s = plan.checklist
        SarySection(title: "قائمة التجهيز", footer: plan.checklistPhase == .loaded ? "أي عضو يضيف ويوزّع ويعلّم. تتحدث عند الكل." : nil) {
            switch plan.checklistPhase {
            case .loading:
                SarySkeletonRow().padding(.vertical, theme.space(.s))
            case .unavailable:
                HStack(spacing: theme.space(.m)) {
                    SaryRowIcon(systemImage: "clock.badge.questionmark")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("قائمة التجهيز غير متاحة بعد").saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                        Text("الخادم لم يُحدَّث لهذه الميزة. جرّب لاحقًا.").saryText(.footnote).foregroundStyle(p.textSecondary)
                    }
                }
                .padding(.vertical, theme.space(.s))
                .accessibilityIdentifier("checklist.unavailable")
            case .failed(let m):
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    SaryInlineMessage(text: m, tone: .error)
                    Button("حاول مرة ثانية") { Task { await plan.loadChecklist() } }.buttonStyle(.sary(.plain, width: .hug, compact: true))
                }
                .padding(.vertical, theme.space(.s))
            case .loaded:
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    if s.total > 0 {
                        HStack {
                            Text(s.progressLabel).saryNumber(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                                .accessibilityIdentifier("checklist.progress")
                            Text("جاهز").saryText(.subhead).foregroundStyle(p.textSecondary)
                            Spacer()
                        }
                        ProgressView(value: s.fraction).tint(s.doneCount == s.total ? p.live : p.accent)
                            .accessibilityHidden(true)
                    }
                    ForEach(s.ordered) { item in
                        SaryDivider()
                        ChecklistRow(item: item, members: members, me: me,
                                     canDelete: ChecklistState.canDelete(item, me: me, iLead: iLead),
                                     toggle: { Task { await plan.toggle(item.id) } },
                                     assign: { u in Task { await plan.assign(item.id, to: u) } },
                                     delete: { Task { await plan.delete(item.id) } })
                    }
                    SaryDivider()
                    HStack(spacing: theme.space(.s)) {
                        SaryTextField(title: "أضف غرض", placeholder: "مثل: ماء", text: $newTitle, id: "checklist.field", maxLength: ChecklistItem.titleMax)
                        Button { addTyped() } label: { Image(systemName: "plus").font(.system(size: 18, weight: .bold)).frame(width: 50, height: 50) }
                            .buttonStyle(.sary(.primary, width: .hug, compact: true))
                            .disabled(ChecklistState.cleanTitle(newTitle) == nil)
                            .accessibilityLabel("أضف")
                            .accessibilityIdentifier("checklist.add")
                            .padding(.top, 22)
                    }
                    let sug = s.openSuggestions
                    if !sug.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: theme.space(.xs)) {
                                ForEach(sug, id: \.self) { t in
                                    Button { Task { _ = await plan.add(t, me: me) } } label: {
                                        Label(t, systemImage: "plus").saryText(.subhead, weight: .medium)
                                            .padding(.horizontal, theme.space(.m)).padding(.vertical, theme.space(.xs) + 2)
                                            .background(Capsule().fill(p.sunken))
                                            .foregroundStyle(p.textPrimary)
                                    }
                                    .buttonStyle(SaryPressStyle())
                                    .accessibilityIdentifier("checklist.suggest")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.vertical, theme.space(.s))
            }
        }
        .alert("تنبيه", isPresented: Binding(get: { plan.errorText != nil }, set: { if !$0 { plan.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(plan.errorText ?? "") }
    }

    private func addTyped() {
        let t = newTitle
        Task { if await plan.add(t, me: me) { newTitle = "" } }
    }
}

struct ChecklistRow: View {
    var item: ChecklistItem
    var members: [Member]
    var me: String
    var canDelete: Bool
    var toggle: () -> Void
    var assign: (String?) -> Void
    var delete: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let who = members.first { $0.user_id == item.assignee_user_id }
        HStack(spacing: theme.space(.m)) {
            Button(action: toggle) {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(item.done ? p.live : p.textTertiary)
                    .frame(width: theme.minTarget, height: theme.minTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(item.done ? "تم: \(item.title)" : "لم يتم: \(item.title)")
            .accessibilityIdentifier("checklist.toggle")
            Text(item.title)
                .saryText(.body, weight: .medium)
                .foregroundStyle(item.done ? p.textTertiary : p.textPrimary)
                .strikethrough(item.done, color: p.textTertiary)
            Spacer(minLength: 0)
            Menu {
                Button { assign(me) } label: { Label("أنا", systemImage: "person.fill") }
                ForEach(members.filter { $0.user_id != me }) { m in
                    Button(m.display_name) { assign(m.user_id) }
                }
                if item.assignee_user_id != nil {
                    Button("بدون أحد") { assign(nil) }
                }
                if canDelete {
                    Divider()
                    Button(role: .destructive, action: delete) { Label("احذف", systemImage: "trash") }
                }
            } label: {
                Text(who.map { $0.user_id == me ? "أنا" : $0.display_name } ?? "وزّع")
                    .saryText(.footnote, weight: .bold)
                    .foregroundStyle(who == nil ? p.accentText : p.textSecondary)
                    .padding(.horizontal, theme.space(.s)).padding(.vertical, 6)
                    .background(Capsule().fill(p.sunken))
                    .frame(minHeight: theme.minTarget)
            }
            .accessibilityLabel(who.map { "مع \($0.display_name)" } ?? "وزّع على عضو")
            .accessibilityIdentifier("checklist.assign")
        }
    }
}
