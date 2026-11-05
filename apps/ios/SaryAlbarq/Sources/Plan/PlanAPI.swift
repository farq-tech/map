import Foundation

/// What the plan + checklist need from the server (a fake in tests and the demo).
protocol PlanBackend: AnyObject {
    func plan(_ outingId: String) async throws -> TripPlan
    func putPlan(_ outingId: String, _ plan: TripPlan) async throws -> TripPlan
    func checklist(_ outingId: String) async throws -> [ChecklistItem]
    /// The server may answer with the new item or the whole list; both come back as the list.
    func addItem(_ outingId: String, title: String) async throws -> ChecklistReply
    func patchItem(_ outingId: String, _ itemId: String, done: Bool?, assignee: AssigneeChange?) async throws -> ChecklistReply
    func deleteItem(_ outingId: String, _ itemId: String) async throws -> ChecklistReply
    /// «نقطة تجمع» from the search sheet (leader).
    func setRally(_ outingId: String, lat: Double, lng: Double, label: String?) async throws -> RallyInfo?
}

/// `assignee_user_id`: keep, set or clear (an explicit null).
enum AssigneeChange: Equatable {
    case set(String)
    case clear
}

/// A checklist mutation's answer: the item, the list, or nothing.
struct ChecklistReply: Decodable, Equatable {
    var item: ChecklistItem?
    var items: [ChecklistItem]?

    init(item: ChecklistItem? = nil, items: [ChecklistItem]? = nil) {
        self.item = item
        self.items = items
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        item = try? c.decodeIfPresent(ChecklistItem.self, forKey: .item)
        items = (try? c.decodeIfPresent([ChecklistItem].self, forKey: .items)) ?? (try? c.decodeIfPresent([ChecklistItem].self, forKey: .checklist))
    }

    private enum Keys: String, CodingKey { case item, items, checklist }
}

enum PlanAvailability {
    /// The route is missing on this server (Express 404 / a proxy's 405): the feature is not deployed yet.
    static func notDeployed(_ e: Error) -> Bool {
        guard let e = e as? OutingAPIError else { return false }
        return (e.status == 404 || e.status == 405) && (e.code.hasPrefix("http_") || e.code == "not_found")
    }
}

/// `{plan: {...}}` or the plan itself.
private struct PlanBox: Decodable {
    var plan: TripPlan
    init(from d: Decoder) throws {
        if let c = try? d.container(keyedBy: K.self), let p = try? c.decode(TripPlan.self, forKey: .plan) {
            plan = p
        } else {
            plan = try TripPlan(from: d)
        }
    }
    private enum K: String, CodingKey { case plan }
}

/// `{items: [...]}`, `{checklist: [...]}` or a bare array.
private struct ItemsBox: Decodable {
    var items: [ChecklistItem]
    init(from d: Decoder) throws {
        if let a = try? [ChecklistItem](from: d) { items = a; return }
        let r = try ChecklistReply(from: d)
        items = r.items ?? []
    }
}

extension OutingsAPI: PlanBackend {
    func plan(_ outingId: String) async throws -> TripPlan {
        let r: PlanBox = try await call("GET", "/\(outingId)/plan")
        return r.plan
    }

    func putPlan(_ outingId: String, _ plan: TripPlan) async throws -> TripPlan {
        let r: PlanBox = try await call("PUT", "/\(outingId)/plan", body: plan.cleanedForUpload(), timeout: 20)
        return r.plan
    }

    func checklist(_ outingId: String) async throws -> [ChecklistItem] {
        let r: ItemsBox = try await call("GET", "/\(outingId)/checklist")
        return r.items
    }

    func addItem(_ outingId: String, title: String) async throws -> ChecklistReply {
        try await call("POST", "/\(outingId)/checklist", body: ["title": title])
    }

    func patchItem(_ outingId: String, _ itemId: String, done: Bool?, assignee: AssigneeChange?) async throws -> ChecklistReply {
        struct B: Encodable {
            var done: Bool?
            var assignee: AssigneeChange?
            enum K: String, CodingKey { case done, assignee_user_id }
            func encode(to e: Encoder) throws {
                var c = e.container(keyedBy: K.self)
                try c.encodeIfPresent(done, forKey: .done)
                switch assignee {
                case let .set(id)?: try c.encode(id, forKey: .assignee_user_id)
                case .clear?: try c.encodeNil(forKey: .assignee_user_id)
                case nil: break
                }
            }
        }
        return try await call("PATCH", "/\(outingId)/checklist/\(itemId)", body: B(done: done, assignee: assignee))
    }

    func deleteItem(_ outingId: String, _ itemId: String) async throws -> ChecklistReply {
        try await call("DELETE", "/\(outingId)/checklist/\(itemId)")
    }
}
