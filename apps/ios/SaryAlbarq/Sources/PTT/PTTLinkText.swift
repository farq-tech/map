import Foundation

/// The one diagnostics line under «قناة الطلعة» in the outing's settings: is the live link up,
/// is it coming back, and the last close code — so a field test can say what it saw.
enum PTTLinkText {
    static func line(_ d: LiveChannel.Diagnostics, nowMs: Double) -> String {
        var s: String
        switch d.state {
        case .live:
            if let since = d.liveSinceMs {
                let min = Int(max(0, nowMs - since) / 60_000)
                s = min < 1 ? "الاتصال: متصل الآن" : "الاتصال: متصل منذ \(min) د"
            } else {
                s = "الاتصال: متصل"
            }
        case .connecting:
            s = d.reconnects > 0 ? "الاتصال: يعيد الاتصال… (المحاولة \(d.reconnects + 1))" : "الاتصال: يتصل…"
            if d.retryInMs >= 1_000 { s += " بعد \(Int((d.retryInMs / 1000).rounded())) ث" }
        case .polling:
            s = "الاتصال: بطيء — المواقع تصل، الصوت المباشر لا"
        case .offline:
            s = "الاتصال: لا إنترنت"
        case .closed:
            s = "الاتصال: مغلق"
        }
        if let code = d.lastCloseCode, d.state != .live || d.reconnects > 0 {
            s += " • آخر انقطاع: \(code)"
            if let why = reason(d.lastCloseReason, code: code) { s += " (\(why))" }
        }
        return s
    }

    static func reason(_ r: String?, code: Int) -> String? {
        switch r {
        case "replaced": return "جلسة أحدث لك"
        case "auth_timeout": return "تأخّر التحقق"
        case "ready_timeout": return "لم يكتمل الاتصال"
        case "silent": return "انقطع بصمت"
        case "unauthorized": return "الدخول"
        case "not_a_member": return "لست عضوًا"
        case "outing_ended": return "انتهت الطلعة"
        default: return code == 1006 ? "انقطع" : nil
        }
    }
}
