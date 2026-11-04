import Foundation

/// The live screen's alerts as ONE priority queue: one card on screen, the rest
/// counted on the trip header's bell. SOS has its own strips and full-screen alert
/// (always above everything); it is listed here so the order is written down once.
/// docs/IA-REDESIGN.md §2.5.
enum AlertPriority: Int, Comparable {
    case media = 0, note, weather, convoy, returnTimer, silent, stuck, sos

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    /// While driving only these take the card; lower ones wait on the bell.
    static let drivingFloor: AlertPriority = .convoy

    init(_ kind: LiveAlertKindUI) {
        switch kind {
        case let .safety(s):
            switch s {
            case .friendStuck: self = .stuck
            case .myTimerOverdue, .friendTimerOverdue, .sunset: self = .returnTimer
            }
        case .silent: self = .silent
        case .convoy, .drift: self = .convoy
        case .weather: self = .weather
        case .note, .voice: self = .note
        case .toast: self = .media
        }
    }
}

enum AlertQueue {
    /// Toasts are feedback for the person's own action («نُسخ»): a short pill, never queued.
    static func isToast(_ a: LiveAlertUI) -> Bool { if case .toast = a.kind { return true }; return false }

    /// Highest priority first; newest first within a priority (the input is newest first).
    static func ordered(_ alerts: [LiveAlertUI]) -> [LiveAlertUI] {
        let real = alerts.filter { !isToast($0) }
        return real.enumerated()
            .sorted { a, b in
                let pa = AlertPriority(a.element.kind), pb = AlertPriority(b.element.kind)
                return pa != pb ? pa > pb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// The one card on screen (nil: nothing, or only low priority while driving).
    static func card(_ alerts: [LiveAlertUI], driving: Bool) -> LiveAlertUI? {
        guard let top = ordered(alerts).first else { return nil }
        if driving && AlertPriority(top.kind) < AlertPriority.drivingFloor { return nil }
        return top
    }

    /// The bell's number: queued alerts not on screen (+ media notices, the lowest tier).
    static func bellCount(_ alerts: [LiveAlertUI], driving: Bool, media: Int = 0) -> Int {
        let all = ordered(alerts).count
        return all - (card(alerts, driving: driving) == nil ? 0 : 1) + media
    }

    /// The newest toast, if any (shown as a quiet pill under the header).
    static func toast(_ alerts: [LiveAlertUI]) -> LiveAlertUI? { alerts.first(where: isToast) }
}

/// One past alert in the bell's history: alerts are never just dropped — when they expire
/// or are dismissed they stay readable here (docs/IA-REDESIGN.md §2.5).
struct AlertHistoryEntry: Identifiable, Equatable {
    var id: String
    var at: Date
    var symbol: String
    var text: String
    var priority: AlertPriority
}

extension AlertQueue {
    /// The history keeps this many entries (newest first).
    static let historyLimit = 40

    /// A one-line summary for the history list.
    static func summary(_ kind: LiveAlertKindUI) -> (symbol: String, text: String)? {
        switch kind {
        case let .note(name, _, text): return (SaryIcon.note, "\(name): \(text)")
        case let .drift(name, _, m): return ("arrow.up.left.and.arrow.down.right", "\(name) ابتعد \(SaryFormat.distance(meters: m))")
        case let .voice(c): return ("waveform", "رسالة صوتية من \(c.senderName)")
        case .toast: return nil
        case let .safety(s):
            switch s {
            case let .friendStuck(f): return (SafetyIcon.stuck, "\(f.name) غرّز")
            case let .sunset(title, _): return ("sunset.fill", title)
            case .myTimerOverdue: return ("timer", "تأخرت عن موعد العودة")
            case let .friendTimerOverdue(name, _): return ("timer", "\(name) تأخر عن موعد عودته")
            }
        case let .convoy(c): return ("car.2.fill", c.title)
        case let .weather(w): return ("cloud.sun.rain.fill", w.title)
        case let .silent(s): return ("antenna.radiowaves.left.and.right.slash", "انقطع إرسال \(s.name)")
        }
    }

    /// Adds `alert` to the history (replacing an older entry with the same id).
    static func record(_ alert: LiveAlertUI, at: Date, into history: inout [AlertHistoryEntry]) {
        guard let s = summary(alert.kind) else { return }
        history.removeAll { $0.id == alert.id }
        history.insert(AlertHistoryEntry(id: alert.id, at: at, symbol: s.symbol, text: s.text, priority: AlertPriority(alert.kind)), at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
    }
}
