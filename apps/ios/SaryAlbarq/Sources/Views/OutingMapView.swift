import MapKit
import SwiftUI

/// One car on the map.
struct CarItem: Equatable, Identifiable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var color: UInt32
    var name: String
    var freshness: Policy.Freshness
    var ageText: String
    var heading: Double?
    var note: String?
    var isMe: Bool

    static func == (a: CarItem, b: CarItem) -> Bool {
        a.id == b.id && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.color == b.color && a.name == b.name && a.freshness == b.freshness && a.ageText == b.ageText
            && a.heading == b.heading && a.note == b.note && a.isMe == b.isMe
    }
}

/// MapKit, wrapped for iOS 16 (SwiftUI's `Map` gained custom annotations and
/// camera control only in iOS 17). Hybrid imagery reads best over sand.
struct OutingMapView: UIViewRepresentable {
    var cars: [CarItem]
    /// Bumped to ask for a fit-all.
    var fitToken: Int
    /// A member to centre on.
    var focus: (id: String, token: Int)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView()
        m.delegate = context.coordinator
        m.mapType = .hybrid
        m.showsCompass = true
        m.showsScale = true
        m.pointOfInterestFilter = .excludingAll
        m.showsUserLocation = false // you are drawn as your own car, from your own fix
        m.register(CarAnnotationView.self, forAnnotationViewWithReuseIdentifier: CarAnnotationView.reuse)
        m.accessibilityIdentifier = "outing.map"
        /* Riyadh until the first fix arrives. */
        m.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753), latitudinalMeters: 20_000, longitudinalMeters: 20_000), animated: false)
        return m
    }

    func updateUIView(_ m: MKMapView, context: Context) {
        let c = context.coordinator
        var existing: [String: CarAnnotation] = [:]
        for a in m.annotations.compactMap({ $0 as? CarAnnotation }) { existing[a.item.id] = a }
        let ids = Set(cars.map(\.id))
        m.removeAnnotations(existing.values.filter { !ids.contains($0.item.id) })
        for item in cars {
            if let a = existing[item.id] {
                if a.item != item {
                    let moved = a.coordinate.latitude != item.coordinate.latitude || a.coordinate.longitude != item.coordinate.longitude
                    a.item = item
                    if moved {
                        UIView.animate(withDuration: 0.8) { a.coordinate = item.coordinate }
                    }
                    (m.view(for: a) as? CarAnnotationView)?.render(item)
                }
            } else {
                m.addAnnotation(CarAnnotation(item))
            }
        }
        /* Fit on request, and on its own whenever someone new appears — until you move the map yourself. */
        let newIds = ids.subtracting(c.fittedIds)
        if c.lastFit != fitToken || (!newIds.isEmpty && !c.userMoved) {
            if c.lastFit != fitToken { c.userMoved = false }
            c.lastFit = fitToken
            c.fittedIds = ids
            fit(m)
        }
        if let f = focus, f.token != c.lastFocus, let car = cars.first(where: { $0.id == f.id }) {
            c.lastFocus = f.token
            m.setRegion(MKCoordinateRegion(center: car.coordinate, latitudinalMeters: 1_500, longitudinalMeters: 1_500), animated: true)
        }
    }

    private func fit(_ m: MKMapView) {
        let pts = cars.map(\.coordinate)
        guard !pts.isEmpty else { return }
        if pts.count == 1 {
            m.setRegion(MKCoordinateRegion(center: pts[0], latitudinalMeters: 2_000, longitudinalMeters: 2_000), animated: true)
            return
        }
        var rect = MKMapRect.null
        for p in pts {
            let mp = MKMapPoint(p)
            rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0.1, height: 0.1))
        }
        /* Clear of the header (top) and the controls + members panel (bottom). */
        m.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 170, left: 90, bottom: 360, right: 90), animated: true)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastFit = -1
        var fittedIds: Set<String> = []
        var userMoved = false
        var lastFocus = -1

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            /* A pan or pinch by the person (not our own setRegion) stops automatic fitting. */
            let touching = mapView.subviews.first?.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed } ?? false
            if touching { userMoved = true }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? CarAnnotation else { return nil }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: CarAnnotationView.reuse, for: a) as! CarAnnotationView
            v.render(a.item)
            return v
        }
    }
}

