import Foundation

/// Every participant drives a different colour, and everyone sees the same
/// colour for the same person: the colour comes from join order, which the
/// server gives every device identically. Port of `carColors.ts` — same
/// palette, same order, same tie-break.
enum CarColors {
    /// Distinct on satellite imagery and from each other; no two neighbours alike.
    static let palette: [UInt32] = [
        0xE8EEF0, // white
        0xD6452F, // red
        0x2F6FD6, // blue
        0xF2B630, // yellow
        0x2FA56A, // green
        0x8A4FD1, // purple
        0xF07F2F, // orange
        0x1FB8C4, // teal
        0xE05A9C, // pink
        0x15191C, // black
        0x9AA5AD, // silver
        0x7A5230, // brown
    ]

    /// user_id → RGB hex. Ordered by `joined_at` (ISO strings compare as text, as on
    /// the web) and then `user_id`, wrapping around the palette.
    static func assign(_ members: [(userId: String, joinedAt: String)]) -> [String: UInt32] {
        let order = members.sorted { a, b in
            if a.joinedAt != b.joinedAt { return a.joinedAt < b.joinedAt }
            return a.userId < b.userId
        }
        var out: [String: UInt32] = [:]
        for (i, m) in order.enumerated() { out[m.userId] = palette[i % palette.count] }
        return out
    }

    static func assign(_ members: [Member]) -> [String: UInt32] {
        assign(members.map { (userId: $0.user_id, joinedAt: $0.joined_at) })
    }

    /// Dark ink on light cars, light ink on dark ones.
    static func isLight(_ rgb: UInt32) -> Bool {
        let r = Double((rgb >> 16) & 0xFF), g = Double((rgb >> 8) & 0xFF), b = Double(rgb & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 150
    }
}
