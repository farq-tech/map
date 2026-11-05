import SwiftUI

private let radioColor = Color(red: 0.05, green: 0.55, blue: 0.45)

// MARK: - Hooks (one line each in LiveSheet / LiveOutingScreen / MediaSheet)

/// «إذاعة الطلعة» row in the live sheet (above «يوتيوب»).
struct GroupAudioEntryCard: View {
    @ObservedObject var center: GroupAudioCenter
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button { center.open() } label: {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: "dot.radiowaves.left.and.right", color: radioColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("إذاعة الطلعة").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                    Text(subtitle).saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(1)
                        .accessibilityIdentifier("radio.entry.subtitle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold)).foregroundStyle(p.textTertiary)
            }
            .padding(theme.space(.m))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sarySurface(radius: SaryRadius.l)
        .accessibilityIdentifier("radio.entry")
    }

    private var subtitle: String {
        if let i = center.nowItem { return "يشغّل الآن: \(i.title)" }
        return "إذاعات وقرآن للكل، تشتغل والشاشة مقفلة وفي السيارة"
    }
}

/// Presents the «إذاعة الطلعة» sheet.
struct GroupAudioSheetHost: View {
    @ObservedObject var center: GroupAudioCenter
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $center.presented) {
                GroupAudioSheet(center: center)
                    .saryAppearance(appearance)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}

/// «يشغّل الآن: …» on the map, also while navigating: big targets, one line.
struct GroupAudioMiniBar: View {
    @ObservedObject var center: GroupAudioCenter
    @Environment(\.sary) private var theme

    var body: some View {
        if center.showsNowPlaying, let item = center.nowItem {
            let p = theme.palette
            HStack(spacing: theme.space(.s)) {
                Button { center.open() } label: {
                    HStack(spacing: theme.space(.s)) {
                        Image(systemName: center.muted ? "speaker.slash.fill" : (center.state.playing ? "dot.radiowaves.left.and.right" : SaryIcon.pause))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(center.muted ? Color.gray : radioColor))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(center.muted ? "ساكت عندك" : (center.state.playing ? "يشغّل الآن" : "موقّفة"))
                                .saryText(.caption, weight: .bold).foregroundStyle(p.textSecondary)
                            Text(item.title).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                                .accessibilityIdentifier("radio.bar.title")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("radio.bar.open")
                if center.canControl, center.availability == .shared || center.availability == .localOnly {
                    Button { Task { await center.togglePlay() } } label: {
                        Image(systemName: center.state.playing ? SaryIcon.pause : SaryIcon.play)
                            .font(.system(size: 17, weight: .bold)).foregroundStyle(p.textPrimary)
                            .frame(width: theme.minTarget, height: theme.minTarget)
                    }
                    .accessibilityLabel(Text(center.state.playing ? "وقّف للكل" : "شغّل للكل"))
                    .accessibilityIdentifier("radio.bar.toggle")
                }
                Button { center.muted ? center.unmute() : center.mute() } label: {
                    Image(systemName: center.muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 17, weight: .bold)).foregroundStyle(p.textPrimary)
                        .frame(width: theme.minTarget, height: theme.minTarget)
                }
                .accessibilityLabel(Text(center.muted ? "رجّع الصوت" : "اسكت عندي"))
                .accessibilityIdentifier("radio.bar.mute")
            }
            .padding(.leading, theme.space(.s))
            .padding(.trailing, theme.space(.xs))
            .padding(.vertical, theme.space(.xs))
            .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("radio.bar")
        }
    }
}

