import Foundation

/// «الوجهة»: where the outing is heading, set in the plan by a leader or
/// co-leader. Defined identically on the plan branch (same file) so the merge is trivial.
struct OutingDestination: Codable, Equatable {
    var name: String
    var lat: Double
    var lng: Double
}
