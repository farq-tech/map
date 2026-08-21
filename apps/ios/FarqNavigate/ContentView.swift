import CoreLocation
import FerrostarCore
import FerrostarSwiftUI
import MapboxMaps
import SwiftUI

/// The map screen, laid out the way the web lays it out: chrome floating over
/// the map at the top, the sheet holding the answer at the bottom, and the map
/// itself carrying everything else.
struct ContentView: View {
    @StateObject private var location = LocationProvider()
    @StateObject private var model = OpportunitiesModel()
    @StateObject private var navigation = NavigationModel()
    @State private var query = ""
    @State private var lens: DistrictLens = .gap
    @State private var sort: OpportunitySort = .gap

    var body: some View {
        ZStack(alignment: .top) {
            FarqMapView(
                opportunities: model.all,
                districts: model.districts,
                lens: lens,
                route: navigation.routes.first,
                userLocation: location.location?.coordinate,
                isNavigating: navigation.state == .navigating
            )

            if navigation.state == .navigating {
                guidance(navigation)
            } else {
                browsing
            }
        }
        .background(Farq.brand900)
        .task {
            location.request()
            await model.load()
            await smokeRouteIfRequested()
        }
        .onAppear {
            /* Ferrostar keeps its own location provider, and it has to be
             * running before the first route is asked for — otherwise the
             * navigate button answers «نحتاج موقعك أولاً» to someone whose
             * position is already on the screen. */
            navigation.startLocationUpdates()
        }
    }

    /// Drive the whole tap → route → guidance path from a launch argument, so
    /// it can be run without a finger on the glass.
    ///
    /// A navigation app whose navigation has never been run end to end is not
    /// finished, and the one path that cannot be checked by reading the code is
    /// the one that crosses into Ferrostar and out to a routing server.
    private func smokeRouteIfRequested() async {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-farq-smoke-route"),
              let target = model.all.first(where: { $0.destination != nil })
        else { return }
        /* A first fix takes a moment; the button a person presses is not
         * pressed a millisecond after the list arrives. */
        try? await Task.sleep(for: .seconds(3))
        await navigation.planRoute(to: target)
        NSLog("[farq-nav] smoke: %@ → %@", target.name, String(describing: navigation.state))
        #endif
    }

    // MARK: Browsing

    private var browsing: some View {
        VStack(spacing: 0) {
            FarqTopChrome(
                query: $query,
                lens: $lens,
                districtLabel: "اختر حي",
                onPickDistrict: {}
            )
            .padding(.top, 8)

            Spacer(minLength: 0)

            if let message = model.error ?? navigationFailure {
                Text(message)
                    .font(Farq.font(12.5, .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(hex: 0xB3202B).opacity(0.94), in: Capsule())
                    .padding(.bottom, 10)
                    .padding(.horizontal, 16)
            }

            OpportunitySheet(
                opportunities: model.visible(sort),
                comparisonsTotal: model.comparisonsTotal,
                freshness: model.freshness,
                sort: $sort,
                onNavigate: { opportunity in
                    Task { await navigation.planRoute(to: opportunity) }
                },
                onSelect: { _ in }
            )
            .frame(height: 330)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var navigationFailure: String? {
        if case .failed(let why) = navigation.state { return why }
        return nil
    }

    // MARK: Guiding

    /// Banner, progress and the way out — all from FerrostarSwiftUI, which
    /// imports no renderer, so this looks and speaks the same whichever map is
    /// underneath it.
    @ViewBuilder
    private func guidance(_ navigation: NavigationModel) -> some View {
        VStack(spacing: 0) {
            if let visual = navigation.core?.state?.currentVisualInstruction {
                InstructionsView(
                    visualInstruction: visual,
                    distanceToNextManeuver: navigation.core?.state?
                        .currentProgress?.distanceToNextManeuver,
                    remainingSteps: navigation.core?.state?.remainingSteps
                )
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            Spacer()
            if let progress = navigation.core?.state?.currentProgress {
                TripProgressView(progress: progress) { navigation.stop() }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
            } else {
                Button("إنهاء التوجيه") { navigation.stop() }
                    .font(Farq.font(15, .bold))
                    .foregroundStyle(Farq.brand900)
                    .padding(.horizontal, 24)
                    .frame(height: Farq.tapTarget)
                    .background(Farq.mint, in: Capsule())
                    .padding(.bottom, 28)
            }
        }
    }
}

/// Loads what is cheap nearby, and keeps the failure honest.
@MainActor
final class OpportunitiesModel: ObservableObject {
    @Published private(set) var all: [Opportunity] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var freshness: String?
    @Published private(set) var districts: FeatureCollection?

    private let api = FarqAPI()

    var comparisonsTotal: Int { all.reduce(0) { $0 + $1.comparisons } }

    /// The same four orderings the web offers.
    ///
    /// «الأعلى نسبة» carries a floor in riyals for the reason measured on the
    /// web: ranking by percentage alone puts a nine-riyal can of soft drink at
    /// the top, and a share of nothing is not an opportunity.
    func visible(_ sort: OpportunitySort) -> [Opportunity] {
        switch sort {
        case .gap:
            return all.sorted { ($0.gap ?? 0) > ($1.gap ?? 0) }
        case .cheap:
            return all
                .filter { $0.cheapestPrice != nil }
                .sorted { ($0.cheapestPrice ?? 0) < ($1.cheapestPrice ?? 0) }
        case .value:
            let ratio: (Opportunity) -> Double = {
                guard let dear = $0.expensivePrice, dear > 0, let gap = $0.gap else { return 0 }
                return gap / dear
            }
            return all.sorted {
                let meaningful = { (o: Opportunity) in (o.gap ?? 0) >= 15 }
                if meaningful($0) != meaningful($1) { return meaningful($0) }
                return ratio($0) > ratio($1)
            }
        case .near:
            /* Without an observed location there is no "nearest", so the order
             * does not silently become something else — it stays the default. */
            return all.sorted { ($0.gap ?? 0) > ($1.gap ?? 0) }
        }
    }

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            all = try await api.opportunities()
        } catch let failure {
            error = failure.localizedDescription
        }
        /* Boundaries are the backdrop, not the answer. If they fail to load the
         * opportunities still stand on their own, so this failure is not raised
         * over the screen. */
        districts = try? await api.districts()
    }
}
