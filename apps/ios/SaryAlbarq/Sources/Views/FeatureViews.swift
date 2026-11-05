import PhotosUI
import SwiftUI
import UIKit

// The sheet sections, cards and composers for shared waypoints (§3) and convoy mode (§4).

// MARK: - Waypoints section (participants tab)

struct WaypointsSection: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject var features: OutingFeaturesModel
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        SarySection(title: "نقاط مشتركة", footer: footer) {
            VStack(alignment: .leading, spacing: 0) {
                switch features.phase {
                case .notDeployed:
                    SaryBanner(text: FeatureAvailability.notDeployedText, tone: .info, systemImage: "clock.badge.questionmark")
                        .padding(.vertical, theme.space(.s))
                        .accessibilityIdentifier("waypoints.unavailable")
                case let .failed(msg):
                    SaryBanner(text: msg, tone: .warning).padding(.vertical, theme.space(.s))
                case let .cached(at):
                    SaryBanner(text: "بلا اتصال · آخر نسخة \(SaryFormat.elapsed(since: at, now: Date()))", tone: .info, systemImage: SaryIcon.offline)
                        .padding(.vertical, theme.space(.s))
                case .loading where features.waypoints.isEmpty:
                    ProgressView().frame(maxWidth: .infinity).padding(theme.space(.m))
                default:
                    EmptyView()
                }
                if features.waypoints.isEmpty, features.phase == .loaded {
                    Text("ما فيه نقاط بعد. أضف مخيم أو ماء أو خطر يشوفه الكل على الخريطة.")
                        .saryText(.subhead).foregroundStyle(p.textSecondary)
                        .padding(.vertical, theme.space(.s))
                }
                ForEach(features.waypoints) { w in
                    WaypointRow(waypoint: w, by: features.creatorName(w), from: myPoint, mapBearing: controller.overlay.projection.bearing) {
                        features.modal = .waypoint(w.id)
                    }
                    if w.id != features.waypoints.last?.id { SaryDivider() }
                }
                if features.phase != .notDeployed, controller.session.view?.status != .ended {
                    Button { features.composeAtMe(controller.location.lastFix) } label: {
                        SaryButtonLabel(title: "أضف نقطة", systemImage: "mappin.and.ellipse")
                    }
                    .buttonStyle(.sary(.secondary))
                    .padding(.vertical, theme.space(.s))
                    .accessibilityIdentifier("waypoints.add")
                }
                Button { features.modal = .past } label: {
                    HStack {
                        Text("نقاط من طلعات سابقة").saryText(.subhead, weight: .bold).foregroundStyle(p.accentText)
                        Spacer()
                        Image(systemName: "chevron.forward").font(.system(size: 12, weight: .bold)).foregroundStyle(p.textTertiary)
                    }
                    .frame(minHeight: theme.minTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SaryRowPressStyle())
                .accessibilityIdentifier("waypoints.past")
            }
        }
    }

    private var footer: String {
        "تظهر لكل أعضاء الطلعة، وتبقى بعد نهايتها. اضغط مطولًا على الخريطة لتضيف نقطة في أي مكان."
    }

    private var myPoint: Geo.LatLng? {
        guard let f = controller.location.lastFix, Date().timeIntervalSince1970 * 1000 - f.atMs <= LiveOutingPresenter.myLiveMaxAgeMs else { return nil }
        return f.coordinate
    }
}

struct WaypointRow: View {
    var waypoint: Waypoint
    var by: String
    /// My live position (distance and direction are only shown from a live fix).
    var from: Geo.LatLng?
    var mapBearing: Double = 0
    var tapped: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button(action: tapped) {
            HStack(spacing: theme.space(.m)) {
                SaryWaypointGlyph(kind: waypoint.kind, size: theme.drive ? 40 : 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(waypoint.title).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                    Text("\(waypoint.kind.label) · \(by)").saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let from {
                    let to = Geo.LatLng(lat: waypoint.lat, lng: waypoint.lng)
                    HStack(spacing: 4) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(LiveOutingPresenter.relative(Geo.bearingDeg(from, to), mapBearing: mapBearing)))
                            .environment(\.layoutDirection, .leftToRight)
                        Text(SaryFormat.distance(meters: Geo.haversineMeters(from, to))).saryNumber(.footnote, weight: .bold)
                    }
                    .foregroundStyle(p.textSecondary)
                }
                if waypoint.photo != nil {
                    Image(systemName: "photo").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.textTertiary)
                }
            }
            .frame(minHeight: theme.minTarget + 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryRowPressStyle())
        .accessibilityIdentifier("waypoint-row")
    }
}