/// In the «يوتيوب» sheet: «إذاعة الطلعة» first, and why.
struct GroupAudioPromoCard: View {
    var open: () -> Void
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            Button(action: open) {
                HStack(spacing: theme.space(.m)) {
                    SaryRowIcon(systemImage: "dot.radiowaves.left.and.right", color: radioColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("إذاعة الطلعة").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                        Text("للكل، والشاشة مقفلة، وعلى سماعات السيارة").saryText(.footnote).foregroundStyle(p.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold)).foregroundStyle(p.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("media.radio")
            Text("يوتيوب يشتغل والتطبيق مفتوح فقط (شرط يوتيوب)؛ للسيارة استخدم إذاعة الطلعة")
                .saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("media.radio.note")
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.l)
    }
}

// MARK: - The sheet

struct GroupAudioSheet: View {
    @ObservedObject var center: GroupAudioCenter
    @Environment(\.sary) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.m)) {
            HStack {
                Text("إذاعة الطلعة").saryText(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("radio.sheet")
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: SaryIcon.close).font(.system(size: 14, weight: .bold)).foregroundStyle(p.textSecondary)
                        .frame(width: theme.minTarget, height: theme.minTarget)
                }
                .accessibilityLabel(Text("إغلاق"))
                .accessibilityIdentifier("radio.close")
            }
            ScrollView {
                VStack(spacing: theme.space(.m)) {
                    if center.availability == .localOnly {
                        SaryInlineMessage(text: "التشغيل الحين لك أنت بس. المزامنة مع أعضاء الطلعة تشتغل مع تحديث الخادم القادم.", tone: .info)
                            .accessibilityIdentifier("radio.localOnly")
                    }
                    NowPlayingCard(center: center)
                    if center.canSetAllowAll {
                        SaryToggleRow(title: "الكل يقدر يشغّل", subtitle: "بدونها: أمير الرحلة ونائبه بس", systemImage: "person.3.fill",
                                      isOn: Binding(get: { center.state.allow_all }, set: { v in Task { await center.setAllowAll(v) } }), id: "radio.allowAll")
                            .padding(theme.space(.s))
                            .sarySurface(radius: SaryRadius.l)
                    }
                    if center.canControl {
                        SarySegmented(options: GroupAudioSource.allCases, selection: $center.pickerSource, label: { $0.title }, id: "radio.sources")
                        switch center.pickerSource {
                        case .radio: StationList(center: center)
                        case .quran: QuranPicker(center: center)
                        case .audius: AudiusPicker(center: center)
                        }
                    } else {
                        SaryInlineMessage(text: "أمير الرحلة هو اللي يختار. تقدر تسكّتها عندك بس.", tone: .info)
                            .accessibilityIdentifier("radio.memberNote")
                    }
                    Text("كل جوال يشغّل البث من مصدره الرسمي مباشرة، والخادم يعرف بس وش يشتغل ووين وصل. الإذاعات مباشرة فالكل يسمع نفس البث؛ القرآن وAudius متزامنة على ساعة الخادم. صوت الملاحة يخفّض الصوت، والقناة (اضغط وتكلم) توقفها لين تخلص.")
                        .saryText(.caption).foregroundStyle(p.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("radio.policy")
                }
                .padding(.bottom, theme.space(.xl))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.top, theme.space(.l))
        .background(p.elevated.ignoresSafeArea())
        .alert("إذاعة الطلعة", isPresented: Binding(get: { center.errorText != nil }, set: { if !$0 { center.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(center.errorText ?? "") }
    }
}

private struct NowPlayingCard: View {
    @ObservedObject var center: GroupAudioCenter
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            if let item = center.nowItem {
                HStack(spacing: theme.space(.s)) {
                    Text(item.live ? "مباشر" : "متزامن")
                        .saryText(.caption, weight: .heavy).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(item.live ? Color.red : radioColor))
                    Text(statusText).saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                        .accessibilityIdentifier("radio.status")
                }
                Text("يشغّل الآن: \(item.title)").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(2)
                    .accessibilityIdentifier("radio.nowPlaying")
                Text(detail(item)).saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(2)
                if case let .failed(msg) = center.status {
                    SaryBanner(text: msg, tone: .error).accessibilityIdentifier("radio.error")
                }
                HStack(spacing: theme.space(.s)) {
                    if center.canControl {
                        Button { Task { await center.togglePlay() } } label: {
                            SaryButtonLabel(title: center.state.playing ? "وقّف للكل" : "شغّل للكل", systemImage: center.state.playing ? SaryIcon.pause : SaryIcon.play)
                        }
                        .buttonStyle(.sarySecondary)
                        .accessibilityIdentifier("radio.toggle")
                        if !center.state.queue.isEmpty {
                            Button { Task { await center.next() } } label: { SaryButtonLabel(title: "التالي", systemImage: "forward.fill") }
                                .buttonStyle(.sarySecondary)
                                .accessibilityIdentifier("radio.next")
                        }
                        Button { Task { await center.stop() } } label: { SaryButtonLabel(title: "سكّر", systemImage: SaryIcon.stop) }
                            .buttonStyle(.sarySecondary)
                            .accessibilityIdentifier("radio.stop")
                    }
                }
                HStack(spacing: theme.space(.s)) {
                    Button { center.muted ? center.unmute() : center.mute() } label: {
                        SaryButtonLabel(title: center.muted ? "رجّع الصوت" : "اسكت عندي", systemImage: center.muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    }
                    .buttonStyle(.sarySecondary)
                    .accessibilityIdentifier("radio.mute")
                    if !center.canControl {
                        Button(action: center.leave) { SaryButtonLabel(title: "اطلع", systemImage: "rectangle.portrait.and.arrow.right") }
                            .buttonStyle(.sarySecondary)
                            .accessibilityIdentifier("radio.leave")
                    }
                }
                if !center.state.queue.isEmpty {
                    Text("بعدها: \(center.state.queue.prefix(3).map(\.title).joined(separator: "، "))")
                        .saryText(.caption).foregroundStyle(p.textTertiary).lineLimit(2)
                }
            } else {
                VStack(alignment: .leading, spacing: theme.space(.xs)) {
                    Text("ما فيه شي شغّال").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("radio.idle")
                    Text(center.canControl ? "اختر إذاعة أو تلاوة وتشتغل عند الكل." : "إذا شغّل أمير الرحلة شي، يشتغل عندك تلقائي.")
                        .saryText(.footnote).foregroundStyle(p.textSecondary)
                }
            }
        }
        .padding(theme.space(.m))
        .frame(maxWidth: .infinity, alignment: .leading)
        .sarySurface(radius: SaryRadius.l)
    }

    private var statusText: String {
        if center.muted { return "ساكت عندك" }
        if !center.state.playing { return "موقّفة للكل" }
        switch center.status {
        case .loading: return "يحمّل…"
        case .playing: return "يشتغل"
        case .paused: return "موقّف"
        case .failed: return "تعذّر التشغيل"
        case .idle: return ""
        }
    }

    private func detail(_ item: GroupAudioItem) -> String {
        var parts: [String] = []
        if !item.subtitle.isEmpty { parts.append(item.subtitle) }
        if let by = center.state.by { parts.append("شغّلها \(center.name(of: by))") }
        if !item.live, let e = center.elapsed { parts.append(MediaFormat.ltr(GroupAudioFormat.time(e))) }
        if item.source == .quran { parts.append("المصدر: mp3quran.net") }
        if item.source == .audius { parts.append("على Audius") }
        return parts.joined(separator: " · ")
    }
}

