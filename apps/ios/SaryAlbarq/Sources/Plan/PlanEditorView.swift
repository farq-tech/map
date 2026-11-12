import SwiftUI
import UniformTypeIdentifiers

/// «خطة الطلعة» full screen: the leader draws the route (tap to add, drag to adjust,
/// undo), imports GPX/KML, sets the destination and notes; everyone else sees it
/// read-only and can export it as GPX.
struct PlanEditorView: View {
    @ObservedObject var plan: PlanModel
    var outingName: String
    var canEdit: Bool
    var myFix: DeviceFix?
    var close: () -> Void
    @Environment(\.sary) private var theme
    @State private var draft: [LngLat] = []
    @State private var undo: [[LngLat]] = []
    @State private var notes = ""
    @State private var destination: OutingDestination?
    @State private var drawing = false
    @State private var importing = false
    @State private var importBusy = false
    @State private var camera: PlanCamera?
    @State private var cameraSeq = 0
    @State private var card: LngLat?
    @State private var searchOpen = false
    @State private var notesOpen = false
    @State private var share: URL?
    @State private var confirmClear = false
    @State private var toast: String?
    @State private var loaded = false

    private var dirty: Bool {
        draft != plan.plan.points || notes != plan.plan.notes || destination != plan.plan.destination
    }