// MARK: - Convoy section

struct ConvoySection: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject var features: OutingFeaturesModel
    @Environment(\.sary) private var theme

    var body: some View {
        let v = controller.session.view
        let c = v?.convoy
        if let v, c?.isOn == true || v.iLead, v.status != .ended {
            SarySection(title: "القافلة", footer: c?.isOn == true ? "التنبيهات تُحسب على جوالك من المواقع المباشرة فقط. سيارة موقعها قديم لا تُحسب." : nil) {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    if let c, c.isOn {
                        roleRow(.lead, c.lead_user_id, v)
                        SaryDivider()
                        roleRow(.tail, c.tail_user_id, v)
                        SaryDivider()
                        HStack {
                            Text("أقصى مسافة بين السيارات").saryText(.subhead).foregroundStyle(theme.palette.textSecondary)
                            Spacer()
                            Text(SaryFormat.distance(meters: c.gapM)).saryNumber(.subhead, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                        }
                        .frame(minHeight: theme.minTarget)
                        status(features.convoyCheck)
                    } else {
                        Text("حدّد سيارة في المقدمة وسيارة في المؤخرة، وننبّه الكل إذا أحد سبق المقدمة أو تأخر عن المؤخرة.")
                            .saryText(.subhead).foregroundStyle(theme.palette.textSecondary)
                            .padding(.top, theme.space(.s))
                    }
                    if v.iLead {
                        Button { features.modal = .convoy } label: {
                            SaryButtonLabel(title: c?.isOn == true ? "عدّل القافلة" : "شغّل وضع القافلة", systemImage: "car.2.fill")
                        }
                        .buttonStyle(.sary(c?.isOn == true ? .secondary : .primary))
                        .padding(.vertical, theme.space(.s))
                        .accessibilityIdentifier("convoy.edit")
                    }
                }
            }
            .accessibilityIdentifier("convoy.section")
        }
    }

    private func roleRow(_ r: ConvoyRole, _ uid: String?, _ v: OutingView) -> some View {
        let p = theme.palette
        let m = uid.flatMap { v.members[$0] }
        let parts = Dictionary(LiveOutingPresenter.participants(controller.input).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let live = uid.flatMap { parts[$0] }?.presence.isLive ?? false
        return HStack(spacing: theme.space(.m)) {
            Label(r.label, systemImage: ConvoyBadgeUI(r).symbol)
                .saryText(.footnote, weight: .bold)
                .foregroundStyle(p.onAccent)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(p.accent))
            Text(m.map { $0.user_id == v.myId ? "أنت" : $0.display_name } ?? "لم تُحدَّد")
                .saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
            Spacer()
            if m != nil {
                Text(live ? "مباشر" : "موقعه قديم").saryText(.caption, weight: .bold).foregroundStyle(live ? p.liveText : p.textTertiary)
            }
        }
        .frame(minHeight: theme.minTarget)
    }

    @ViewBuilder
    private func status(_ e: ConvoyMath.Evaluation?) -> some View {
        if let e {
            if e.leadMissing || e.tailMissing {
                SaryBanner(text: e.leadMissing && e.tailMissing ? "المقدمة والمؤخرة بلا موقع مباشر · التنبيهات متوقفة حتى يرجع موقعهم"
                           : e.leadMissing ? "المقدمة بلا موقع مباشر · لا ننبّه عن من سبقها" : "المؤخرة بلا موقع مباشر · لا ننبّه عن من تأخر",
                           tone: .info)
            } else if e.alerts.isEmpty {
                SaryBanner(text: "كل السيارات المباشرة ضمن القافلة", tone: .success, systemImage: SaryIcon.checkCircle)
            } else {
                SaryBanner(text: "\(SaryFormat.number(e.alerts.count)) تنبيه في القافلة الآن", tone: .warning)
            }
        }
    }
}

