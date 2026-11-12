@_spi(Experimental) import MapboxMaps
import SwiftUI

/// «الخرائط بلا إنترنت»: saved areas, how much space they take against the cap,
/// delete, and «حمّل منطقة» (a box on the map).
struct OfflineMapsView: View {
    var back: () -> Void
    /// Frame this area first in the picker (e.g. the outing's cars).
    var suggested: OfflinePlan.Box? = nil
    var outingName: String? = nil
    @ObservedObject private var store = OfflineMaps.shared
    @Environment(\.sary) private var theme
    @Environment(AppearanceSettings.self) private var appearance
    @State private var picking = false
    @State private var deleting: OfflineArea?

    var body: some View {
        let p = theme.palette
        SaryPage(title: "الخرائط بلا إنترنت", subtitle: "للبر حيث لا تغطية", back: back) {
            usage
            if case let .downloading(name, f, bytes) = store.job {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    HStack {
                        Text("ننزّل «\(name)»").saryText(.headline).foregroundStyle(p.textPrimary)
                        Spacer()
                        Text(SaryFormat.percent(Int((f * 100).rounded()))).saryNumber(.subhead, weight: .bold).foregroundStyle(p.accentText)
                    }
                    ProgressView(value: f).tint(p.accent)
                    Text("\(SaryFormat.bytes(bytes)) حتى الآن. تقدر تكمل استخدام التطبيق.").saryText(.footnote).foregroundStyle(p.textSecondary)
                    Button("أوقف التنزيل") { store.cancel() }.buttonStyle(.sary(.plainDestructive, width: .hug, compact: true))
                }
                .padding(theme.space(.m))
                .sarySurface(radius: SaryRadius.m)
                .accessibilityIdentifier("offline.progress")
            } else if case let .failed(m) = store.job {
                SaryBanner(text: m, tone: .error)
            } else if case let .finished(name, bytes) = store.job {
                SaryBanner(text: "«\(name)» جاهزة بلا إنترنت (\(SaryFormat.bytes(bytes))).", tone: .success, systemImage: SaryIcon.checkCircle)
                    .accessibilityIdentifier("offline.finished")
            }
            Button { picking = true } label: { SaryButtonLabel(title: "حمّل منطقة", systemImage: "square.dashed") }
                .buttonStyle(.sary(.primary))
                .disabled({ if case .downloading = store.job { return true }; return false }())
                .accessibilityIdentifier("offline.add")
            if store.loaded && store.areas.isEmpty {
                SaryStateView(kind: .empty(title: "ما حفظت مناطق بعد", message: "قبل الطلعة، وأنت على إنترنت، احفظ منطقتها: الخريطة والطرق والتضاريس تشتغل بعدها بدون تغطية.", systemImage: "map"))
                    .sarySurface(radius: SaryRadius.l)
            }
            if !store.areas.isEmpty {
                SarySection(title: "المناطق المحفوظة") {
                    ForEach(Array(store.areas.enumerated()), id: \.element.id) { i, a in
                        if i > 0 { SaryDivider() }
                        row(a)
                    }
                }
            }
            SarySection(title: "كيف تعمل") {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    Text("• تحفظ صور الأقمار والطرق والتضاريس من مستوى الحي حتى مستوى الشارع (تكبير ١١–١٦).")
                    Text("• الطبقة «الطبوغرافي» (خطوط الكنتور) تُحفظ فقط إذا اخترتها عند التنزيل. الطبقة «العادي» تحتاج إنترنت دائمًا.")
                    Text("• بلا إنترنت تعرض الخريطة المحفوظ تلقائيًا. مواقع الأصدقاء تحتاج إنترنت لتتحدث، لكن مكانك أنت يظهر من إشارة الموقع في جوالك.")
                    Text("• الحد: \(SaryFormat.bytes(OfflinePlan.totalCapBytes)) لكل المناطق معًا، وكل منطقة حتى \(SaryFormat.number(Int(OfflinePlan.maxSideKm))) كم في \(SaryFormat.number(Int(OfflinePlan.maxSideKm))) كم، حتى لا تملأ جوالك.")
                    Text("• تُحدّث المنطقة عند تنزيلها مرة ثانية. يفضّل التنزيل على واي فاي.")
                }
                .saryText(.subhead)
                .foregroundStyle(p.textSecondary)
                .padding(.vertical, theme.space(.s))
            }
        }
        .onAppear { store.reload() }
        .fullScreenCover(isPresented: $picking) {
            OfflineAreaPicker(initial: suggested, outingName: outingName, close: { picking = false })
                .saryPresented(appearance)
        }
        .saryDialog(Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), systemImage: "trash.fill",
                    title: "تحذف «\(deleting?.name ?? "")»؟", message: "تُحذف خرائط هذه المنطقة من الجوال، وتحتاج إنترنت لعرضها.", confirmTitle: "احذف") {
            if let d = deleting { store.delete(d.id) }
            deleting = nil
        }
    }

    private var usage: some View {
        let p = theme.palette
        let used = store.usedBytes
        let frac = min(1, Double(used) / Double(OfflinePlan.totalCapBytes))
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            HStack {
                Text("المساحة المستخدمة").saryText(.subhead).foregroundStyle(p.textSecondary)
                Spacer()
                Text("\(SaryFormat.bytes(used)) من \(SaryFormat.bytes(OfflinePlan.totalCapBytes))").saryNumber(.subhead, weight: .bold).foregroundStyle(p.textPrimary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(p.sunken)
                    Capsule().fill(frac > 0.9 ? p.warning : p.accent).frame(width: max(6, g.size.width * frac))
                }
            }
            .frame(height: 8)
            .environment(\.layoutDirection, .rightToLeft)
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.m)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("offline.usage")
    }

    private func row(_ a: OfflineArea) -> some View {
        let p = theme.palette
        return HStack(spacing: theme.space(.m)) {
            SaryRowIcon(systemImage: a.isComplete ? "map.fill" : "exclamationmark.triangle.fill", color: a.isComplete ? nil : p.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.name).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                Text(detail(a)).saryText(.footnote).foregroundStyle(p.textSecondary)
            }
            Spacer()
            SaryIconButton(systemImage: "trash", label: "احذف \(a.name)", id: "offline.delete") { deleting = a }
        }
        .padding(.vertical, theme.space(.xs))
        .accessibilityIdentifier("offline.area")
    }

    private func detail(_ a: OfflineArea) -> String {
        var parts = [SaryFormat.bytes(a.bytes)]
        if let b = a.box { parts.append("\(SaryFormat.number(Int(b.widthKm.rounded()))) × \(SaryFormat.number(Int(b.heightKm.rounded()))) كم") }
        parts.append(a.layers.contains(.topo) ? "قمر صناعي + طبوغرافي" : "قمر صناعي")
        parts.append(a.isComplete ? "جاهزة بلا إنترنت" : "ناقصة \(SaryFormat.percent(Int(Double(a.completed) / Double(max(1, a.required)) * 100))) — نزّلها مرة ثانية")
        if let d = a.createdAt { parts.append(SaryFormat.elapsed(since: d, now: Date())) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Picking the box

/// A satellite map with a fixed box in the middle: move and zoom the map until the
/// box covers the area, see what it will cost, name it, download.
struct OfflineAreaPicker: View {
    var initial: OfflinePlan.Box?
    var outingName: String?
    var close: () -> Void
    @ObservedObject private var store = OfflineMaps.shared
    @Environment(\.sary) private var theme
    @State private var box: OfflinePlan.Box?
    /// Also save the topographic layer (Mapbox Outdoors) for this area.
    @State private var withTopo = false
    @State private var estimate: Int64?
    @State private var estimating = false
    @State private var name = ""
    @State private var estimateTask: Task<Void, Never>?

    var body: some View {
        let p = theme.palette
        ZStack {
            AreaPickerMap(initial: initial) { b in
                box = b
                scheduleEstimate(b)
            }
            .ignoresSafeArea()
            .accessibilityIdentifier("offline.pickerMap")
            /* The box: the map moves under it. */
            GeometryReader { g in
                let r = AreaPickerMap.boxRect(in: g.size)
                Path { $0.addRect(CGRect(origin: .zero, size: g.size)); $0.addRect(r) }
                    .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 6).stroke(p.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack(spacing: theme.space(.s)) {
                HStack {
                    Text("حرّك الخريطة وكبّرها حتى يغطي المربع منطقة الطلعة")
                        .saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                    Spacer()
                    SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "offline.pickerClose", action: close)
                }
                .padding(theme.space(.m))
                .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .control)
                Spacer()
                panel
            }
            .padding(theme.space(.m))
        }
        .onAppear { if name.isEmpty { name = outingName ?? "منطقة \(SaryFormat.number(store.areas.count + 1))" } }
    }

    private var verdict: OfflinePlan.Verdict? {
        box.map { OfflinePlan.check($0, estimateBytes: estimate, usedBytes: store.usedBytes) }
    }

    private var panel: some View {
        let p = theme.palette
        return VStack(alignment: .leading, spacing: theme.space(.s)) {
            if let b = box {
                HStack {
                    Text("\(SaryFormat.number(Int(b.widthKm.rounded()))) × \(SaryFormat.number(Int(b.heightKm.rounded()))) كم")
                        .saryNumber(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                    Spacer()
                    if estimating {
                        ProgressView().controlSize(.small)
                        Text("نحسب الحجم…").saryText(.footnote).foregroundStyle(p.textSecondary)
                    } else if let e = estimate {
                        Text("≈ \(SaryFormat.bytes(e))").saryNumber(.headline, weight: .bold).foregroundStyle(p.accentText)
                            .accessibilityIdentifier("offline.estimate")
                    } else {
                        Text("الحجم يُعرف أثناء التنزيل").saryText(.footnote).foregroundStyle(p.textSecondary)
                    }
                }
            }
            switch verdict {
            case .tooSmall?: SaryInlineMessage(text: "المنطقة صغيرة جدًا. صغّر الخريطة (ابعد).", tone: .warning)
            case let .tooBig(km)?: SaryInlineMessage(text: "أكبر من \(SaryFormat.number(Int(km))) كم. كبّر الخريطة (قرّب) أو احفظها على أجزاء.", tone: .warning)
            case let .overCap(free)?: SaryInlineMessage(text: "لا تكفي المساحة المسموحة: المتبقي \(SaryFormat.bytes(free)). احذف منطقة قديمة أو صغّر هذه.", tone: .warning)
            default: EmptyView()
            }
            SaryTextField(title: "اسم المنطقة", placeholder: "مثل: نفود الثويرات", text: $name, id: "offline.name", maxLength: 40)
            SaryToggleRow(title: "مع الخريطة الطبوغرافية", subtitle: "خطوط الكنتور والارتفاعات بلا إنترنت · يزيد الحجم",
                          systemImage: MapLayer.topo.systemImage, isOn: $withTopo, id: "offline.topo")
                .onChange(of: withTopo) { _, _ in if let b = box { scheduleEstimate(b) } }
            Button {
                guard let b = box else { return }
                store.download(b, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "منطقة" : name, outing: outingName, topo: withTopo)
                close()
            } label: { SaryButtonLabel(title: "نزّل المنطقة", systemImage: "arrow.down.circle.fill") }
                .buttonStyle(.sary(.primary))
                .disabled(box == nil || verdict != .ok)
                .accessibilityIdentifier("offline.download")
        }
        .padding(theme.space(.l))
        .background(RoundedRectangle(cornerRadius: SaryRadius.xl, style: .continuous).fill(p.elevated))
        .saryShadow(.overlay, theme)
    }

    private func scheduleEstimate(_ b: OfflinePlan.Box) {
        estimateTask?.cancel()
        estimate = nil
        guard OfflinePlan.check(b, estimateBytes: nil, usedBytes: 0) == .ok else { estimating = false; return }
        estimating = true
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            let e = await store.estimate(b, topo: withTopo)
            guard !Task.isCancelled else { return }
            estimate = e
            estimating = false
        }
    }
}

/// The picker's map: same style as the live map, reports the box's coordinates as it moves.
struct AreaPickerMap: UIViewRepresentable {
    var initial: OfflinePlan.Box?
    var changed: (OfflinePlan.Box) -> Void

    /// Height of the chrome around the box (top bar + the bottom panel with its name field,
    /// topo toggle and download button) that the box must not run under.
    static let chromeHeight: CGFloat = 447

    /// The box on screen: centred, between the top bar and the bottom panel. On a 375×667 SE the
    /// 42 % box ran under the panel (the area being saved was hidden behind it), so the side is
    /// also capped by what the chrome leaves; on 812 pt+ phones the cap does not bite.
    static func boxRect(in size: CGSize) -> CGRect {
        let side = max(120, min(size.width - 48, size.height * 0.42, size.height - chromeHeight))
        return CGRect(x: (size.width - side) / 2, y: size.height * 0.36 - side / 2, width: side, height: side)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapView {
        let start = initial?.center ?? LngLat(lng: 46.6753, lat: 24.7136)
        let cam = CameraOptions(center: start.coordinate, zoom: 11)
        let map = MapView(frame: .zero, mapInitOptions: MapInitOptions(cameraOptions: cam, styleURI: ArabicBasemap.cachedJSON == nil ? OutingMapboxView.styleURI : nil))
        if let json = ArabicBasemap.cachedJSON { map.mapboxMap.loadStyle(json) }
        ArabicBasemap.load { json in if let json { map.mapboxMap.loadStyle(json) } }
        SandGrade.follow(map)
        map.ornaments.options.scaleBar.visibility = .visible
        map.ornaments.options.compass.visibility = .hidden
        /* The area is what the flat map shows: no tilting by touch here, and no 2D / 3D button (a tilted view has no rectangle). */
        map.gestures.options.pitchEnabled = false
        map.ornaments.options.logo.position = .bottomLeft
        map.ornaments.options.attributionButton.position = .bottomLeft
        map.ornaments.options.logo.margins = CGPoint(x: 12, y: 300)
        map.ornaments.options.attributionButton.margins = CGPoint(x: 104, y: 300)
        map.ornaments.options.scaleBar.position = .topLeft
        map.ornaments.options.scaleBar.margins = CGPoint(x: 16, y: 96)
        let c = context.coordinator
        c.map = map
        c.changed = changed
        c.cancel = map.mapboxMap.onMapIdle.observe { [weak c] _ in c?.report() }
        if let b = initial {
            DispatchQueue.main.async {
                let coords = [CLLocationCoordinate2D(latitude: b.south, longitude: b.west), CLLocationCoordinate2D(latitude: b.north, longitude: b.east)]
                let r = Self.boxRect(in: map.bounds.size)
                let pad = UIEdgeInsets(top: r.minY + 8, left: r.minX + 8, bottom: map.bounds.height - r.maxY + 8, right: map.bounds.width - r.maxX + 8)
                if let cam = try? map.mapboxMap.camera(for: coords, camera: CameraOptions(), coordinatesPadding: pad, maxZoom: 14, offset: nil) {
                    map.mapboxMap.setCamera(to: cam)
                }
            }
        }
        return map
    }

    func updateUIView(_ map: MapView, context: Context) { context.coordinator.changed = changed }

    final class Coordinator {
        weak var map: MapView?
        var changed: (OfflinePlan.Box) -> Void = { _ in }
        var cancel: AnyCancelable?

        func report() {
            guard let map, map.bounds.width > 0 else { return }
            let r = AreaPickerMap.boxRect(in: map.bounds.size)
            changed(OfflinePlan.Box(map.mapboxMap.coordinateBounds(for: r)))
        }
    }
}
