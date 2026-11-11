import SwiftUI

#if DEBUG
/// DEBUG ONLY: the CarPlay map view controller and the CarPlay presenters' exact output, drawn
/// on the PHONE screen (landscape-shaped frame), for screenshots when a CarPlay display cannot
/// be attached to the simulator. It is NOT the CarPlay template UI (that is drawn by iOS).
/// `-SaryCarPlayPreview map|members|wayback|sos|mysos` (+ `-SaryCarPlayNight 1`).
struct CarPlayPhonePreview: View {
    let mode: String
    let night: Bool
    @State private var input: CarPlayInput?
    @State private var guidance: CarPlayGuidance?
    @State private var backTrack: BackTrack?
    @State private var content = CarPlayMapContent()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = w * 0.6
            VStack(spacing: 8) {
                Text("معاينة DEBUG على الجوال لشاشة CarPlay (الخريطة + نصوص CarPlay) — ليست واجهة CarPlay نفسها")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ZStack(alignment: .top) {
                    CarPlayMapRepresentable(content: content, night: night)
                    banner
                }
                .frame(width: w, height: h)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .environment(\.colorScheme, night ? .dark : .light)
                panel.frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.top, 60)
        }
        .padding(.horizontal, 10)
        .background(night ? Color.black : Color(white: 0.93))
        .environment(\.layoutDirection, .rightToLeft)
        .onReceive(tick) { _ in update() }
        .onAppear { update() }
    }

    @ViewBuilder private var banner: some View {
        if let g = guidance {
            HStack(spacing: 12) {
                Image(systemName: g.symbol).font(.system(size: 34, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(g.instruction).font(.title3.bold())
                    Text(g.detail).font(.footnote)
                    if let r = g.remainingM { Text("باقي \(ArabicFormat.distance(r))").font(.footnote.bold()) }
                }
                Spacer()
            }
            .foregroundStyle(.white).padding(10)
            .background(Color(red: 0.02, green: 0.2, blue: 0.2).opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
            .padding(8)
            .frame(maxWidth: 300, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var panel: some View {
        let fg: Color = night ? .white : .black
        if let i = input {
            switch mode {
            case "members":
                VStack(alignment: .leading, spacing: 6) {
                    Text("الأصدقاء — " + CarPlayPresenter.mySharingLine(i)).font(.headline)
                    ForEach(CarPlayPresenter.memberRows(i)) { r in
                        HStack {
                            Image(uiImage: CarPlayCoordinator.dot(r.color, live: r.isLive, alert: r.sos || r.stuck))
                            VStack(alignment: .leading) {
                                Text(r.name).font(.body.bold())
                                Text(r.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if r.position != nil { Text("أظهره").font(.caption.bold()) }
                            if r.phone != nil { Text("اتصال").font(.caption.bold()) }
                        }
                    }
                }.foregroundStyle(fg)
            case "sos":
                if let a = CarPlayAlerts.current(i, guidance: guidance).first {
                    alertCard(a.title, a.subtitle, a.phone != nil ? ["أظهره", "اتصال"] : ["أظهره", "تمام"])
                }
            case "mysos":
                alertCard("ترسل نداء استغاثة لكل الطلعة؟", "خطوتين: «نداء» ثم التأكيد", ["نعم، أرسل النداء", "لا"])
            case "wayback":
                if let g = guidance, g.offTrack { alertCard("خرجت عن الطريق", g.detail, ["تمام"]) }
            default:
                EmptyView()
            }
        }
    }

    private func alertCard(_ title: String, _ subtitle: String, _ actions: [String]) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title3.bold())
            Text(subtitle).font(.subheadline)
            HStack { ForEach(actions, id: \.self) { Text($0).font(.headline).padding(.horizontal, 14).padding(.vertical, 8).background(.gray.opacity(0.3), in: Capsule()) } }
        }
        .foregroundStyle(night ? .white : .black)
        .padding().frame(maxWidth: .infinity)
        .background(night ? Color(white: 0.15) : .white, in: RoundedRectangle(cornerRadius: 14))
    }

    private func update() {
        guard let s = AppDelegate.model?.session else { return }
        let i = CarPlayCoordinator.makeInput(s)
        input = i
        if mode == "wayback" {
            if backTrack == nil { backTrack = BackTrack(s.trail) }
            if var bt = backTrack, let me = i.myPosition {
                guidance = CarPlayGuide.wayBack(bt.update(me), course: i.course)
                backTrack = bt
            }
        }
        var c = CarPlayMapContent()
        c.cars = CarPlayPresenter.mapCars(i)
        let runs = s.trail.runs
        c.trailSolid = runs.solid
        c.trailGaps = runs.gaps
        c.start = s.trail.start?.position
        c.rally = CarPlayPresenter.rally(i)
        c.destination = CarPlayPresenter.destination(i)
        c.highlightTrail = mode == "wayback"
        content = c
    }
}

private struct CarPlayMapRepresentable: UIViewControllerRepresentable {
    var content: CarPlayMapContent
    var night: Bool
    func makeUIViewController(context: Context) -> CarPlayMapViewController { CarPlayMapViewController() }
    func updateUIViewController(_ vc: CarPlayMapViewController, context: Context) {
        vc.loadViewIfNeeded()
        vc.night = night
        vc.zoom = 13.2
        vc.show(content)
    }
}

extension View {
    /// DEBUG hook, like `saryShowcaseIfRequested`: replaces the screen only with `-SaryCarPlayPreview`.
    @ViewBuilder func saryCarPlayPreviewIfRequested(_ args: [String] = ProcessInfo.processInfo.arguments) -> some View {
        if let i = args.firstIndex(of: "-SaryCarPlayPreview"), i + 1 < args.count {
            let night = args.firstIndex(of: "-SaryCarPlayNight").map { $0 + 1 < args.count && args[$0 + 1] == "1" } ?? false
            ZStack {
                self
                CarPlayPhonePreview(mode: args[i + 1], night: night).ignoresSafeArea()
            }
        } else {
            self
        }
    }
}
#else
extension View {
    func saryCarPlayPreviewIfRequested() -> some View { self }
}
#endif