// MARK: - Presentations

/// The feature sheets, attached once to the live sheet.
struct FeatureModals: ViewModifier {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject var features: OutingFeaturesModel
    @Environment(AppearanceSettings.self) private var appearance

    func body(content: Content) -> some View {
        content.background {
            Color.clear
                .sheet(item: $features.modal) { m in
                    Group {
                        switch m {
                        case let .compose(p):
                            WaypointComposer(point: p, features: features)
                                .presentationDetents([.large])
                        case let .waypoint(id):
                            if let w = features.waypoints.first(where: { $0.id == id }) {
                                WaypointCard(waypoint: w, features: features, controller: controller)
                                    .presentationDetents([.medium, .large])
                                    .presentationDragIndicator(.visible)
                            }
                        case .convoy:
                            ConvoyEditor(controller: controller, features: features)
                                .presentationDetents([.large])
                        case .past:
                            PastWaypointsView(currentOuting: features.outingId, close: { features.modal = nil }, show: { p in
                                features.modal = nil
                                controller.sheetDetent = .peek
                                controller.ask(.point(p))
                            })
                            .presentationDetents([.large])
                        }
                    }
                    .saryAppearance(appearance)
                }
        }
    }
}

// MARK: - Composer

struct WaypointComposer: View {
    var point: LngLat
    @ObservedObject var features: OutingFeaturesModel
    @Environment(\.sary) private var theme
    @State private var kind: WaypointKind = .camp
    @State private var title = WaypointKind.camp.label
    @State private var titleEdited = false
    @State private var note = ""
    @State private var item: PhotosPickerItem?
    @State private var photo: String?
    @State private var photoBusy = false
    @State private var camera = false