private struct StationList: View {
    @ObservedObject var center: GroupAudioCenter
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.m)) {
            ForEach(GroupAudioStation.Group.allCases, id: \.self) { g in
                let list = center.stations.filter { $0.group == g }
                if !list.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(g.title).saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                            .padding(.horizontal, theme.space(.m)).padding(.top, theme.space(.s))
                        ForEach(list) { s in
                            Button { Task { await center.playStation(s) } } label: {
                                HStack(spacing: theme.space(.m)) {
                                    Image(systemName: center.nowItem?.id == s.id ? "speaker.wave.2.fill" : "dot.radiowaves.left.and.right")
                                        .foregroundStyle(radioColor).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.name).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                                        Text(s.subtitle).saryText(.caption).foregroundStyle(p.textSecondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, theme.space(.m))
                                .frame(minHeight: theme.minTarget + 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(center.busy)
                            .accessibilityIdentifier("radio.station.\(s.id)")
                        }
                    }
                    .sarySurface(radius: SaryRadius.l)
                }
            }
        }
    }
}

private struct QuranPicker: View {
    @ObservedObject var center: GroupAudioCenter
    @State private var reciter = QuranReciter.all[0]
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            Picker("القارئ", selection: $reciter) {
                ForEach(QuranReciter.all) { r in Text(r.name).tag(r) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("radio.quran.reciter")
            Text("السورة تشتغل عند الكل من نفس الموضع. المصدر: mp3quran.net").saryText(.caption).foregroundStyle(p.textTertiary)
            LazyVStack(spacing: 0) {
                ForEach(1...114, id: \.self) { n in
                    Button { Task { await center.play(reciter.item(surah: n)) } } label: {
                        HStack {
                            Text(SaryFormat.digits("\(n)")).saryNumber(.footnote).foregroundStyle(p.textTertiary).frame(width: 32)
                            Text("سورة \(QuranSurahs.name(n))").saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, theme.space(.m))
                        .frame(minHeight: theme.minTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(center.busy)
                    .accessibilityIdentifier("radio.quran.surah.\(n)")
                }
            }
            .sarySurface(radius: SaryRadius.l)
        }
    }
}

private struct AudiusPicker: View {
    @ObservedObject var center: GroupAudioCenter
    @State private var query = ""
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            SaryTextField(title: "ابحث في Audius", placeholder: "اسم فنان أو مقطع", text: $query, id: "radio.audius.field")
                .onSubmit { Task { await center.searchAudius(query) } }
            Button { Task { await center.searchAudius(query) } } label: {
                SaryButtonLabel(title: "ابحث", systemImage: "magnifyingglass", busy: center.audiusSearching)
            }
            .buttonStyle(.saryPrimary)
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || center.audiusSearching)
            .accessibilityIdentifier("radio.audius.go")
            Text("Audius منصة مفتوحة: الفنانين يرفعون أعمالهم ويسمحون بتشغيلها في التطبيقات.").saryText(.caption).foregroundStyle(p.textTertiary)
            if !center.audiusResults.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(center.audiusResults, id: \.id) { t in
                        HStack {
                            Button { Task { await center.play(t.item) } } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.title).saryText(.callout, weight: .bold).foregroundStyle(p.textPrimary).lineLimit(1)
                                    Text([t.user?.name ?? "", t.duration.map { MediaFormat.ltr(GroupAudioFormat.time($0)) } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .saryText(.caption).foregroundStyle(p.textSecondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if center.canQueue {
                                Button { Task { await center.queue(t.item) } } label: {
                                    Image(systemName: "text.badge.plus").frame(width: theme.minTarget, height: theme.minTarget)
                                }
                                .accessibilityLabel(Text("أضفها للقائمة"))
                            }
                        }
                        .padding(.horizontal, theme.space(.m))
                        .frame(minHeight: theme.minTarget + 8)
                    }
                }
                .sarySurface(radius: SaryRadius.l)
            }
        }
    }
}
