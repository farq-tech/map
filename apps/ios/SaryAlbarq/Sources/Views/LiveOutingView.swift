import CoreLocation
import SwiftUI

struct LiveOutingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationSharer
    @ObservedObject var session: OutingSession
    @State private var camera: MapCameraRequest?
    @State private var showConsent = false
    @State private var showNote = false
    @State private var showMenu = false
    @State private var inviteURL: URL?
    @State private var confirmBack = false
    /// Bottom edge of the top bar and top edge of the bottom panel, in screen points.
    @State private var topChrome: CGFloat = 0
    @State private var bottomChromeTop: CGFloat = 0
    /// A member whose card is open (tapped their car or name on the map).
    @State private var cardFor: String?

    var body: some View {
        let v = session.view
        GeometryReader { screen in
            ZStack(alignment: .top) {
                OutingMapboxView(members: mapMembers(v), camera: camera, chrome: chromeInsets(screen), onMemberTap: carTapped)
                    .ignoresSafeArea()
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        header(v)
                        if session.isSharingNow { SharingBanner(mode: location.effectiveMode, chosen: session.mode) }
                        if let r = session.closedReason { ClosedBanner(reason: r) }
                    }
                    .background(GeometryReader { g in Color.clear.preference(key: TopChromeKey.self, value: g.frame(in: .global).maxY) })
                    Spacer()
                    VStack(spacing: 8) {
                        controls(v)
                        MembersPanel(session: session, myFix: location.lastFix) { id in
                            camera = MapCameraRequest(kind: .withMember(id), id: (camera?.id ?? 0) + 1)
                        }
                    }
                    .background(GeometryReader { g in Color.clear.preference(key: BottomChromeKey.self, value: g.frame(in: .global).minY) })
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .onPreferenceChange(TopChromeKey.self) { topChrome = $0 }
            .onPreferenceChange(BottomChromeKey.self) { bottomChromeTop = $0 }
        }
        .sheet(isPresented: Binding(get: { cardFor != nil }, set: { if !$0 { cardFor = nil } })) {
            if let id = cardFor, let v, let m = v.members[id] {
                MemberCard(member: m, view: v, color: v.colors[id] ?? 0xFFFFFF, myFix: location.lastFix, tick: session.tick) {
                    cardFor = nil
                    camera = MapCameraRequest(kind: .withMember(id), id: (camera?.id ?? 0) + 1)
                }
                .presentationDetents([.height(320), .medium])
                .rtl()
            }
        }
        .sheet(isPresented: $showConsent) {
            ConsentSheet(hasAlways: location.hasAlways) {
                showConsent = false
                Task { await session.beginSharing() }
            }
            .presentationDetents([.large])
            .rtl()
        }
        .sheet(isPresented: $showNote) { NoteSheet(session: session).rtl() }
        .alert("تنبيه", isPresented: Binding(get: { session.errorText != nil }, set: { if !$0 { session.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(session.errorText ?? "") }
        .onAppear { inviteURL = session.storedInviteURL() }
        .confirmationDialog("أنت تشارك موقعك الآن", isPresented: $confirmBack, titleVisibility: .visible) {
            Button("أوقف المشاركة وارجع", role: .destructive) {
                Task { await session.stopSharing(); model.closeSession() }
            }
            Button("ابقَ في الطلعة", role: .cancel) {}
        } message: {
            Text("الرجوع إلى قائمة الطلعات يوقف مشاركة موقعك. لتبقى المشاركة والشاشة مقفلة، اقفل الشاشة وأنت هنا.")
        }
    }

    /// The map's view of our chrome: what the top bar and the bottom panel cover.
    private func chromeInsets(_ screen: GeometryProxy) -> UIEdgeInsets {
        let full = screen.size.height + screen.safeAreaInsets.top + screen.safeAreaInsets.bottom
        return UIEdgeInsets(top: topChrome, left: 0, bottom: bottomChromeTop > 0 ? max(0, full - bottomChromeTop) : 0, right: 0)
    }

    /// My car opens the note composer; anyone else's opens their card (call, WhatsApp), as on the web.
    private func carTapped(_ id: String) {
        guard let v = session.view else { return }
        if id == v.myId {
            if v.status != .ended { showNote = true }
        } else {
            cardFor = id
        }
    }

    private func mapMembers(_ v: OutingView?) -> [MapMember] {
        _ = session.tick
        guard let v else { return [] }
        let colors = v.colors
        var out: [MapMember] = []
        for m in v.orderedMembers {
            let isMe = m.user_id == v.myId
            if isMe {
                /* Your own car comes from your own GPS — the freshest truth there is. */
                guard let f = location.lastFix else { continue }
                /* iOS sends no new fix while you stand still, so your own fix's age says nothing
                 * about staleness. Only a GPS that has really gone quiet greys you out. */
                let age = Date().timeIntervalSince1970 * 1000 - f.atMs
                let mine: Policy.Freshness = location.gpsState == .denied ? .lost : (age > 5 * 60_000 && session.isSharingNow ? .recent : .live)
                out.append(MapMember(id: m.user_id, position: LngLat(lng: f.lng, lat: f.lat), color: colors[m.user_id] ?? 0xFFFFFF, name: m.display_name,
                                   presence: mine, heading: Policy.trustedHeading(f.heading, speed: f.speed), accuracyM: f.accuracy, atMs: f.atMs,
                                   note: m.note?.text, isMe: true))
                continue
            }
            guard let p = v.positions[m.user_id], let fr = v.freshness(of: m.user_id) else { continue }
            let at = (ISODate.parse(p.recorded_at)?.timeIntervalSince1970 ?? 0) * 1000
            out.append(MapMember(id: m.user_id, position: LngLat(lng: p.lng, lat: p.lat), color: colors[m.user_id] ?? 0xFFFFFF, name: m.display_name,
                               presence: fr, heading: fr == .live ? Policy.trustedHeading(p.heading, speed: p.speed) : nil, accuracyM: p.accuracy, atMs: at,
                               note: m.note?.text, isMe: false))
        }
        return out
    }

    @ViewBuilder private func header(_ v: OutingView?) -> some View {
        HStack(spacing: 10) {
            Button { if session.isSharingNow { confirmBack = true } else { model.closeSession() } } label: {
                Image(systemName: "chevron.backward").font(.headline).padding(10).background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("رجوع")
            .accessibilityIdentifier("live.back")
            VStack(alignment: .leading, spacing: 2) {
                Text(v?.snapshot.outing.name ?? "…").font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    if let st = v?.status { StatusChip(status: st) }
                    LinkBadge(state: session.link)
                }
            }
            Spacer()
            if let inviteURL, v?.status != .ended {
                ShareLink(item: inviteURL, subject: Text("دعوة طلعة"), message: Text("انضم لطلعتنا على سَرى البارق")) {
                    Image(systemName: "person.badge.plus").font(.headline).padding(10).background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel("دعوة")
            }
            Menu {
                if v?.snapshot.me.role == "owner" {
                    switch v?.status {
                    case .created?: Button("ابدأ الطلعة") { Task { await session.setStatus("start") } }
                    case .active?: Button("إيقاف مؤقت") { Task { await session.setStatus("pause") } }
                    case .paused?: Button("استئناف الطلعة") { Task { await session.setStatus("resume") } }
                    default: EmptyView()
                    }
                    if v?.status != .ended { Button("إنهاء الطلعة للجميع", role: .destructive) { Task { await session.setStatus("end") } } }
                }
                Picker("دقة المشاركة", selection: $session.mode) {
                    Text("دقيقة").tag(ShareMode.precise)
                    Text("متوازنة").tag(ShareMode.balanced)
                    Text("موفّرة للبطارية").tag(ShareMode.saver)
                }
                if v?.snapshot.me.role == "owner", v?.status != .ended {
                    Button("رابط دعوة جديد (يلغي القديم)") { Task { if let u = await session.newInviteURL() { inviteURL = u } } }
                }
                if v?.status != .ended { Button("مغادرة الطلعة", role: .destructive) { Task { await session.leave() } } }
            } label: {
                Image(systemName: "ellipsis").font(.headline).padding(12).background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel("خيارات")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private func controls(_ v: OutingView?) -> some View {
        HStack(spacing: 10) {
            if session.isSharingNow {
                Button { Task { await session.stopSharing() } } label: {
                    Label("أوقف المشاركة", systemImage: "location.slash.fill").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .accessibilityIdentifier("live.stopSharing")
            } else if v?.status == .active, session.closedReason == nil {
                Button {
                    if OutingSession.hasConsent(for: session.id) { Task { await session.beginSharing() } } else { showConsent = true }
                } label: {
                    Label("شارك موقعي", systemImage: "location.fill").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .accessibilityIdentifier("live.share")
            } else if v?.status == .created {
                Text(v?.snapshot.me.role == "owner" ? "ابدأ الطلعة من القائمة ⋯ لتبدأ المشاركة." : "تبدأ المشاركة عندما يبدأ صاحب الطلعة.")
                    .font(.callout).padding(10).frame(maxWidth: .infinity).background(.regularMaterial, in: Capsule())
            } else if v?.status == .paused {
                Text("الطلعة متوقفة مؤقتًا. لا أحد يشارك موقعه الآن.")
                    .font(.callout).padding(10).frame(maxWidth: .infinity).background(.regularMaterial, in: Capsule())
            }
            Button { showNote = true } label: { Image(systemName: "text.bubble.fill").font(.title3).padding(12) }
                .background(.regularMaterial, in: Circle())
                .accessibilityLabel("ملاحظة فوق سيارتك")
                .disabled(v?.status == .ended)
            Button { camera = MapCameraRequest(kind: .group, id: (camera?.id ?? 0) + 1) } label: { Label("المجموعة", systemImage: "person.3.fill").font(.subheadline.bold()).padding(.horizontal, 12).padding(.vertical, 11) }
                .background(.regularMaterial, in: Capsule())
                .accessibilityLabel("اعرض المجموعة")
                .accessibilityIdentifier("live.fit")
        }
    }
}

struct LinkBadge: View {
    let state: LiveChannel.State
    var body: some View {
        let (t, c): (String, Color) = {
            switch state {
            case .live: return ("متصل", Theme.accent)
            case .polling: return ("اتصال بطيء", Theme.amber)
            case .connecting: return ("يتصل…", .gray)
            case .offline: return ("بلا شبكة", .red)
            case .closed: return ("مغلق", .gray)
            }
        }()
        Label(t, systemImage: "dot.radiowaves.left.and.right").font(.caption2.bold()).foregroundStyle(c)
    }
}

/// Always visible while your position leaves the phone.
struct SharingBanner: View {
    let mode: ShareMode
    let chosen: ShareMode
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.mint).frame(width: 10, height: 10)
                .scaleEffect(pulse ? 1.4 : 1).opacity(pulse ? 0.5 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
            Text("تشارك موقعك الآن مع أعضاء هذه الطلعة").font(.subheadline.bold())
            Spacer()
            if mode != chosen { Text("وضع توفير البطارية").font(.caption2).foregroundStyle(Theme.amber) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.ink.opacity(0.92), in: Capsule())
        .foregroundStyle(.white)
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("live.sharingBanner")
    }
}

struct ClosedBanner: View {
    let reason: LiveCloseReason
    var body: some View {
        let t: String = {
            switch reason {
            case .outingEnded: return "انتهت الطلعة. توقفت المشاركة وحُذفت المواقع."
            case .removed: return "أزالك صاحب الطلعة. توقفت المشاركة."
            case .left: return "غادرت الطلعة. توقفت المشاركة."
            case .notAMember: return "لست عضوًا في هذه الطلعة."
            case .unauthorized: return "انتهت جلستك على هذا الجهاز."
            case .replaced: return "فُتحت الطلعة على جهاز آخر."
            }
        }()
        Text(t).font(.subheadline.bold()).padding(10).frame(maxWidth: .infinity)
            .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
    }
}

struct MembersPanel: View {
    @ObservedObject var session: OutingSession
    let myFix: DeviceFix?
    var onSelect: (String) -> Void

    var body: some View {
        let v = session.view
        let colors = v?.colors ?? [:]
        ScrollView {
            VStack(spacing: 0) {
                ForEach(v?.orderedMembers ?? []) { m in
                    MemberRow(member: m, view: v!, color: colors[m.user_id] ?? 0xFFFFFF, myFix: myFix, tick: session.tick)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(m.user_id) }
                    Divider()
                }
            }
        }
        .frame(maxHeight: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("live.members")
    }
}

struct MemberRow: View {
    let member: Member
    let view: OutingView
    let color: UInt32
    let myFix: DeviceFix?
    let tick: Int

    var body: some View {
        let isMe = member.user_id == view.myId
        let p = view.positions[member.user_id]
        let fr = view.freshness(of: member.user_id)
        HStack(spacing: 10) {
            Circle().fill(Theme.car(color)).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(isMe ? "\(member.display_name) (أنت)" : member.display_name).font(.subheadline.bold())
                    if member.role == "owner" { Image(systemName: "crown.fill").font(.caption2).foregroundStyle(Theme.amber) }
                }
                Text(detail(isMe: isMe, p: p, fr: fr)).font(.caption).foregroundStyle(.secondary)
                if let n = member.note?.text { Text("«\(n)»").font(.caption).foregroundStyle(Theme.ink) }
            }
            Spacer()
            if !isMe, let phone = member.phone, !phone.isEmpty {
                Link(destination: URL(string: "tel:\(phone)")!) { Image(systemName: "phone.fill").padding(8) }
                    .accessibilityLabel("اتصل بـ\(member.display_name)")
                if let wa = URL(string: "https://wa.me/\(phone.filter(\.isNumber))") {
                    Link(destination: wa) { Image(systemName: "message.fill").padding(8) }
                        .accessibilityLabel("واتساب \(member.display_name)")
                }
            }
            if let fr, !isMe { FreshnessChip(f: fr) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func detail(isMe: Bool, p: Position?, fr: Policy.Freshness?) -> String {
        if isMe { return myFix == nil ? "موقعك غير معروف بعد" : "موقعك من جهازك" }
        guard member.sharing else { return "لا يشارك موقعه" }
        guard let p, let fr else { return member.online == true ? "متصل، بلا موقع بعد" : "لا موقع" }
        var parts: [String] = []
        if let me = myFix {
            let a = Geo.LatLng(lat: me.lat, lng: me.lng), b = Geo.LatLng(lat: p.lat, lng: p.lng)
            parts.append("\(ArabicFormat.distance(Geo.haversineMeters(a, b))) \(Geo.directionLabel(Geo.bearingDeg(a, b)))")
        }
        if fr != .live { parts.append(ArabicFormat.ago(view.positionAgeMs(p))) }
        if let s = p.speed, s >= Policy.stillMps, fr == .live { parts.append("\(ArabicFormat.number((s * 3.6).rounded())) كم/س") }
        return parts.joined(separator: " · ")
    }
}

struct FreshnessChip: View {
    let f: Policy.Freshness
    var body: some View {
        let c: Color = f == .live ? Theme.accent : f == .recent ? Theme.amber : Theme.lost
        Text(ArabicFormat.freshnessLabel(f)).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 3)
            .background(c.opacity(0.18), in: Capsule()).foregroundStyle(c)
    }
}

/// Explicit consent, in Arabic, before any position leaves the phone.
struct ConsentSheet: View {
    let hasAlways: Bool
    var onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "location.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
                    Text("مشاركة موقعك في هذه الطلعة").font(.title2.bold())
                    bullet("lock.fill", "يرى موقعك أعضاء هذه الطلعة فقط، ولا أحد غيرهم.")
                    bullet("iphone.radiowaves.left.and.right", "تستمر المشاركة والشاشة مقفلة أو التطبيق في الخلفية، حتى لا تختفي عن أصحابك في البر. يظهر مؤشر الموقع الأزرق أعلى الشاشة طوال المشاركة.")
                    bullet("stop.circle.fill", "تتوقف تلقائيًا إذا أوقفت المشاركة، أو غادرت، أو أوقف صاحب الطلعة الطلعة أو أنهاها.")
                    bullet("clock.arrow.circlepath", "يحفظ الخادم آخر موقع لك فقط، لا مسارك، ويحذفه عند انتهاء الطلعة.")
                    bullet("battery.75", "تستهلك المشاركة البطارية. اختر «موفّرة للبطارية» من القائمة إن احتجت، وننتقل إليها تلقائيًا عند انخفاض الشحن.")
                    if !hasAlways {
                        Text("بعد الموافقة قد يسألك النظام عن السماح بالموقع «دائمًا». هذا اختياري، ويفيد فقط إن أغلق النظام التطبيق أثناء الطلعة، فيعيد تشغيله ليكمل المشاركة.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button { onAccept() } label: { Text("أوافق، شارك موقعي").bold().frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                        .accessibilityIdentifier("consent.accept")
                    Button("ليس الآن") { dismiss() }
                }
                .padding()
                .background(.bar)
            }
        }
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 24)
            Text(text).font(.body)
        }
    }
}

struct NoteSheet: View {
    @ObservedObject var session: OutingSession
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private let presets = ["بوقف عند المحطة", "انتظروني", "اتبعوني", "عندي عطل", "وصلت", "غرزت، أحتاج سحب"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("عبارة قصيرة تظهر فوق سيارتك", text: $text)
                        .onChange(of: text) { t in if t.count > ServerRules.noteMax { text = String(t.prefix(ServerRules.noteMax)) } }
                    ForEach(presets, id: \.self) { p in Button(p) { text = p } }
                } footer: {
                    Text("تظهر لأعضاء الطلعة ١٥ دقيقة، ويصلهم تنبيه.")
                }
                Section {
                    Button("أرسل") { Task { await session.sendNote(text); dismiss() } }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    if session.view?.me?.note != nil {
                        Button("احذف ملاحظتي", role: .destructive) { Task { await session.sendNote(""); dismiss() } }
                    }
                }
            }
            .navigationTitle("ملاحظة")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct TopChromeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct BottomChromeKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A member's card, opened by tapping their car (the web's member card in OutingLive.tsx):
/// who, how fresh, how far, their note, and call / WhatsApp.
struct MemberCard: View {
    let member: Member
    let view: OutingView
    let color: UInt32
    let myFix: DeviceFix?
    let tick: Int
    var onShowTogether: () -> Void

    var body: some View {
        let p = view.positions[member.user_id]
        let fr = view.freshness(of: member.user_id)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle().fill(Theme.car(color)).frame(width: 22, height: 22).overlay(Circle().stroke(.white, lineWidth: 2)).shadow(radius: 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(member.display_name).font(.title3.bold())
                        if member.role == "owner" { Image(systemName: "crown.fill").font(.caption).foregroundStyle(Theme.amber) }
                    }
                    Text(detail(p, fr)).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let fr { FreshnessChip(f: fr) }
            }
            if let n = member.note?.text {
                Text("«\(n)»").font(.body.bold()).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 1, green: 0xF4 / 255, blue: 0xD6 / 255), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(Color.black)
            }
            HStack(spacing: 10) {
                if let phone = member.phone, !phone.isEmpty, let tel = URL(string: "tel:\(phone)") {
                    Link(destination: tel) { Label("اتصال", systemImage: "phone.fill").bold().frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                        .accessibilityIdentifier("card.call")
                    if let wa = URL(string: "https://wa.me/\(phone.filter(\.isNumber))") {
                        Link(destination: wa) { Label("واتساب", systemImage: "message.fill").bold().frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered).tint(Theme.accent)
                            .accessibilityIdentifier("card.whatsapp")
                    }
                } else {
                    Text("لم يضف رقم جوال").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if p != nil {
                Button { onShowTogether() } label: { Label("اعرضنا معًا على الخريطة", systemImage: "scope").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .accessibilityIdentifier("member.card")
    }

    private func detail(_ p: Position?, _ fr: Policy.Freshness?) -> String {
        guard member.sharing else { return "لا يشارك موقعه" }
        guard let p, let fr else { return "لا موقع بعد" }
        var parts: [String] = []
        if let me = myFix {
            let a = Geo.LatLng(lat: me.lat, lng: me.lng), b = Geo.LatLng(lat: p.lat, lng: p.lng)
            parts.append("\(ArabicFormat.distance(Geo.haversineMeters(a, b))) \(Geo.directionLabel(Geo.bearingDeg(a, b)))")
        }
        if fr != .live { parts.append(ArabicFormat.ago(view.positionAgeMs(p))) }
        if let s = p.speed, s >= Policy.stillMps, fr == .live { parts.append("\(ArabicFormat.number((s * 3.6).rounded())) كم/س") }
        return parts.joined(separator: " · ")
    }
}