    var body: some View {
        let p = theme.palette
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                HStack {
                    Text("نقطة جديدة").saryText(.title2).foregroundStyle(p.textPrimary)
                    Spacer()
                    SaryIconButton(systemImage: SaryIcon.close, label: "إلغاء", id: "waypoint.cancel") { features.modal = nil }
                }
                Text(coordText).saryNumber(.footnote, weight: .medium).foregroundStyle(p.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityLabel(Text("المكان: \(coordText)"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.space(.s)), count: 3), spacing: theme.space(.s)) {
                    ForEach(WaypointKind.allCases) { k in
                        Button {
                            kind = k
                            if !titleEdited { title = k.label }
                        } label: {
                            VStack(spacing: 6) {
                                SaryWaypointGlyph(kind: k, size: theme.drive ? 44 : 36)
                                Text(k.label).saryText(.footnote, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: theme.minTarget + 40)
                            .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(kind == k ? k.color(p).opacity(0.18) : p.sunken))
                            .overlay(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).strokeBorder(kind == k ? k.color(p) : .clear, lineWidth: 2))
                        }
                        .buttonStyle(SaryPressStyle())
                        .accessibilityLabel(Text(k.label))
                        .accessibilityAddTraits(kind == k ? .isSelected : [])
                        .accessibilityIdentifier("waypoint.kind.\(k.rawValue)")
                    }
                }
                SaryTextField(title: "الاسم", placeholder: "مثل: مخيم الشباب", text: Binding(get: { title }, set: { title = $0; titleEdited = true }),
                              id: "waypoint.title", maxLength: WaypointRules.titleMax)
                SaryTextField(title: "ملاحظة (اختياري)", placeholder: "مثل: نفّس كفراتك قبلها", text: $note, id: "waypoint.note", maxLength: WaypointRules.noteMax)
                photoRow
                if let e = features.composeError {
                    SaryInlineMessage(text: e, tone: .error).accessibilityIdentifier("waypoint.error")
                }
                Button {
                    Task {
                        await features.add(WaypointDraft(kind: kind, title: title, note: note.isEmpty ? nil : note, lat: point.lat, lng: point.lng, photo: photo))
                    }
                } label: { SaryButtonLabel(title: "أضف النقطة", systemImage: SaryIcon.check, busy: features.saving, busyTitle: "جارٍ الإضافة…") }
                    .buttonStyle(.saryPrimary)
                    .disabled(ServerRules.cleanText(title, max: WaypointRules.titleMax) == nil || features.saving || photoBusy)
                    .accessibilityIdentifier("waypoint.save")
                Text("تظهر النقطة واسمك لكل أعضاء الطلعة فقط.").saryText(.footnote).foregroundStyle(p.textTertiary)
            }
            .padding(theme.space(.l))
        }
        .onChange(of: item) { _, it in load(it) }
        .fullScreenCover(isPresented: $camera) {
            CameraPicker { img in
                camera = false
                if let img { compress(img) }
            }
            .ignoresSafeArea()
        }
    }

    private var coordText: String {
        SaryFormat.digits(String(format: "%.5f، %.5f", point.lat, point.lng))
    }

    @ViewBuilder
    private var photoRow: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.s)) {
            if let img = WaypointPhoto.image(fromDataURL: photo) {
                Image(uiImage: img).resizable().scaledToFill().frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous))
                    .accessibilityIdentifier("waypoint.photo.preview")
                Button("إزالة الصورة") { photo = nil; item = nil }
                    .buttonStyle(.sary(.plainDestructive, width: .hug, compact: true))
                Spacer()
            } else if photoBusy {
                ProgressView()
                Text("نجهّز الصورة…").saryText(.footnote).foregroundStyle(p.textSecondary)
                Spacer()
            } else {
                PhotosPicker(selection: $item, matching: .images) {
                    Label("صورة", systemImage: "photo.on.rectangle").saryText(.subhead, weight: .bold)
                }
                .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                .accessibilityIdentifier("waypoint.photo.library")
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { camera = true } label: { Label("الكاميرا", systemImage: "camera.fill").saryText(.subhead, weight: .bold) }
                        .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                        .accessibilityIdentifier("waypoint.photo.camera")
                }
                Spacer()
                Text("اختياري").saryText(.caption).foregroundStyle(p.textTertiary)
            }
        }
    }

    private func load(_ it: PhotosPickerItem?) {
        guard let it else { return }
        photoBusy = true
        Task {
            let data = try? await it.loadTransferable(type: Data.self)
            if let data, let img = UIImage(data: data) { compress(img) } else {
                photoBusy = false
                features.composeError = "تعذّر فتح الصورة. جرّب صورة ثانية."
            }
        }
    }

    private func compress(_ img: UIImage) {
        photoBusy = true
        Task.detached(priority: .userInitiated) {
            let url = WaypointPhoto.dataURL(from: img)
            await MainActor.run {
                photoBusy = false
                photo = url
                if url == nil { features.composeError = "تعذّر تصغير الصورة. جرّب صورة ثانية." }
            }
        }
    }
}

/// The system camera, for a waypoint photo (never saved to the photo library).
struct CameraPicker: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

// MARK: - Card

struct WaypointCard: View {
    var waypoint: Waypoint
    @ObservedObject var features: OutingFeaturesModel
    @ObservedObject var controller: LiveOutingController
    @Environment(\.sary) private var theme
    @State private var confirmDelete = false

