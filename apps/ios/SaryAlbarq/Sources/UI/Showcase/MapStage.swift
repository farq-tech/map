#if DEBUG
import SwiftUI

/// Full composition over procedural terrain: status capsule, alert lane,
/// cars with name chips, a note, rally flag, edge arrows, the control
/// cluster, SOS + push-to-talk, and the REAL native sheet with three detents.
/// Used to judge legibility and spacing of chrome over a map.
struct MapStage: View {
    var lab: ShowcaseLab
    var close: () -> Void

    @Environment(\.sary) private var theme
    @State private var expanded = false
    @State private var alerts = Array(Mock.alerts.prefix(2))
    @State private var sheetShown = true
    @State private var detent: SheetDetentUI = .peek
    @State private var tab: LiveTabUI = .group
    @State private var sheetHeight: CGFloat = 0
    @State private var following = true
    @State private var ptt: PTTStateUI = .idle
    @State private var sos: MySOSUI = .none

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                DesertTerrainView()
                SaryMapOverlayLayer {
                    carsLayer(size: size)
                    edgeChips(size: size)
                }
                chrome(size: size, safeTop: geo.safeAreaInsets.top)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            if let d = lab.sheet { detent = d }
            if theme.drive { alerts = Array(alerts.prefix(1)) }
        }
        .sheet(isPresented: $sheetShown) {
            ShowcaseThemed(lab: lab) {
                SheetBody(tab: $tab, detent: detent, expand: { detent = detent == .peek ? .half : .peek })
                    .padding(.top, theme.space(.s))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background {
                        GeometryReader { g in
                            Color.clear
                                .onAppear { sheetHeight = g.size.height }
                                .onChange(of: g.size.height) { _, h in sheetHeight = h }
                        }
                    }
                    .sarySheetPresentation(detent: $detent)
            }
        }
    }

    // MARK: Map content

    private func carsLayer(size: CGSize) -> some View {
        ZStack {
            SaryRallyFlag(marker: .init(label: "نقطة التجمع"))
                .saryMapPoint(size.width * 0.70, size.height * 0.36)
            stageCar(Mock.fahad, heading: 30, note: true).saryMapPoint(size.width * 0.52, size.height * 0.47)
            stageCar(Mock.me, heading: 25).saryMapPoint(size.width * 0.40, size.height * 0.60)
            stageCar(Mock.saad, heading: 140).saryMapPoint(size.width * 0.24, size.height * 0.40)
        }
    }

    private func stageCar(_ p: ParticipantUI, heading: Double, note: Bool = false) -> some View {
        VStack(spacing: 3) {
            if note, let n = p.note, !theme.drive { SaryNoteBubble(bubble: .init(text: n, color: p.color)) }
            if theme.nameDisplay == .always || p.isMe {
                SaryNameChip(chip: .init(name: p.name, color: p.color, isMe: p.isMe, presence: p.presence, hasVoice: p.hasVoice, now: Mock.now))
            }
            SaryCarMarker(color: p.color, heading: heading, presence: p.presence, isMe: p.isMe)
        }
    }

    private func edgeChips(size: CGSize) -> some View {
        ZStack {
            SaryEdgeArrowChip(chip: .init(name: "نورة", color: SaryCarColors.palette[2], distanceMeters: 2_400, bearingDegrees: 285, isStale: false))
                .saryMapPoint(62, size.height * 0.31)
            if !theme.drive && detent == .peek {
                SaryEdgeArrowChip(chip: .init(name: "ريم", color: SaryCarColors.palette[4], distanceMeters: 12_300, bearingDegrees: 200, isStale: true))
                    .saryMapPoint(size.width * 0.5, size.height - bottomInset - 60)
            }
        }
    }

    // MARK: Chrome

    private var bottomInset: CGFloat {
        detent == .full ? 0 : max(sheetHeight, SheetDetentUI.peekHeight(drive: theme.drive))
    }

    private func chrome(size: CGSize, safeTop: CGFloat) -> some View {
        let items = theme.drive
            ? Array(SaryMapControlItem.liveDefaults(following: following).prefix(2))
            : SaryMapControlItem.liveDefaults(following: following, unreadNotes: 1)
        let rowMode = detent == .half
        return ZStack {
            // Top: status + alert lane
            VStack(spacing: theme.space(.s)) {
                if case .active(let since) = sos {
                    SaryMySOSStrip(since: since, now: Date(), imOK: { sos = .none })
                }
                SaryStatusCapsule(outingName: "طلعة الثمامة", status: .active, connection: .connected, sharing: .sharing,
                                  warnings: theme.drive ? [] : [.keepScreenOn], expanded: $expanded, back: close)
                if !rowMode {
                    SaryAlertLane(alerts: alerts, limit: theme.drive ? 1 : SaryAlertLane.defaultLimit, dismiss: { id in alerts.removeAll { $0.id == id } })
                }
                Spacer()
            }
            .padding(.horizontal, theme.space(.m))
            .padding(.top, 4)

            // Controls: column on the trailing edge; morph to a row above the sheet at half height.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if !rowMode {
                        SaryControlCluster(items: items, axis: .vertical) { id in if id == "locate" { following.toggle() } }
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, theme.space(.m))
                Spacer().frame(height: bottomInset + (theme.drive ? 176 : 150))
            }

            // Bottom: SOS + PTT just above the sheet; at half height the cluster joins them as a row.
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    SaryPTTButton(state: ptt, actions: pttActions, showsCaption: !rowMode)
                    Spacer()
                    if rowMode {
                        SaryControlCluster(items: items, axis: .horizontal) { id in if id == "locate" { following.toggle() } }
                            .transition(.opacity)
                        Spacer()
                    }
                    SarySOSButton(state: sos) {
                        sos = .sending
                        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); sos = .active(since: Date()) }
                    }
                    .padding(.bottom, rowMode ? 0 : 22)
                }
                .padding(.horizontal, theme.space(.l))
                .padding(.bottom, bottomInset + theme.space(.m))
                .opacity(detent == .full ? 0 : 1)
            }
        }
        .animation(theme.animation(.smooth), value: detent)
        .animation(theme.animation(.smooth), value: sheetHeight)
    }

    private var pttActions: PTTActions {
        PTTActions(
            pressBegan: { ptt = .talking(seconds: 3, remaining: 57) },
            pressEnded: { ptt = .idle },
            cancelled: { ptt = .idle }
        )
    }
}
#endif