    var body: some View {
        let p = theme.palette
        ZStack {
            PlanMapView(route: draft, destination: destination, picked: card, editing: canEdit && drawing, camera: camera, theme: theme,
                        onTap: { add($0) }, onLongPress: { card = $0 }, onMove: { i, pt in move(i, pt) })
                .ignoresSafeArea()
            VStack(spacing: theme.space(.s)) {
                topBar
                if drawing {
                    SaryBanner(text: "اضغط على الخريطة لإضافة نقطة، واسحب أي نقطة لتعديلها.", tone: .info, systemImage: "hand.tap.fill")
                        .background(RoundedRectangle(cornerRadius: SaryRadius.s).fill(p.surface))
                        .accessibilityIdentifier("plan.drawHint")
                }
                MapTiltButton().frame(maxWidth: .infinity, alignment: .trailing)
                Spacer()
                if let toast {
                    SaryToast(text: toast).accessibilityIdentifier("plan.toast").transition(.opacity)
                }
                panel
            }
            .padding(.horizontal, theme.space(.m))
            .padding(.bottom, theme.space(.s))
        }
        .animation(theme.animation(.snappy), value: toast)
        .task {
            guard !loaded else { return }
            if plan.planPhase != .loaded { await plan.loadPlan() }
            loaded = true
            draft = plan.plan.points
            notes = plan.plan.notes
            destination = plan.plan.destination
            fit()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: RouteFile.contentTypes, allowsMultipleSelection: false) { r in
            if case let .success(urls) = r, let u = urls.first { importFile(u) }
        }
        .sheet(isPresented: Binding(get: { card != nil }, set: { if !$0 { card = nil } })) {
            if let c = card {
                /* Scrolls when the card is taller than the detent (an SE, large text, every action). */
                ScrollView {
                    PointCard(subject: .point(c, name: nil), actions: pointActions, close: { card = nil })
                }
                .scrollBounceBehavior(.basedOnSize)
                .presentationDetents([.height(420), .large])
                .rtl()
            }
        }
        .sheet(isPresented: $searchOpen) {
            CoordinateSearchSheet(near: draft.last ?? myFix.map { LngLat(lng: $0.lng, lat: $0.lat) }, myFix: myFix, actions: pointActions, close: { searchOpen = false })
                .rtl()
        }
        .sheet(isPresented: $notesOpen) { notesSheet.rtl().presentationDetents([.medium, .large]) }
        .sheet(item: Binding(get: { share.map(ShareTarget.init) }, set: { if $0 == nil { share = nil } })) { s in
            ShareSheet(items: [s.url]).presentationDetents([.medium, .large])
        }
        .saryDialog($confirmClear, systemImage: "trash", title: "تمسح المسار؟", message: "تقدر تتراجع عن المسح قبل الحفظ.", confirmTitle: "امسح") {
            push()
            draft = []
            confirmClear = false
        }
        .alert("تنبيه", isPresented: Binding(get: { plan.errorText != nil }, set: { if !$0 { plan.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(plan.errorText ?? "") }
    }

    // MARK: chrome

    private var topBar: some View {
        HStack(spacing: theme.space(.s)) {
            SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "plan.close", action: close)
            VStack(alignment: .leading, spacing: 0) {
                Text("خطة الطلعة").saryText(.headline).foregroundStyle(theme.palette.textPrimary)
                Text(outingName).saryText(.caption).foregroundStyle(theme.palette.textSecondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer()
            SaryIconButton(systemImage: "magnifyingglass", label: "ابحث أو أدخل إحداثية", id: "plan.search") { searchOpen = true }
            if canEdit {
                Button { Task { if await plan.save(TripPlan(route: PlanLineString(draft), notes: notes, destination: destination, updated_at: nil)) {
                    draft = plan.plan.points
                    notes = plan.plan.notes
                    destination = plan.plan.destination
                    flash("حُفظت الخطة")
                } } } label: {
                    SaryButtonLabel(title: "احفظ", systemImage: "checkmark", busy: plan.saving)
                }
                .buttonStyle(.sary(.primary, width: .hug, compact: true))
                .disabled(!dirty || plan.saving)
                .accessibilityIdentifier("plan.save")
            }
        }
        .padding(theme.space(.s))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .control)
    }

    private var panel: some View {
        let p = theme.palette
        let len = PlanGeo.length(draft)
        return VStack(alignment: .leading, spacing: theme.space(.m)) {
            HStack(spacing: theme.space(.l)) {
                stat("المسافة", draft.count >= 2 ? SaryFormat.distance(meters: len) : "—", id: "plan.distance")
                stat("الوقت التقديري", draft.count >= 2 ? "≈ " + SaryFormat.duration(seconds: PlanETA.seconds(meters: len)) : "—", id: "plan.eta")
                stat("النقاط", SaryFormat.number(draft.count), id: "plan.points")
            }
            if draft.count >= 2 {
                Text("الوقت تقديري على متوسط \(SaryFormat.number(Int(PlanETA.offroadKmh))) كم/س في البر.").saryText(.caption).foregroundStyle(p.textTertiary)
            }
            if let d = destination {
                HStack(spacing: theme.space(.s)) {
                    Image(systemName: "flag.checkered.circle.fill").foregroundStyle(Color(UIColor(rgb: PlanMapStyle.color)))
                    Text("الوجهة: \(d.name)").saryText(.subhead, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                        .accessibilityIdentifier("plan.destinationName")
                    Spacer()
                    if canEdit {
                        Button("أزلها") { destination = nil }.buttonStyle(.sary(.plainDestructive, width: .hug, compact: true))
                    }
                }
            }
            if canEdit {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: theme.space(.s)) {
                        tool(drawing ? "إيقاف الرسم" : "ارسم", drawing ? "pencil.slash" : "pencil.tip", id: "plan.draw", active: drawing) { drawing.toggle() }
                        tool("تراجع", "arrow.uturn.backward", id: "plan.undo", disabled: undo.isEmpty) { if let last = undo.popLast() { draft = last } }
                        tool("امسح", "trash", id: "plan.clear", disabled: draft.isEmpty) { confirmClear = true }
                        tool("استورد ملف مسار", "square.and.arrow.down", id: "plan.import", busy: importBusy) { importing = true }
                        tool("النهاية وجهة", "flag.checkered", id: "plan.endAsDestination", disabled: draft.count < 2) {
                            if let e = draft.last { destination = OutingDestination(name: destination?.name ?? "نهاية المسار", lat: e.lat, lng: e.lng) }
                        }
                        tool("ملاحظات", "note.text", id: "plan.notes") { notesOpen = true }
                    }
                }
            } else if !notes.isEmpty {
                Text(notes).saryText(.subhead).foregroundStyle(p.textSecondary).lineLimit(4)
            }
            if plan.plan.hasRoute || plan.plan.destination != nil {
                Button { exportGPX() } label: { SaryButtonLabel(title: "صدّر الخطة كملف مسار", systemImage: SaryIcon.share) }
                    .buttonStyle(.sary(.secondary, compact: true))
                    .accessibilityIdentifier("plan.export")
            }
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.l)
    }

    private func stat(_ k: String, _ v: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).saryNumber(.headline, weight: .bold).foregroundStyle(theme.palette.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            Text(k).saryText(.caption).foregroundStyle(theme.palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(k)
        .accessibilityValue(v)
        .accessibilityIdentifier(id)
    }

    private func tool(_ title: String, _ icon: String, id: String, active: Bool = false, disabled: Bool = false, busy: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { SaryButtonLabel(title: title, systemImage: icon, busy: busy) }
            .buttonStyle(.sary(active ? .primary : .secondary, width: .hug, compact: true))
            .disabled(disabled || busy)
            .accessibilityIdentifier(id)
    }

    private var notesSheet: some View {
        SaryPage(title: "ملاحظات الخطة", close: { notesOpen = false }) {
            TextEditor(text: $notes)
                .saryText(.body)
                .frame(minHeight: 180)
                .padding(theme.space(.s))
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: SaryRadius.s).fill(theme.palette.sunken))
                .accessibilityIdentifier("plan.notesField")
                .onChange(of: notes) { _, v in if v.count > TripPlan.notesMax { notes = String(v.prefix(TripPlan.notesMax)) } }
            Text("\(SaryFormat.number(notes.count))/\(SaryFormat.number(TripPlan.notesMax))").saryNumber(.caption).foregroundStyle(theme.palette.textTertiary)
        }
    }

    // MARK: actions

    private var pointActions: PointActions {
        var a = PointActions(setDestination: nil, addPoint: nil, rally: nil)
        guard canEdit else { return a }
        a.setDestination = { pt, name in
            destination = OutingDestination(name: String((name ?? "الوجهة").prefix(TripPlan.destinationNameMax)), lat: pt.lat, lng: pt.lng)
            card = nil
            searchOpen = false
            focus(pt)
            flash("صارت الوجهة. اضغط «احفظ».")
        }
        /* «الطقس هنا» lives on the live map (it would close this editor and its unsaved edits). */
        a.weatherHere = nil
        /* In the editor «أضف نقطة» extends the planned route (the shared-waypoint composer
           lives on the live map and cannot open over this sheet). */
        a.addPoint = { pt in add(pt); card = nil; searchOpen = false; focus(pt) }
        a.rally = { pt in
            Task { if await plan.setRally(pt, label: nil) { flash("صارت نقطة التجمع") } }
            card = nil
            searchOpen = false
        }
        return a
    }

    private func push() {
        undo.append(draft)
        if undo.count > 200 { undo.removeFirst() }
    }

    private func add(_ pt: LngLat) {
        guard draft.count < TripPlan.maxPoints else { flash("وصلت للحد (٥٠٠٠ نقطة)."); return }
        push()
        draft.append(pt)
    }

    private func move(_ i: Int, _ pt: LngLat) {
        guard draft.indices.contains(i) else { return }
        push()
        draft[i] = pt
    }

    private func fit() {
        cameraSeq += 1
        var pts = draft
        if let d = destination { pts.append(LngLat(lng: d.lng, lat: d.lat)) }
        if pts.isEmpty, let f = myFix { pts = [LngLat(lng: f.lng, lat: f.lat)] }
        if pts.isEmpty { return }
        camera = PlanCamera(kind: .fit(pts), id: cameraSeq)
    }

    private func focus(_ pt: LngLat) {
        cameraSeq += 1
        camera = PlanCamera(kind: .point(pt, zoom: 13), id: cameraSeq)
    }

    private func flash(_ s: String) {
        toast = s
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toast == s { toast = nil }
        }
    }