    var body: some View {
        let p = theme.palette
        let w = waypoint
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                HStack(alignment: .top, spacing: theme.space(.m)) {
                    SaryWaypointGlyph(kind: w.kind, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).saryText(.title2).foregroundStyle(p.textPrimary)
                        Text(subtitle(w)).saryText(.footnote).foregroundStyle(p.textSecondary)
                    }
                    Spacer()
                    SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "waypoint.card.close") { features.modal = nil }
                }
                if let note = w.note, !note.isEmpty {
                    Text(note).saryText(.body).foregroundStyle(p.textPrimary)
                }
                if let img = WaypointPhoto.image(fromDataURL: w.photo) {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous))
                        .accessibilityLabel(Text("صورة النقطة"))
                }
                distanceRow(w)
                HStack(spacing: theme.space(.s)) {
                    Button {
                        features.modal = nil
                        controller.sheetDetent = .peek
                        controller.ask(.point(w.position))
                    } label: { SaryButtonLabel(title: "أظهرها", systemImage: SaryIcon.showOnMap) }
                        .buttonStyle(.sarySecondary)
                        .accessibilityIdentifier("waypoint.show")
                    Button { Directions.open(lat: w.lat, lng: w.lng, name: w.title) } label: { SaryButtonLabel(title: "اتجه", systemImage: SaryIcon.directions) }
                        .buttonStyle(.saryPrimary)
                        .accessibilityIdentifier("waypoint.go")
                }
                if features.canDelete(w) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        SaryButtonLabel(title: "احذف النقطة", systemImage: "trash", busy: features.deleting.contains(w.id), busyTitle: "جارٍ الحذف…")
                    }
                    .buttonStyle(.sary(.plainDestructive))
                    .accessibilityIdentifier("waypoint.delete")
                }
            }
            .padding(theme.space(.l))
        }
        .accessibilityIdentifier("waypoint-card")
        .confirmationDialog("تحذف «\(w.title)»؟", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("احذفها للجميع", role: .destructive) { Task { await features.delete(w.id) } }
            Button("إلغاء", role: .cancel) {}
        } message: { Text("تختفي النقطة من خريطة كل أعضاء الطلعة.") }
    }

    private func subtitle(_ w: Waypoint) -> String {
        let at = ISODate.parse(w.created_at).map { SaryFormat.elapsed(since: $0, now: Date()) } ?? ""
        return "\(w.kind.label) · أضافها \(features.creatorName(w))" + (at.isEmpty ? "" : " · \(at)")
    }

    @ViewBuilder
    private func distanceRow(_ w: Waypoint) -> some View {
        let p = theme.palette
        if let f = controller.location.lastFix, Date().timeIntervalSince1970 * 1000 - f.atMs <= LiveOutingPresenter.myLiveMaxAgeMs {
            let to = Geo.LatLng(lat: w.lat, lng: w.lng)
            let b = Geo.bearingDeg(f.coordinate, to)
            HStack(spacing: theme.space(.s)) {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.degrees(LiveOutingPresenter.relative(b, mapBearing: controller.overlay.projection.bearing)))
                    .environment(\.layoutDirection, .leftToRight)
                    .foregroundStyle(p.accentText)
                Text("\(SaryFormat.distance(meters: Geo.haversineMeters(f.coordinate, to))) · \(SaryFormat.compass(b))")
                    .saryNumber(.headline, weight: .bold).foregroundStyle(p.textPrimary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("waypoint.distance")
        } else {
            Text("المسافة تظهر لما يكون موقعك مباشرًا.").saryText(.footnote).foregroundStyle(p.textTertiary)
        }
    }
}

// MARK: - Convoy editor

