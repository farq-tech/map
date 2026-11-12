import SwiftUI

/// «أداء التطبيق»: the developer row under «الإعدادات › متقدم › تشخيص», behind the same gate as
/// «جودة الموقع» (`GpsDevGate`: Debug builds, `-SaryDevGPS`, or a 3-second press). Opens the
/// stored MetricKit summaries. Reads a local file only; nothing is uploaded (docs/METRICS.md).
struct MetricsEntryRow: View {
    @Environment(\.sary) private var theme
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: theme.space(.m)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("أداء التطبيق").saryText(.subhead, weight: .medium).foregroundStyle(theme.palette.textPrimary)
                    Text("سرعة الفتح، التعليق، البطارية، والانهيارات من iOS").saryText(.caption, weight: .regular)
                        .foregroundStyle(theme.palette.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: SaryIcon.disclosure).saryGlyph(13, weight: .bold, relativeTo: .footnote)
                    .foregroundStyle(theme.palette.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: theme.minTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(SaryRowPressStyle())
        .padding(.horizontal, theme.space(.l))
        .padding(.vertical, theme.space(.xs))
        .sheet(isPresented: $open) { MetricsDiagnosticsView() }
    }
}

struct MetricsDiagnosticsView: View {
    @Environment(\.sary) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MetricsSummary]?
    @State private var file: URL?

    var body: some View {
        VStack(spacing: 0) {
            /* The app's one sheet header (was a text «تم» and a hand-sized title). */
            SarySheetHeader(title: "أداء التطبيق", close: { dismiss() }, trailing: {
                SaryIconButton(systemImage: SaryIcon.share, label: "شارك التقرير", id: "metrics.share") {
                    MetricsCollector.shared.exportFile { url in DispatchQueue.main.async { file = url } }
                }
                .disabled(items?.isEmpty ?? true)
            })
            .padding(.horizontal, theme.space(.l))
            .padding(.top, theme.space(.m))
            .padding(.bottom, theme.space(.s))
            ScrollView {
                VStack(alignment: .leading, spacing: theme.space(.m)) {
                    Text(MetricsLabels.footer).saryText(.caption, weight: .regular).foregroundStyle(theme.palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let items {
                        if items.isEmpty {
                            SaryStateView(kind: .empty(title: "ما وصل تقرير للحين",
                                                       message: "iOS يرسل تقرير الأداء مرة باليوم تقريبًا. استخدم التطبيق وارجع بكرة.",
                                                       systemImage: "chart.bar.doc.horizontal"))
                        }
                        ForEach(Array(items.reversed().enumerated()), id: \.offset) { _, s in card(s) }
                    } else {
                        SarySkeletonRow()
                        SarySkeletonRow()
                    }
                }
                .padding(.horizontal, theme.space(.l))
                .padding(.bottom, theme.space(.xxxl))
            }
        }
        .background(theme.palette.background.ignoresSafeArea())
        .onAppear {
            MetricsCollector.shared.load { list in DispatchQueue.main.async { items = list } }
        }
        .sheet(item: Binding(get: { file.map(PTTLinkRow.ShareFile.init) }, set: { file = $0?.url })) { f in
            ShareSheet(items: [f.url])
        }
    }

    private func card(_ s: MetricsSummary) -> some View {
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            Text(MetricsLabels.title(s)).saryText(.callout, weight: .bold).foregroundStyle(theme.palette.textPrimary)
            ForEach(Array(MetricsLabels.lines(s).enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.label).saryText(.caption, weight: .medium).foregroundStyle(theme.palette.textSecondary)
                    Text(line.value).font(.system(size: 12, design: .monospaced)).foregroundStyle(theme.palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.s)
    }
}

/// Plain Arabic labels for one summary (pure: tested).
enum MetricsLabels {
    struct Line: Equatable {
        var label: String
        var value: String
    }

    static let footer = "iOS يرسل تقرير الأداء مرة باليوم تقريبًا، وبس إذا كانت «مشاركة التحليلات مع المطورين» شغّالة بالجوال. ما فيه موقع ولا أرقام ولا أي شي يعرّف بك، ويبقى بجوالك لين تشاركه أنت."

    static func title(_ s: MetricsSummary) -> String {
        let kind = s.kind == .daily ? "تقرير يومي" : "تشخيص"
        let day = (s.periodEnd ?? s.periodStart).map { String($0.prefix(10)) } ?? ""
        let build = s.appBuild.map { b in " (\(b))" } ?? ""
        let ver = s.appVersion.map { v in " · نسخة \(v)\(build)" } ?? ""
        return "\(kind) \(day)\(ver)"
    }

    static func lines(_ s: MetricsSummary) -> [Line] {
        var out: [Line] = []
        func add(_ label: String, _ value: String?) {
            if let value, !value.isEmpty { out.append(Line(label: label, value: value)) }
        }
        /// "a · b · c", skipping the missing parts.
        func join(_ parts: [String?]) -> String? {
            let kept = parts.compactMap { $0 }
            return kept.isEmpty ? nil : kept.joined(separator: " · ")
        }

        if let m = s.firstDrawMedianMs {
            add("فتح التطبيق (لين أول رسم)", join(["الوسيط \(ms(m))",
                                                  s.firstDrawP90Ms.map { v in "٩٠٪ \(ms(v))" },
                                                  s.launchSamples.map { n in "\(n) مرة" }]))
        }
        add("الرجوع للتطبيق من الخلفية", s.resumeMedianMs.map { v in "الوسيط \(ms(v))" })
        if let h = s.hangSeconds {
            add("التعليق", join(["\(num(h)) ث",
                                  s.hangSecondsPerHour.map { v in "\(num(v)) ث بالساعة" },
                                  s.hangCount.map { n in "\(n) مرة" }]))
        }
        add("وقت المعالج", s.cpuSeconds.map { v in "\(num(v)) ث" })
        add("وقت الرسوميات", s.gpuSeconds.map { v in "\(num(v)) ث" })
        add("أعلى ذاكرة", s.peakMemoryMB.map { v in "\(num(v)) ميغا" })
        add("تقطيع التمرير", s.scrollHitchMsPerS.map { v in "\(num(v)) ملّي ث لكل ثانية تمرير" })
        if let fg = s.foregroundSeconds {
            add("وقت الاستخدام", join(["بالواجهة \(num(fg / 60)) د",
                                        s.backgroundSeconds.map { v in "بالخلفية \(num(v / 60)) د" },
                                        s.backgroundLocationSeconds.map { v in "موقع بالخلفية \(num(v / 60)) د" }]))
        }
        if let loc = s.locationSeconds {
            let rows = loc.keys.sorted().map { k in "\(k) \(num((loc[k] ?? 0) / 60)) د" }
            add("الموقع حسب الدقة (بطارية)", rows.joined(separator: "\n"))
        }
        add("إضاءة الشاشة (متوسط)", s.displayAverageLuminance.map { v in num(v) })
        if let bars = s.cellularBars {
            let rows = bars.keys.sorted().map { k in "\(k): \(bars[k] ?? 0)" }
            add("الشبكة الخلوية حسب الإشارة", rows.joined(separator: " · "))
        }
        if s.cellularDownloadMB != nil || s.cellularUploadMB != nil {
            let down = num(s.cellularDownloadMB ?? 0), up = num(s.cellularUploadMB ?? 0)
            add("بيانات الجوال", "تنزيل \(down) ميغا · رفع \(up) ميغا")
        }
        add("الكتابة على التخزين", s.diskWritesMB.map { v in "\(num(v)) ميغا" })
        if let ex = s.exits {
            let rows = ex.keys.sorted().map { k in "\(exitLabel(k)): \(ex[k] ?? 0)" }
            add("إغلاق التطبيق حسب السبب", rows.joined(separator: "\n"))
        }
        for p in s.signposts ?? [] {
            add("قياسنا: \(signpost(p.name))", join(["\(p.count) مرة",
                                                     p.medianMs.map { v in "الوسيط \(ms(v))" },
                                                     p.p90Ms.map { v in "٩٠٪ \(ms(v))" }]))
        }
        for d in s.diagnostics ?? [] {
            add(join([diagnostic(d.type), d.detail]) ?? d.type, d.stack.isEmpty ? "بدون مسار" : d.stack.joined(separator: "\n"))
        }
        if out.isEmpty { out.append(Line(label: "لا شي", value: "التقرير فاضي")) }
        return out
    }

    static func exitLabel(_ key: String) -> String {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        let side = parts.first == "foreground" ? "بالواجهة" : "بالخلفية"
        let names: [String: String] = [
            "normalApp": "طبيعي", "abnormal": "غير طبيعي", "appWatchdog": "تعليق طويل (watchdog)",
            "memoryResourceLimit": "تجاوز حد الذاكرة", "memoryPressure": "ضغط الذاكرة",
            "cpuResourceLimit": "تجاوز حد المعالج", "badAccess": "وصول خاطئ للذاكرة",
            "illegalInstruction": "تعليمة غلط", "backgroundTaskAssertionTimeout": "خلصت مهلة الخلفية",
            "suspendedWithLockedFile": "ملف مقفول وقت الإيقاف",
            "backgroundURLSessionCompletionTimeout": "خلصت مهلة التحميل بالخلفية",
            "backgroundFetchCompletionTimeout": "خلصت مهلة التحديث بالخلفية",
        ]
        let reason = parts.count > 1 ? parts[1] : key
        return "\(side) · \(names[reason] ?? reason)"
    }

    static func signpost(_ name: String) -> String {
        switch name {
        case "launch_to_map": return "فتح التطبيق لين تطلع الخريطة"
        case "live_first_car": return "شاشة الطلعة لين تطلع أول سيارة"
        case "desert_route": return "طلب درب البر لين يطلع"
        case "search": return "البحث لين تطلع النتائج"
        default: return name
        }
    }

    static func diagnostic(_ type: String) -> String {
        switch type {
        case "hang": return "تعليق"
        case "crash": return "انهيار"
        case "cpu": return "معالج زايد"
        case "diskWrite": return "كتابة زايدة على التخزين"
        case "launch": return "فتح بطيء"
        default: return type
        }
    }

    static func ms(_ v: Double) -> String { v >= 1000 ? "\(num(v / 1000)) ث" : "\(Int(v.rounded())) ملّي ث" }

    static func num(_ v: Double) -> String {
        v >= 100 ? String(Int(v.rounded())) : String(format: "%.1f", v)
    }
}