final class CarAnnotation: NSObject, MKAnnotation {
    var item: CarItem
    @objc dynamic var coordinate: CLLocationCoordinate2D
    init(_ item: CarItem) {
        self.item = item
        coordinate = item.coordinate
    }
    var title: String? { item.name }
}

final class CarAnnotationView: MKAnnotationView {
    static let reuse = "car"
    private var host: UIHostingController<CarMarker>?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 150, height: 120)
        backgroundColor = .clear
        canShowCallout = false
        collisionMode = .circle
        /* Put the car's centre (not the label's) on the coordinate. */
        centerOffset = CGPoint(x: 0, y: -17)
    }

    required init?(coder: NSCoder) { fatalError() }

    func render(_ item: CarItem) {
        let marker = CarMarker(item: item)
        if let host {
            host.rootView = marker
        } else {
            let h = UIHostingController(rootView: marker)
            h.view.backgroundColor = .clear
            h.view.frame = bounds
            h.view.isUserInteractionEnabled = false
            addSubview(h.view)
            host = h
        }
        /* Every car always shows: MapKit must never hide a friend because two labels overlap. */
        displayPriority = .required
        zPriority = item.isMe ? .max : (item.freshness == .live ? .defaultSelected : .defaultUnselected)
        accessibilityLabel = "\(item.name)، \(ArabicFormat.freshnessLabel(item.freshness))"
        isAccessibilityElement = true
    }
}

/// The car: coloured body, heading arrow only when really moving, name under it,
/// note over it. Old positions are faded and dashed — never drawn as live.
struct CarMarker: View {
    let item: CarItem

    var body: some View {
        let car = Theme.car(item.color)
        let faded = item.freshness != .live
        VStack(spacing: 3) {
            if let note = item.note, !note.isEmpty {
                Text(note)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(Color.black)
                    .shadow(radius: 2)
                    .frame(maxWidth: 140)
            } else {
                Spacer(minLength: 0)
            }
            ZStack {
                if item.freshness == .live {
                    Circle().fill(car.opacity(0.25)).frame(width: 40, height: 40)
                }
                CarShape()
                    .fill(item.freshness == .lost ? Theme.lost : car, style: FillStyle(eoFill: true))
                    .overlay(CarShape().stroke(Color.white, style: StrokeStyle(lineWidth: 2, dash: faded ? [3, 2] : [])))
                    .frame(width: 20, height: 32)
                    .rotationEffect(.degrees(item.heading ?? 0))
                if item.heading != nil {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white)
                        .offset(y: -22)
                        .rotationEffect(.degrees(item.heading ?? 0))
                }
            }
            .frame(width: 44, height: 44)
            .opacity(item.freshness == .recent ? 0.65 : item.freshness == .lost ? 0.85 : 1)
            /* One Text, so the bidi order is the reading order: «نورة · انقطع · قبل ٥ د». */
            (Text(item.isMe ? "أنت" : item.name).font(.system(size: 12, weight: .bold))
                + Text(item.freshness == .live ? "" : " · \(ArabicFormat.freshnessLabel(item.freshness)) · \(item.ageText)").font(.system(size: 10)))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.black.opacity(0.65), in: Capsule())
            .foregroundStyle(Color.white)
        }
        .frame(width: 150, height: 120, alignment: .bottom)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

struct CarShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: r.width * 0.35)
        /* windscreen notch */
        p.addRoundedRect(in: CGRect(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.18, width: r.width * 0.6, height: r.height * 0.2), cornerSize: CGSize(width: 2, height: 2))
        return p
    }
}