struct ConvoyEditor: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject var features: OutingFeaturesModel
    @Environment(\.sary) private var theme
    @State private var lead: String?
    @State private var tail: String?
    @State private var gap = ConvoyInfo.defaultGapM

    var body: some View {
        let p = theme.palette
        let members = controller.session.view?.orderedMembers ?? []
        let myId = controller.session.view?.myId
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                HStack {
                    Text("وضع القافلة").saryText(.title2).foregroundStyle(p.textPrimary)
                    Spacer()
                    SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "convoy.close") { features.modal = nil }
                }
                picker("المقدمة", selection: $lead, members: members, myId: myId, id: "convoy.lead")
                picker("المؤخرة", selection: $tail, members: members, myId: myId, id: "convoy.tail")
                SarySection(title: "أقصى مسافة بين السيارات", footer: "ننبّه إذا تأخرت سيارة خلف المؤخرة أكثر من هذه المسافة، أو سبقت المقدمة.") {
                    VStack(alignment: .leading, spacing: theme.space(.s)) {
                        Text(SaryFormat.distance(meters: gap)).saryNumber(.title2, weight: .bold).foregroundStyle(p.textPrimary)
                        Slider(value: $gap, in: ConvoyInfo.gapRange, step: 100)
                            .tint(p.accent)
                            .accessibilityValue(Text(SaryFormat.distance(meters: gap)))
                            .accessibilityIdentifier("convoy.gap")
                    }
                    .padding(.vertical, theme.space(.s))
                }
                if let e = features.convoyError { SaryInlineMessage(text: e, tone: .error) }
                Button {
                    Task { await features.saveConvoy(ConvoyInfo(lead_user_id: lead, tail_user_id: tail, max_gap_m: gap)) }
                } label: { SaryButtonLabel(title: "احفظ", systemImage: SaryIcon.check, busy: features.convoySaving, busyTitle: "جارٍ الحفظ…") }
                    .buttonStyle(.saryPrimary)
                    .disabled((lead == nil && tail == nil) || (lead != nil && lead == tail) || features.convoySaving)
                    .accessibilityIdentifier("convoy.save")
                if lead != nil && lead == tail {
                    SaryInlineMessage(text: "اختر سيارة مختلفة للمقدمة والمؤخرة.", tone: .warning)
                }
                if controller.session.view?.convoy?.isOn == true {
                    Button(role: .destructive) { Task { await features.saveConvoy(.off) } } label: { SaryButtonLabel(title: "أوقف وضع القافلة", systemImage: SaryIcon.stop) }
                        .buttonStyle(.sary(.plainDestructive))
                        .accessibilityIdentifier("convoy.off")
                }
            }
            .padding(theme.space(.l))
        }
        .onAppear {
            let c = controller.session.view?.convoy
            lead = c?.lead_user_id
            tail = c?.tail_user_id
            gap = c?.gapM ?? ConvoyInfo.defaultGapM
        }
    }

    private func picker(_ title: String, selection: Binding<String?>, members: [Member], myId: String?, id: String) -> some View {
        SarySection(title: title) {
            ForEach(members) { m in
                Button { selection.wrappedValue = selection.wrappedValue == m.user_id ? nil : m.user_id } label: {
                    HStack(spacing: theme.space(.m)) {
                        SaryAvatar(name: m.display_name, color: controller.session.view?.colors[m.user_id] ?? 0xFFFFFF, size: 30)
                        Text(m.user_id == myId ? "\(m.display_name) (أنت)" : m.display_name).saryText(.body, weight: .medium).foregroundStyle(theme.palette.textPrimary)
                        Spacer()
                        if selection.wrappedValue == m.user_id {
                            Image(systemName: SaryIcon.checkCircle).foregroundStyle(theme.palette.accentText)
                        }
                    }
                    .frame(minHeight: theme.minTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SaryRowPressStyle())
                .accessibilityAddTraits(selection.wrappedValue == m.user_id ? .isSelected : [])
                .accessibilityIdentifier("\(id).\(m.user_id)")
                if m.id != members.last?.id { SaryDivider() }
            }
        }
    }
}

// MARK: - Past outings

/// Waypoints this device saw in other outings (read from the cache, no network needed).
struct PastWaypointsView: View {
    var currentOuting: String
    var close: () -> Void
    var show: ((LngLat) -> Void)?
    @Environment(\.sary) private var theme
    @State private var open: Waypoint?

