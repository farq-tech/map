import SwiftUI
import UniformTypeIdentifiers

// MARK: - Map chrome

/// Exploration's top bar: back (to the trip map) · «استكشاف» + the layer · bell.
struct ExploreHeader: View {
    var layer: MapLayer
    var bell: Int
    var bellOpen: Bool
    var hasHistory: Bool
    var back: () -> Void
    var exit: () -> Void
    var bellTapped: () -> Void
    @Environment(\.sary) private var theme

    private var barHeight: CGFloat { theme.drive ? 64 : 52 }

    var body: some View {
        let p = theme.palette
        HStack(spacing: theme.space(.s)) {
            /* One back button («تخفيف الزحمة» ١١): out of exploration, back on the trip map. */
            Button(action: exit) {
                Image(systemName: SaryIcon.back)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(p.textPrimary)
                    .frame(width: barHeight, height: barHeight)
                    .saryGlass(Circle(), role: .chrome, interactive: true)
            }
            .buttonStyle(SaryPressStyle())
            .accessibilityLabel(Text("ارجع للطلعة"))
            .accessibilityIdentifier("explore-exit")

            HStack(spacing: theme.space(.s)) {
                Image(systemName: "binoculars.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(p.accentText)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("استكشاف").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                    Text("الطبقة: \(layer.label)").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary).lineLimit(1)
                        .accessibilityIdentifier("explore.layerName")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if bell > 0 || bellOpen || hasHistory {
                    Button(action: bellTapped) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: bellOpen ? "bell.slash.fill" : "bell.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(p.textPrimary)
                                .frame(width: 30, height: 30)
                            if bell > 0 && !bellOpen {
                                Text(SaryFormat.number(bell))
                                    .saryNumber(.micro, weight: .heavy)
                                    .foregroundStyle(p.onAccent)
                                    .padding(.horizontal, 4)
                                    .frame(minWidth: 17, minHeight: 17)
                                    .background(Capsule().fill(p.accent))
                                    .saryBadgeOutset(trailing: 6, top: 4)
                            }
                        }
                        .frame(width: 44, height: barHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryPressStyle())
                    .accessibilityLabel(Text(bell == 0 ? "سجل التنبيهات" : "\(SaryFormat.number(bell)) تنبيهات"))
                    .accessibilityIdentifier("alerts.bell")
                }
            }
            .padding(.leading, theme.space(.m))
            .padding(.trailing, theme.space(.xs))
            .frame(minHeight: barHeight)
            .saryGlass(RoundedRectangle(cornerRadius: barHeight / 2, style: .continuous), role: .chrome)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("explore.header")

        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// The centre crosshair (where «احفظ المكان» and the readout point to). Not touchable.
struct ExploreCrosshair: View {
    @ObservedObject var model: ExploreReadingModel
    @Environment(\.sary) private var theme

    var body: some View {
        GeometryReader { g in
            let pt = model.reading?.screenPoint ?? .zero
            let at = pt == .zero ? CGPoint(x: g.size.width / 2, y: g.size.height / 2) : pt
            ZStack {
                Circle().stroke(Color.black.opacity(0.55), lineWidth: 4).frame(width: 30, height: 30)
                Circle().stroke(Color.white, lineWidth: 2).frame(width: 30, height: 30)
                ForEach(0..<4) { i in
                    Capsule().fill(Color.white)
                        .frame(width: 2.5, height: 10)
                        .overlay(Capsule().stroke(Color.black.opacity(0.5), lineWidth: 0.8))
                        .offset(y: -22)
                        .rotationEffect(.degrees(Double(i) * 90))
                }
                Circle().fill(theme.palette.accent).frame(width: 5, height: 5)
            }
            .position(at)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Coordinates at the crosshair (decimal / DMS), the terrain elevation there, copy and save.
struct ExploreReadout: View {
    @ObservedObject var model: ExploreReadingModel
    var format: CoordinateShare.Format
    var toggleFormat: () -> Void
    var copy: () -> Void
    var save: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let r = model.reading
        HStack(spacing: theme.space(.s)) {
            Button(action: toggleFormat) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.map { ExploreRules.coordinateText($0.center, format) } ?? "…")
                        .saryNumber(.callout, weight: .bold)
                        .foregroundStyle(p.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .accessibilityIdentifier("explore.coordinate")
                    HStack(spacing: 6) {
                        Image(systemName: "mountain.2.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(p.textSecondary)
                        Text(ExploreRules.elevationText(r?.elevationM))
                            .saryNumber(.footnote, weight: .bold)
                            .foregroundStyle(r?.elevationM == nil ? p.textTertiary : p.textSecondary)
                            .accessibilityIdentifier("explore.elevation")
                        Text(format == .decimal ? "· عشري" : "· درجات").saryText(.caption, weight: .bold).foregroundStyle(p.accentText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("اضغط للتبديل بين العشري والدرجات"))
            .accessibilityIdentifier("explore-coord-format")
            SaryIconButton(systemImage: SaryIcon.copy, label: "انسخ الإحداثية", id: "explore-copy", action: copy)
            /* «طيران درون استكشافي» around the crosshair (exploration is never driving). */
            SaryIconButton(systemImage: "rotate.3d", label: "طيران درون استكشافي", id: "explore-drone") {
                if let c = r?.center { MapVisualsHub.shared.fly(to: c) }
            }
            Button(action: save) {
                Label("احفظ", systemImage: "star.fill").labelStyle(.titleAndIcon)
                    .saryText(.subhead, weight: .bold)
            }
            .buttonStyle(.sary(.primary, width: .hug, compact: true))
            .accessibilityLabel(Text("احفظ المكان في أماكني"))
            .accessibilityIdentifier("explore-save")
        }
        .padding(.leading, theme.space(.m))
        .padding(.trailing, theme.space(.s))
        .padding(.vertical, theme.space(.s))
        .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.readout")
    }
}

extension SaryMapControlItem {
    /// Exploration's floating group.
    /// «تخفيف الزحمة» ١٠: three buttons. 3D terrain and «الوضع الواقعي» are in «الطبقات»;
    /// saved places and GPX tracks share one sheet.
    static func explore(terrain3D: Bool, tracksShown: Int) -> [SaryMapControlItem] {
        [
            .layers(active: terrain3D),
            SaryMapControlItem(id: "places", systemImage: "star.fill", label: "أماكني ومساراتي", accessibilityID: "explore-places",
                               badge: tracksShown > 0 ? tracksShown : nil),
            SaryMapControlItem(id: "locate", systemImage: SaryIcon.locate, label: "موقعي", accessibilityID: "outing-locate"),
        ]
    }
}

// MARK: - Layers

/// «الطبقات»: satellite / standard / topographic, the 3D terrain view, and what works offline.
struct ExploreLayersSheet: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject private var offline = OfflineMaps.shared
    @Environment(\.sary) private var theme
    @AppStorage(DrivingRealismPrefs.osmKey) private var osmTracks = true

    var body: some View {
        let p = theme.palette
        SaryPage(title: "الطبقات", close: { controller.modal = nil }) {
            VStack(spacing: theme.space(.s)) {
                ForEach(MapLayer.allCases) { l in
                    let on = controller.mapLayer == l
                    Button { controller.mapLayer = l } label: {
                        HStack(spacing: theme.space(.m)) {
                            Image(systemName: l.systemImage)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(on ? p.onAccent : p.accentText)
                                .frame(width: 46, height: 46)
                                .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(on ? p.accent : p.accent.opacity(0.14)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(l.label).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary)
                                Text(l.detail).saryText(.footnote).foregroundStyle(p.textSecondary)
                                Text(ExploreRules.offlineNote(l, areas: offline.completeAreas, topoAreas: offline.topoAreas))
                                    .saryText(.caption, weight: .bold)
                                    .foregroundStyle(l.canBeOffline && (l == .satellite ? offline.completeAreas : offline.topoAreas) > 0 ? p.liveText : p.textTertiary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(on ? p.accent : p.textTertiary)
                        }
                        .padding(theme.space(.m))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SaryRowPressStyle())
                    .sarySurface(radius: SaryRadius.l)
                    .overlay(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(on ? p.accent : .clear, lineWidth: 2))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("layer.\(l.rawValue)")
                }
            }
            ExploreLayerSections(controller: controller)
        }
        .onAppear { offline.reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.layers.sheet")
    }
}

/// Everything under the base-layer cards of «الطبقات» (imagery, weather, camps, tracks, terrain,
/// realistic mode, offline). Shared by `MapLayersSheet` and the DEBUG-only legacy `ExploreLayersSheet`
/// until S3 moves these into the registry too.
struct ExploreLayerSections: View {
    @ObservedObject var controller: LiveOutingController
    @ObservedObject private var offline = OfflineMaps.shared
    @Environment(\.sary) private var theme
    @AppStorage(DrivingRealismPrefs.osmKey) private var osmTracks = true

    var body: some View {
        let p = theme.palette
        Group {
            HiResLayerSection()
            WeatherLayersSection()
            CampSitesLayerSection(controller: controller)
            SarySection(title: "دروب البر", footer: "اختر مسارًا مقترحًا للوجهة من بيانات صور الأقمار. تظهر الخيارات عند تحديد وجهة للطلعة.") {
                SaryNavRow(title: "مسار برّي إلى الوجهة", detail: "الأسهل أو المتوازن أو الأقصر",
                           systemImage: "point.topleft.down.to.point.bottomright.filled.curvepath", id: "explore-desert-route") {
                    controller.performAction("desertRoute")
                }
                .padding(.horizontal, theme.space(.m))
            }
            SarySection(title: "مسارات البر", footer: "طبعات البر من بيانات OpenStreetMap: خط متقطع بني فاتح بحافة داكنة يُقرأ فوق صور القمر الصناعي، والفاتح للمعبّد. درجة المسار ونوع السطح (رمل، حصى، تراب) غير متوفرة في هذه البيانات بعد. تظهر من تقريب متوسط في الاستكشاف وأثناء القيادة خارج الطرق. \(OffroadTracks.attribution)") {
                SaryToggleRow(title: "مسارات البر (OSM)", subtitle: "طبعات الطرق الترابية مثل OsmAnd",
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill", isOn: $osmTracks, id: "explore-osm-tracks")
                    .padding(.horizontal, theme.space(.m))
            }
            SarySection(title: "التضاريس", footer: "الارتفاع عند علامة الوسط من نموذج الارتفاع، ويظهر «غير متاح» لين تنزل بيانات المنطقة.") {
                /* «تخفيف الزحمة» ١٠: this was a button on the map; now one tap here (the map's «الطبقات» lights up). */
                Button { controller.terrain3D.toggle() } label: {
                    HStack(spacing: theme.space(.m)) {
                        SaryRowIcon(systemImage: "mountain.2.fill", color: controller.terrain3D ? p.accent : nil)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("عرض ثلاثي الأبعاد").saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                            Text("يميل الخريطة ويبرز الجبال والطعوس").saryText(.footnote).foregroundStyle(p.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(controller.terrain3D ? "شغّال" : "طافي")
                            .saryText(.footnote, weight: .bold)
                            .foregroundStyle(controller.terrain3D ? p.onAccent : p.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(controller.terrain3D ? p.accent : p.sunken))
                    }
                    .frame(minHeight: theme.minTarget)
                    .padding(.vertical, theme.space(.xs))
                    .contentShape(Rectangle())
                }
                .buttonStyle(SaryRowPressStyle())
                .padding(.horizontal, theme.space(.m))
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(controller.terrain3D ? "شغّال" : "طافي"))
                .accessibilityAddTraits(controller.terrain3D ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("explore-terrain3d")
            }
            SarySection(title: "الوضع الواقعي", footer: "مدن مجسّمة بصور Apple، وأنت واقف (مو أثناء القيادة).") {
                SaryNavRow(title: "الوضع الواقعي", detail: "شوف المكان مجسّم من فوق",
                           systemImage: RealisticEntryButton.icon, id: "explore-realistic") {
                    controller.modal = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { controller.realisticRequest += 1 }
                }
                .padding(.horizontal, theme.space(.m))
            }
            SarySection(title: "بلا إنترنت") {
                SaryNavRow(title: "الخرائط بلا إنترنت",
                           detail: offline.completeAreas > 0
                               ? "\(SaryFormat.number(offline.completeAreas)) منطقة محفوظة · \(SaryFormat.number(offline.topoAreas)) منها مع الطبوغرافي"
                               : "ما حفظت مناطق بعد",
                           systemImage: "arrow.down.circle.fill", id: "explore-offline") {
                    controller.modal = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { controller.modal = .offlineMaps }
                }
                .padding(.horizontal, theme.space(.m))
            }
        }
    }
}

// MARK: - Saved places

struct SavedPlacesSheet: View {
    let controller: LiveOutingController
    @ObservedObject private var store = SavedPlacesStore.shared
    @EnvironmentObject private var location: LocationSharer
    @Environment(\.sary) private var theme
    @State private var share: ShareItem?
    @State private var deleting: SavedPlace?
    @ObservedObject private var visuals = MapVisualsHub.shared
    @State private var realistic: RealisticScene?

    var body: some View {
        let p = theme.palette
        SaryPage(title: "أماكني المحفوظة", subtitle: "على هذا الجوال فقط", close: { controller.modal = nil }) {
            Button { controller.modal = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { controller.saveCrosshair() } } label: {
                SaryButtonLabel(title: "احفظ مكان علامة الوسط", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.sary(.primary))
            .accessibilityIdentifier("places.addCenter")
            if store.places.isEmpty {
                SaryStateView(kind: .empty(title: "ما حفظت أماكن بعد",
                                           message: "حرّك الخريطة حتى تكون العلامة على المكان واضغط «احفظ»، أو اضغط مطولًا على أي نقطة.",
                                           systemImage: "star"))
                    .sarySurface(radius: SaryRadius.l)
            } else {
                SarySection(title: "\(SaryFormat.number(store.places.count)) مكان") {
                    ForEach(Array(store.places.enumerated()), id: \.element.id) { i, place in
                        if i > 0 { SaryDivider().padding(.leading, 56) }
                        row(place)
                    }
                }
            }
        }
        .sheet(item: $share) { s in ShareSheet(items: [s.text]).presentationDetents([.medium, .large]) }
        .realisticCover($realistic)
        .saryDialog(Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), systemImage: "trash.fill",
                    title: "تحذف «\(deleting?.name ?? "")»؟", message: "ينمسح من أماكنك على هذا الجوال.", confirmTitle: "احذف") {
            if let d = deleting { store.delete(d.id) }
            deleting = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("places.sheet")
        .tint(p.accent)
    }

    private func row(_ place: SavedPlace) -> some View {
        let p = theme.palette
        let me = location.lastFix.map { LngLat(lng: $0.lng, lat: $0.lat) }
        return HStack(spacing: theme.space(.m)) {
            Button { controller.showOnMap(place.position) } label: {
                HStack(spacing: theme.space(.m)) {
                    SaryRowIcon(systemImage: place.icon.systemImage)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.85)
                        Text(CoordinateShare.displayDecimal(place.position)).saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let me { Text(SaryFormat.distance(meters: PlanGeo.meters(me, place.position))).saryNumber(.footnote).foregroundStyle(p.textTertiary) }
                }
                .frame(minHeight: theme.minTarget + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("places.row")
            SaryIconButton(systemImage: RealisticEntryButton.icon, label: "الوضع الواقعي", id: "places.realistic") { realistic = .place(place) }
            Menu {
                Button { controller.showOnMap(place.position) } label: { Label("اعرضه على الخريطة", systemImage: "map") }
                Button { controller.navigateToPlace(place) } label: { Label("ملاحة إليه", systemImage: SaryIcon.directions) }
                Button {
                    controller.modal = nil
                    controller.sheetDetent = .peek
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { MapVisualsHub.shared.fly(to: place.position) }
                } label: { Label(visuals.driving ? "الدرون متوقف أثناء القيادة" : "طيران درون استكشافي", systemImage: "rotate.3d") }
                    .disabled(visuals.driving)
                    .accessibilityIdentifier("places.drone")
                Button { PlanClipboard.copy(CoordinateShare.copy(place.position, controller.coordFormat)); controller.toast("نُسخت الإحداثية") } label: {
                    Label("انسخ الإحداثية", systemImage: SaryIcon.copy)
                }
                Button { share = ShareItem(text: CoordinateShare.pointMessage(place.position, name: place.name, link: .google)) } label: {
                    Label("شارك", systemImage: SaryIcon.share)
                }
                Button {
                    controller.modal = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        controller.modal = .placeEdit(SavedPlaceDraft(id: place.id, point: place.position, name: place.name, icon: place.icon))
                    }
                } label: { Label("عدّل الاسم والأيقونة", systemImage: "pencil") }
                Button(role: .destructive) { deleting = place } label: { Label("احذف", systemImage: "trash") }
                    .accessibilityIdentifier("places.delete")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(p.textSecondary)
                    .frame(width: theme.minTarget, height: theme.minTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("خيارات \(place.name)"))
            .accessibilityIdentifier("places.menu")
        }
        .padding(.horizontal, theme.space(.m))
    }
}

/// Name + icon for a new or existing saved place.
struct SavedPlaceEditSheet: View {
    var draft: SavedPlaceDraft
    var done: (SavedPlaceDraft) -> Void
    var cancel: () -> Void
    @Environment(\.sary) private var theme
    @State private var name = ""
    @State private var icon: SavedPlaceIcon = .pin

    var body: some View {
        let p = theme.palette
        SaryPage(title: draft.id == nil ? "احفظ المكان" : "عدّل المكان", close: cancel) {
            Text(CoordinateShare.displayDecimal(draft.point)).saryNumber(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                .accessibilityIdentifier("placeEdit.coordinate")
            SaryTextField(title: "الاسم", placeholder: "مثل: مخيم الشتاء", text: $name, id: "placeEdit.name", maxLength: SavedPlace.nameMax)
            SarySection(title: "الأيقونة") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.space(.s)), count: 4), spacing: theme.space(.s)) {
                    ForEach(SavedPlaceIcon.allCases) { i in
                        let on = i == icon
                        Button { icon = i } label: {
                            VStack(spacing: 4) {
                                Image(systemName: i.systemImage).font(.system(size: 18, weight: .semibold))
                                Text(i.label).saryText(.caption, weight: .bold)
                            }
                            .foregroundStyle(on ? p.onAccent : p.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(on ? p.accent : p.sunken))
                        }
                        .buttonStyle(SaryPressStyle())
                        .accessibilityLabel(Text(i.label))
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("placeEdit.icon.\(i.rawValue)")
                    }
                }
                .padding(theme.space(.s))
            }
            Button {
                var d = draft
                d.name = name
                d.icon = icon
                done(d)
            } label: { SaryButtonLabel(title: "احفظ", systemImage: "star.fill") }
                .buttonStyle(.sary(.primary))
                .accessibilityIdentifier("placeEdit.save")
            Text("يُحفظ على هذا الجوال فقط، وما نرسله لأحد.").saryText(.footnote).foregroundStyle(p.textTertiary)
        }
        .onAppear {
            name = draft.name
            icon = draft.icon
        }
    }
}

// MARK: - GPX tracks

struct TracksSheet: View {
    let controller: LiveOutingController
    @ObservedObject private var library = TrackLibrary.shared
    @Environment(\.sary) private var theme
    @State private var importing = false
    @State private var busy = false
    @State private var message: (text: String, tone: SaryTone)?
    @State private var shareURL: URL?
    @State private var deleting: SavedTrack?
    @State private var detail: FollowSubject?

    var body: some View {
        let p = theme.palette
        SaryPage(title: "ملفات المسارات", subtitle: "المستوردة والمصدّرة على هذا الجوال", close: { controller.modal = nil }) {
            Button { importing = true } label: { SaryButtonLabel(title: "استورد ملف مسار", systemImage: "square.and.arrow.down", busy: busy) }
                .buttonStyle(.sary(.primary))
                .disabled(busy)
                .accessibilityIdentifier("tracks.import")
            if let m = message { SaryBanner(text: m.text, tone: m.tone) }
            if library.tracks.isEmpty {
                SaryStateView(kind: .empty(title: "ما فيه مسارات بعد",
                                           message: "المسارات اللي تستوردها أو تصدّرها من «الخطة» تظهر هنا، وتقدر تعرضها على الخريطة.",
                                           systemImage: "point.bottomleft.forward.to.point.topright.scurvepath"))
                    .sarySurface(radius: SaryRadius.l)
            } else {
                SarySection(title: "\(SaryFormat.number(library.tracks.count)) مسار", footer: "المسارات المعروضة تظهر على الخريطة في الاستكشاف.") {
                    ForEach(Array(library.tracks.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { SaryDivider().padding(.leading, 56) }
                        row(t)
                    }
                }
            }
            /* Named by the screen that has it (the live tabs are being renamed): the plan editor imports, «ملف المسار» exports. */
            Text("مسار الخطة نفسه يُستورد من محرّر «خطة الطلعة»، ويُصدّر من «ملف المسار» في تفاصيل الطلعة.").saryText(.footnote).foregroundStyle(p.textTertiary)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: RouteFile.contentTypes, allowsMultipleSelection: false) { r in
            if case let .success(urls) = r, let u = urls.first { importFile(u) }
        }
        .sheet(item: Binding(get: { shareURL.map(TrackShareURL.init) }, set: { if $0 == nil { shareURL = nil } })) { s in
            ShareSheet(items: [s.url]).presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $detail) { s in
            TrackDetailView(subject: s, close: { detail = nil }) { chosen in
                detail = nil
                controller.modal = nil
                /* After both covers are gone: the live map frames the track. */
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { controller.startFollow(chosen) }
            }
        }
        .saryDialog(Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), systemImage: "trash.fill",
                    title: "تحذف «\(deleting?.name ?? "")»؟", message: "ينمسح من قائمة المسارات على هذا الجوال. الخطة ما تتأثر.", confirmTitle: "احذف") {
            if let d = deleting { library.delete(d.id) }
            deleting = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tracks.sheet")
    }

    private func row(_ t: SavedTrack) -> some View {
        let p = theme.palette
        let shown = library.shown.contains(t.id)
        return HStack(spacing: theme.space(.m)) {
            Button { controller.showTrack(t) } label: {
                HStack(spacing: theme.space(.m)) {
                    SaryRowIcon(systemImage: t.origin == .imported ? "square.and.arrow.down" : "square.and.arrow.up")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).saryText(.body, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1).minimumScaleFactor(0.85)
                        Text("\(t.origin == .imported ? "مستورد" : "مصدَّر") · \(SaryFormat.distance(meters: t.lengthM)) · \(SaryFormat.number(t.points.count)) نقطة")
                            .saryNumber(.footnote).foregroundStyle(p.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: theme.minTarget + 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tracks.row")
            Button { detail = FollowSubject.gpx(t) } label: {
                Image(systemName: FollowIcon.follow).font(.system(size: 18, weight: .semibold)).foregroundStyle(p.accentText)
                    .frame(width: theme.minTarget, height: theme.minTarget).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("اسلك «\(t.name)»"))
            .accessibilityIdentifier("tracks.follow")
            Toggle("", isOn: Binding(get: { shown }, set: { _ in library.toggleShown(t.id) }))
                .labelsHidden()
                .tint(p.accent)
                .accessibilityLabel(Text("اعرض \(t.name) على الخريطة"))
                .accessibilityIdentifier("tracks.toggle")
            Menu {
                Button { shareURL = try? RouteFile.exportFile(name: t.name, points: t.points) } label: { Label("شارك ملف المسار", systemImage: SaryIcon.share) }
                Button(role: .destructive) { deleting = t } label: { Label("احذف", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 20, weight: .semibold)).foregroundStyle(p.textSecondary)
                    .frame(width: theme.minTarget, height: theme.minTarget).contentShape(Rectangle())
            }
            .accessibilityLabel(Text("خيارات \(t.name)"))
        }
        .padding(.horizontal, theme.space(.m))
    }

    private func importFile(_ url: URL) {
        busy = true
        message = nil
        Task {
            let r: Result<RouteFile.Imported, RouteFile.ImportError> = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > RouteFile.maxBytes { return .failure(.tooLarge) }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.malformed) }
                return RouteFile.parse(data, fileName: url.lastPathComponent)
            }.value
            busy = false
            switch r {
            case let .success(im):
                let name = im.name ?? url.deletingPathExtension().lastPathComponent
                if let id = library.add(name: name, origin: .imported, points: im.points) {
                    library.shown.insert(id)
                    message = ("استوردنا «\(TrackRules.cleanName(name, origin: .imported))» (\(SaryFormat.number(im.points.count)) نقطة) وعرضناه على الخريطة.", .success)
                }
            case let .failure(e):
                message = (e.arabic, .error)
            }
        }
    }
}

private struct TrackShareURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

// MARK: - «أماكني ومساراتي»

/// Saved places and GPX tracks behind ONE exploration button («تخفيف الزحمة» ١٠): two tabs on top,
/// each the sheet it always was.
struct PlacesAndTracksSheet: View {
    enum Part: Hashable { case places, tracks }
    let controller: LiveOutingController
    @State var part: Part
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: 0) {
            /* The design system's segmented control (44 pt, no second accent fill above the sheet's primary). */
            SarySegmented(options: [Part.places, Part.tracks], selection: $part,
                          label: { $0 == .places ? "أماكني" : "مساراتي" },
                          systemImage: { $0 == .places ? "star.fill" : "point.bottomleft.forward.to.point.topright.scurvepath.fill" },
                          optionID: { $0 == .places ? "places.tab" : "explore-tracks" })
            .padding(.horizontal, theme.space(.l))
            .padding(.top, theme.space(.m))
            switch part {
            case .places: SavedPlacesSheet(controller: controller)
            case .tracks: TracksSheet(controller: controller)
            }
        }
    }
}

// MARK: - Lovable's exploration top

/// Exploring (Lovable): no trip header — the three layers as one segmented bar, the crosshair's
/// coordinates under it with copy and save. Our additions, documented: a back chevron (out of
/// exploration) and «الطبقات» (3D terrain, high-res imagery, offline maps) at the bar's ends.
struct ExploreTopBar: View {
    @ObservedObject var controller: LiveOutingController
    var exit: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                if !controller.idleHome { round(SaryIcon.back, label: "ارجع للطلعة", id: "explore-exit", action: exit) }
                HStack(spacing: 0) {
                    ForEach([MapLayer.satellite, .topo, .standard], id: \.self) { l in
                        let on = controller.mapLayer == l
                        Button { controller.mapLayer = l } label: {
                            Text(l.label)
                                .font(.sary(14, .medium))
                                .foregroundStyle(on ? p.onAccent : p.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background { if on { RoundedRectangle(cornerRadius: 20, style: .continuous).fill(p.accent) } }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                        .accessibilityIdentifier("explore.layer.\(l.rawValue)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("الطبقة: \(controller.mapLayer.label)"))
                .accessibilityIdentifier("explore.layerName")
                /* «الطبقات» is the map's one layers button (`map.layers`, first in the side column), not a second one here. */
            }
            /* The round buttons are 44 pt touch areas around 36 pt circles, so the
             * bar's inset is 1 pt (the circles still sit 5 pt from its edge). */
            .padding(1)
            .frame(height: 46)
            .saryGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), role: .chrome)
            /* UI-AUDIT م6: the desert features in the open, not three levels under «الطبقات». */
            HStack(spacing: 8) {
                chip("tent.fill", "الكشتة", id: "explore.camp") { controller.performAction("camp") }
                chip("point.topleft.down.to.point.bottomright.curvepath", "دروب البر", id: "explore.desertRoute") { controller.performAction("desertRoute") }
                Spacer(minLength: 0)
            }
            ExploreCoordinateBar(model: controller.exploreReading, format: controller.coordFormat,
                                 toggleFormat: { controller.coordFormat = controller.coordFormat == .decimal ? .dms : .decimal },
                                 copy: controller.copyCrosshair, save: controller.saveCrosshair)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.header")
    }

    /// «الكشتة» / «دروب البر»: a 44 pt glass capsule under the layer bar.
    private func chip(_ symbol: String, _ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.palette.accentText)
                Text(title).font(.sary(14, .medium)).foregroundStyle(theme.palette.textPrimary).lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .saryGlass(Capsule(), role: .chrome, interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityIdentifier(id)
    }

    private func round(_ symbol: String, label: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? theme.palette.onAccent : theme.palette.textPrimary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(active ? theme.palette.accent : theme.palette.sunken.opacity(0.7)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
    }
}

/// «٢٨٫٠٧١٢° N ٤١٫٦٦٣٣° E» with copy and save (Lovable), the elevation small under it.
struct ExploreCoordinateBar: View {
    @ObservedObject var model: ExploreReadingModel
    var format: CoordinateShare.Format
    var toggleFormat: () -> Void
    var copy: () -> Void
    var save: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let r = model.reading
        HStack(spacing: 4) {
            Button(action: toggleFormat) {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse").font(.system(size: 14, weight: .semibold)).foregroundStyle(p.accentText)
                    VStack(alignment: .leading, spacing: 0) {
                        /* The system number font: Huwiya draws the decimal separator «٫» like a comma
                         * («٢٤,٥…»); SF Arabic draws it as «٫», with tabular digits that hold still while panning. */
                        Text(r.map { ExploreRules.coordinateText($0.center, format) } ?? "…")
                            .saryNumber(.subhead, weight: .medium)
                            .foregroundStyle(p.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .accessibilityIdentifier("explore.coordinate")
                        /* 12 pt secondary: it sits on glass over the map (10 pt tertiary was unreadable in sun). */
                        Text(ExploreRules.elevationText(r?.elevationM))
                            .font(.sary(12, .medium, relativeTo: .caption))
                            .foregroundStyle(p.textSecondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("explore.elevation")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("اضغط للتبديل بين العشري والدرجات"))
            .accessibilityIdentifier("explore-coord-format")
            icon(SaryIcon.copy, label: "انسخ الإحداثية", id: "explore-copy", action: copy)
            icon("bookmark", label: "احفظ المكان في أماكني", id: "explore-save", action: save)
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 44)
        .saryGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), role: .chrome)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("explore.readout")
    }

    private func icon(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.palette.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(SaryPressStyle())
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }
}