    private func importFile(_ url: URL) {
        importBusy = true
        Task {
            let r: Result<RouteFile.Imported, RouteFile.ImportError> = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > RouteFile.maxBytes { return .failure(.tooLarge) }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.malformed) }
                return RouteFile.parse(data, fileName: url.lastPathComponent)
            }.value
            importBusy = false
            switch r {
            case let .success(im):
                /* Also kept in exploration's «مسارات GPX» list (this device). */
                TrackLibrary.shared.add(name: im.name ?? url.deletingPathExtension().lastPathComponent, origin: .imported, points: im.points)
                push()
                draft = im.points
                drawing = false
                fit()
                let simplified = im.rawCount > im.points.count ? " (بسّطناه من \(SaryFormat.number(im.rawCount)))" : ""
                flash("استوردنا \(SaryFormat.number(im.points.count)) نقطة\(simplified). اضغط «احفظ».")
            case let .failure(e):
                plan.errorText = e.arabic
            }
        }
    }

    private func exportGPX() {
        do {
            share = try RouteFile.exportFile(name: outingName, plan: plan.plan)
            if plan.plan.hasRoute { TrackLibrary.shared.add(name: outingName, origin: .exported, points: plan.plan.points) }
        } catch { plan.errorText = "تعذّر تجهيز الملف." }
    }
}

extension RouteFile {
    static var contentTypes: [UTType] {
        var t: [UTType] = []
        if let g = UTType(filenameExtension: "gpx") { t.append(g) }
        if let k = UTType(filenameExtension: "kml") { t.append(k) }
        t.append(.xml)
        return t
    }
}
