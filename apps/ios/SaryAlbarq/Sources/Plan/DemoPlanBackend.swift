import Foundation

/// The `-demo` outing's plan and checklist (screenshots, UI tests). In memory,
/// clearly a demo, never talks to the server.
final class DemoPlanBackend: PlanBackend {
    private var plans: [String: TripPlan] = [:]
    private var lists: [String: [ChecklistItem]] = [:]
    private var seq = 100
    /// `-demoPlanUnavailable`: behave like a server without the endpoints (404).
    private let unavailable: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let empty = arguments.contains("-demoPlanEmpty")
        unavailable = arguments.contains("-demoPlanUnavailable")
        let route: [LngLat] = [
            .init(lng: 46.6705, lat: 24.7080), .init(lng: 46.6770, lat: 24.7135), .init(lng: 46.6852, lat: 24.7171),
            .init(lng: 46.6960, lat: 24.7240), .init(lng: 46.7032, lat: 24.7338), .init(lng: 46.7150, lat: 24.7405),
            .init(lng: 46.7275, lat: 24.7442), .init(lng: 46.7360, lat: 24.7531), .init(lng: 46.7491, lat: 24.7590),
        ]
        var p = TripPlan(route: PlanLineString(route), notes: "نتجمع عند المحطة ٤:٣٠ العصر. الطريق رملي بعد الكيلو ٦ — نفّسوا الكفرات.",
                         destination: OutingDestination(name: "روضة الثمامة", lat: 24.7590, lng: 46.7491), updated_at: ISODate.string(Date().addingTimeInterval(-1800)))
        /* `-demoPlanStops`: one planned stop on the way (auto-navigation's stop → destination). */
        if arguments.contains("-demoPlanStops") { p.stops = [OutingDestination(name: "محطة البنزين", lat: 24.7240, lng: 46.6960)] }
        #if DEBUG
        /* Screenshots in the desert: `-SaryDemoShift "dLat,dLng"` moves the plan with the demo group,
         * `-SaryDemoPlanName "مخيم النفود"` renames its destination. */
        if let i = arguments.firstIndex(of: "-SaryDemoShift"), i + 1 < arguments.count {
            let d = arguments[i + 1].split(separator: ",").compactMap { Double($0) }
            if d.count == 2 {
                p.route = p.route.map { PlanLineString($0.coordinates.map { LngLat(lng: $0[0] + d[1], lat: $0[1] + d[0]) }) }
                p.destination = p.destination.map { OutingDestination(name: $0.name, lat: $0.lat + d[0], lng: $0.lng + d[1]) }
                p.stops = p.stops.map { OutingDestination(name: $0.name, lat: $0.lat + d[0], lng: $0.lng + d[1]) }
            }
        }
        if let i = arguments.firstIndex(of: "-SaryDemoPlanName"), i + 1 < arguments.count, let dst = p.destination {
            p.destination = OutingDestination(name: arguments[i + 1], lat: dst.lat, lng: dst.lng)
        }
        #endif
        let me = DemoData.meId
        func items(_ a: String, _ b: String) -> [ChecklistItem] {
            [
                .init(id: "c1", title: "ماء", assignee_user_id: me, done: true, created_by: me),
                .init(id: "c2", title: "حطب", assignee_user_id: a, done: true, created_by: me),
                .init(id: "c3", title: "شاحن", assignee_user_id: b, done: true, created_by: a),
                .init(id: "c4", title: "حبل سحب", assignee_user_id: a, done: true, created_by: me),
                .init(id: "c5", title: "كفرات احتياط", assignee_user_id: nil, done: false, created_by: me),
                .init(id: "c6", title: "عدة إسعاف", assignee_user_id: me, done: true, created_by: b),
                .init(id: "c7", title: "كمبروسر", assignee_user_id: b, done: false, created_by: a),
                .init(id: "c8", title: "فحم", assignee_user_id: nil, done: true, created_by: a),
                .init(id: "c9", title: "كشاف", assignee_user_id: me, done: true, created_by: me),
                .init(id: "c10", title: "خيمة", assignee_user_id: nil, done: false, created_by: b),
            ]
        }
        if !empty {
            plans[DemoData.outingId] = p
            plans["demo-new"] = p
            lists[DemoData.outingId] = items("00000000-0000-4000-8000-000000000002", "00000000-0000-4000-8000-000000000003")
            lists["demo-new"] = items("00000000-0000-4000-8000-00000000021", "00000000-0000-4000-8000-00000000022")
        }
    }

    private func check() throws { if unavailable { throw OutingAPIError(code: "http_404", status: 404) } }

    func plan(_ id: String) async throws -> TripPlan { try check(); return plans[id] ?? .empty }

    func putPlan(_ id: String, _ plan: TripPlan) async throws -> TripPlan {
        var p = plan
        p.updated_at = ISODate.string(Date())
        plans[id] = p
        return p
    }

    func checklist(_ id: String) async throws -> [ChecklistItem] { try check(); return lists[id] ?? [] }

    func addItem(_ id: String, title: String) async throws -> ChecklistReply {
        seq += 1
        let item = ChecklistItem(id: "c\(seq)", title: title, created_by: DemoData.meId, created_at: ISODate.string(Date()))
        lists[id, default: []].append(item)
        return ChecklistReply(item: item)
    }

    func patchItem(_ id: String, _ itemId: String, done: Bool?, assignee: AssigneeChange?) async throws -> ChecklistReply {
        guard var l = lists[id], let i = l.firstIndex(where: { $0.id == itemId }) else { throw OutingAPIError(code: "not_found", status: 404) }
        if let done { l[i].done = done }
        switch assignee {
        case let .set(u)?: l[i].assignee_user_id = u
        case .clear?: l[i].assignee_user_id = nil
        case nil: break
        }
        lists[id] = l
        return ChecklistReply(item: l[i])
    }

    func deleteItem(_ id: String, _ itemId: String) async throws -> ChecklistReply {
        lists[id]?.removeAll { $0.id == itemId }
        return ChecklistReply(items: lists[id] ?? [])
    }

    func setRally(_ id: String, lat: Double, lng: Double, label: String?) async throws -> RallyInfo? { nil }
}
