import SwiftUI

/// The on-screen alert when a camera is coming up on the route. Bound to
/// `CameraHazardProvider.latestAlert`; it shows the text the voice hook also
/// reads. Imminent alerts are warmer and heavier than approach ones.
struct CameraAlertBanner: View {
    var alert: CameraAlert
    var dismiss: () -> Void = {}
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        let imminent = alert.tier == .imminent
        HStack(spacing: theme.space(.m)) {
            Image(systemName: alert.camera.kind.symbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(p.onEmergency)
                .frame(width: 40, height: 40)
                .background(Circle().fill(imminent ? p.emergency : p.warning))
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.text)
                    .saryText(.headline, weight: .bold)
                    .foregroundStyle(p.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if alert.camera.source == .user {
                    Text("مبلّغ من المستخدمين")
                        .saryText(.caption)
                        .foregroundStyle(p.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space(.m))
        .padding(.vertical, theme.space(.s))
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(p.elevated))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(p.stroke, lineWidth: 1))
        .shadow(color: p.shadow.opacity(0.25), radius: 10, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(alert.text)
        .accessibilityIdentifier("camera.alert")
        .onTapGesture(perform: dismiss)
    }
}

/// «كاميرا هنا»: a driver flags a camera at their current position. Lives in the
/// tools/overflow, not among the always-visible buttons. One tap opens a short
/// kind chooser, then the report goes with the driver's location only.
struct CameraReportButton: View {
    /// The report action (kind) — wired by the caller to `CamerasAPI.report`.
    var report: (CameraKind) async -> Void
    var compact = true
    @Environment(\.sary) private var theme
    @State private var choosing = false
    @State private var state: State = .idle

    private enum State { case idle, sending, done }

    var body: some View {
        Button {
            if state == .idle { choosing = true }
        } label: {
            Label(label, systemImage: state == .done ? "checkmark.circle.fill" : "camera.badge.ellipsis")
        }
        .buttonStyle(.sary(.secondary, width: compact ? .hug : .fill, compact: compact))
        .disabled(state != .idle)
        .accessibilityIdentifier("camera.report")
        .confirmationDialog("ما نوع الكاميرا هنا؟", isPresented: $choosing, titleVisibility: .visible) {
            ForEach([CameraKind.mobile, .fixed, .red_light, .avg_speed], id: \.rawValue) { kind in
                Button(kind.arabic) { send(kind) }
            }
            Button("إلغاء", role: .cancel) {}
        } message: {
            Text("يُرسَل موقعك الحالي فقط. كلما بلّغ أكثر من سائق، ظهرت الكاميرا للجميع.")
        }
    }

    private var label: String {
        switch state {
        case .idle: return "كاميرا هنا"
        case .sending: return "جارٍ الإرسال…"
        case .done: return "شكرًا، سُجّل"
        }
    }

    private func send(_ kind: CameraKind) {
        state = .sending
        Task {
            await report(kind)
            state = .done
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            state = .idle
        }
    }
}

#if DEBUG
import MapboxMaps

extension View {
    /// Attach to the app's root view (mirrors `saryShowcaseIfRequested`). In DEBUG
    /// builds launched with `-SaryCamerasDemo` it shows the cameras demo — the map
    /// layer, the approach/imminent banner, and the report button — for simulator
    /// screenshots; otherwise it returns the view untouched.
    @ViewBuilder
    func saryCamerasDemoIfRequested() -> some View {
        if ProcessInfo.processInfo.arguments.contains("-SaryCamerasDemo") {
            CameraDemoScreen()
        } else {
            self
        }
    }
}

/// A self-contained demo of the three pieces — the map layer, the approach/
/// imminent banner, and the report button — reachable with the launch argument
/// `-SaryCamerasDemo`. It touches none of the live navigation screens; it builds
/// its own map so the camera layer can be seen and screenshotted in the simulator.
struct CameraDemoScreen: View {
    @Environment(\.sary) private var theme
    @State private var tier: CameraAlert.Tier = .approach

    private let demoCameras: [SpeedCamera] = [
        .init(id: "d1", lat: 24.7136, lon: 46.6753, bearing: nil, kind: .fixed, speed_limit: 120, source: .official, confidence: 0.95),
        .init(id: "d2", lat: 24.7176, lon: 46.6820, bearing: nil, kind: .red_light, speed_limit: nil, source: .osm, confidence: 0.8),
        .init(id: "d3", lat: 24.7096, lon: 46.6700, bearing: nil, kind: .mobile, speed_limit: nil, source: .user, confidence: 0.6),
    ]

    private var alert: CameraAlert {
        let c = demoCameras[0]
        return tier == .approach
            ? CameraAlert(camera: c, tier: .approach, distanceM: 500, text: CameraVoice.approach(500, kind: c.kind))
            : CameraAlert(camera: demoCameras[1], tier: .imminent, distanceM: 90, text: CameraVoice.imminent(.red_light))
    }

    var body: some View {
        ZStack(alignment: .top) {
            CameraDemoMap(cameras: demoCameras).ignoresSafeArea()
            VStack(spacing: theme.space(.m)) {
                CameraAlertBanner(alert: alert)
                HStack {
                    CameraReportButton(report: { _ in try? await Task.sleep(nanoseconds: 600_000_000) })
                    Spacer()
                    Button(tier == .approach ? "التالي: قدّامك" : "السابق: على بُعد") {
                        tier = tier == .approach ? .imminent : .approach
                    }
                    .buttonStyle(.sary(.primary, width: .hug, compact: true))
                    .accessibilityIdentifier("camera.demo.toggle")
                }
            }
            .padding(theme.space(.m))
        }
        .accessibilityIdentifier("camera.demo")
    }
}

/// A bare Mapbox map centred on Riyadh with the camera layer drawn on it.
private struct CameraDemoMap: UIViewRepresentable {
    var cameras: [SpeedCamera]

    func makeUIView(context: Context) -> MapView {
        let map = MapView(frame: .zero)
        map.mapboxMap.setCamera(to: CameraOptions(center: .init(latitude: 24.7136, longitude: 46.6753), zoom: 13.5))
        map.mapboxMap.onStyleLoaded.observeNext { _ in
            CameraMapLayer.ensure(map.mapboxMap)
            CameraMapLayer.update(map.mapboxMap, cameras: cameras)
        }.store(in: &context.coordinator.tokens)
        return map
    }

    func updateUIView(_ map: MapView, context: Context) {
        guard map.mapboxMap.isStyleLoaded else { return }
        CameraMapLayer.ensure(map.mapboxMap)
        CameraMapLayer.update(map.mapboxMap, cameras: cameras)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var tokens: Set<AnyCancelable> = [] }
}
#endif