    var body: some View {
        let p = theme.palette
        let entries = WaypointCache.all().filter { $0.outing_id != currentOuting }
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack {
                Text("نقاط من طلعات سابقة").saryText(.title2).foregroundStyle(p.textPrimary)
                Spacer()
                SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "past.close", action: close)
            }
            if entries.isEmpty {
                SaryStateView(kind: .empty(title: "ما فيه نقاط محفوظة", message: "النقاط من طلعاتك تُحفظ على جوالك لما تفتح الطلعة.", systemImage: "mappin.slash"))
            } else {
                ScrollView {
                    VStack(spacing: theme.space(.l)) {
                        ForEach(entries, id: \.outing_id) { e in
                            SarySection(title: e.outing_name.isEmpty ? "طلعة" : e.outing_name) {
                                ForEach(e.waypoints) { w in
                                    WaypointRow(waypoint: w, by: w.display_name ?? w.kind.label, from: nil) { open = w }
                                    if w.id != e.waypoints.last?.id { SaryDivider() }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(theme.space(.l))
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(item: $open) { w in
            PastWaypointDetail(waypoint: w, show: show.map { s in { open = nil; s(w.position) } })
                .presentationDetents([.medium, .large])
        }
    }
}

/// A saved point without the live screen around it: what, where, «اتجه».
struct PastWaypointDetail: View {
    var waypoint: Waypoint
    var show: (() -> Void)?
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let w = waypoint
        ScrollView {
            VStack(alignment: .leading, spacing: theme.space(.m)) {
                HStack(spacing: theme.space(.m)) {
                    SaryWaypointGlyph(kind: w.kind, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).saryText(.title2).foregroundStyle(p.textPrimary)
                        Text(w.kind.label + (ISODate.parse(w.created_at).map { " · " + SaryFormat.elapsed(since: $0, now: Date()) } ?? ""))
                            .saryText(.footnote).foregroundStyle(p.textSecondary)
                    }
                }
                if let n = w.note, !n.isEmpty { Text(n).saryText(.body).foregroundStyle(p.textPrimary) }
                if let img = WaypointPhoto.image(fromDataURL: w.photo) {
                    Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous))
                }
                Text(SaryFormat.digits(String(format: "%.5f، %.5f", w.lat, w.lng))).saryNumber(.footnote, weight: .medium).foregroundStyle(p.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
                    .textSelection(.enabled)
                HStack(spacing: theme.space(.s)) {
                    if let show {
                        Button(action: show) { SaryButtonLabel(title: "أظهرها", systemImage: SaryIcon.showOnMap) }.buttonStyle(.sarySecondary)
                    }
                    Button { Directions.open(lat: w.lat, lng: w.lng, name: w.title) } label: { SaryButtonLabel(title: "اتجه", systemImage: SaryIcon.directions) }
                        .buttonStyle(.saryPrimary)
                }
            }
            .padding(theme.space(.l))
        }
    }
}

// MARK: - Trip summary

/// «نقاط الطلعة» on the trip summary: from the server (members can read them after the end),
/// else what this device saved.
struct TripWaypointsSection: View {
    let outingId: String
    var outingName: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var list: [Waypoint]?
    @State private var note: String?
    @State private var open: Waypoint?

    var body: some View {
        let p = theme.palette
        SarySection(title: "نقاط الطلعة", footer: note) {
            if let list {
                if list.isEmpty {
                    Text("ما أُضيفت نقاط في هذه الطلعة.").saryText(.subhead).foregroundStyle(p.textSecondary).padding(.vertical, theme.space(.s))
                }
                ForEach(list) { w in
                    WaypointRow(waypoint: w, by: w.display_name ?? w.kind.label, from: nil) { open = w }
                    if w.id != list.last?.id { SaryDivider() }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(theme.space(.m))
            }
        }
        .accessibilityIdentifier("summary.waypoints")
        .task { await load() }
        .sheet(item: $open) { w in
            PastWaypointDetail(waypoint: w).presentationDetents([.medium, .large])
        }
    }

    private func load() async {
        do {
            let got = OutingFeaturesModel.sorted(try await model.featuresBackend.waypoints(outingId))
            list = got
            note = nil
            WaypointCache.save(outingId, name: outingName, got)
        } catch {
            let cached = WaypointCache.load(outingId)?.waypoints
            list = cached ?? []
            if FeatureAvailability.notDeployed(error) {
                note = cached == nil ? FeatureAvailability.notDeployedText : "المحفوظة على جوالك · " + FeatureAvailability.notDeployedText
            } else {
                note = cached == nil ? FeatureAvailability.arabic(error) : "بلا اتصال · المحفوظة على جوالك"
            }
        }
    }
}
