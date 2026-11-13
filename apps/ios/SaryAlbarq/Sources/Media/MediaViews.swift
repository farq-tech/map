import SwiftUI

// MARK: - Hooks (one line each in LiveSheet / LiveOutingScreen)

/// «يوتيوب» row in the live sheet.
struct MediaEntryCard: View {
    @ObservedObject var center: MediaCenter
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        Button { center.open(center.shared != nil && center.availability == .ready ? .outing : nil) } label: {
            HStack(spacing: theme.space(.m)) {
                SaryRowIcon(systemImage: "play.rectangle.fill", color: Color(red: 0.86, green: 0.11, blue: 0.11))
                VStack(alignment: .leading, spacing: 2) {
                    Text("يوتيوب").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                    Text(subtitle).saryText(.footnote).foregroundStyle(p.textSecondary).lineLimit(1)
                        .accessibilityIdentifier("media.entry.subtitle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: SaryIcon.disclosure).font(.system(size: 13, weight: .bold)).foregroundStyle(p.textTertiary)
            }
            .padding(theme.space(.m))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sarySurface(radius: SaryRadius.l)
        .accessibilityIdentifier("media.entry")
    }

    private var subtitle: String {
        if let s = center.shared, center.availability == .ready {
            return "\(center.name(of: s.controller_user_id)) يشغّل: \(center.title(for: s.video_id, fallback: s.title))"
        }
        return "قناتي • قناة الطلعة"
    }
}

/// Presents the «يوتيوب» sheet over the live sheet.
struct MediaSheetHost: View {
    @ObservedObject var center: MediaCenter
    @Environment(AppearanceSettings.self) private var appearance

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: $center.presented) {
                MediaSheet(center: center)
                    .saryAppearance(appearance)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }
}

/// «سعد شغّل: … في قناة الطلعة» — under the status capsule, with «انضم».
struct MediaNoticeLane: View {
    @ObservedObject var center: MediaCenter
    @Environment(\.sary) private var theme

    var body: some View {
        if let n = center.notice {
            let p = theme.palette
            HStack(spacing: theme.space(.m)) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color(red: 0.86, green: 0.11, blue: 0.11)))
                /* Who and where never truncate («في قناة الطلعة» stays visible); a long video
                 * title is what gets cut, on its own line. */
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(n.who) شغّل في قناة الطلعة")
                        .saryText(.footnote, weight: .bold)
                        .foregroundStyle(p.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                        .accessibilityIdentifier("media.notice.text")
                    Text(center.title(for: n.videoId, fallback: n.title))
                        .saryText(.callout, weight: .bold)
                        .foregroundStyle(p.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("media.notice.title")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("انضم", action: center.joinFromNotice)
                    .buttonStyle(.sary(.primary, width: .hug, compact: true))
                    .accessibilityIdentifier("media.notice.join")
                SaryDismissButton(action: center.dismissNotice)
            }
            .padding(.leading, theme.space(.m))
            .padding(.trailing, theme.space(.xs))
            .padding(.vertical, theme.space(.s))
            .frame(minHeight: theme.minTarget + 12)
            .saryGlass(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous), role: .panel)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("media.notice")
        }
    }
}

// MARK: - The sheet

struct MediaSheet: View {
    @ObservedObject var center: MediaCenter
    @Environment(\.sary) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.m)) {
            HStack {
                Text("يوتيوب").saryText(.title2, weight: .heavy).foregroundStyle(p.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("media.sheet")
                Spacer()
                SaryIconButton(systemImage: SaryIcon.close, label: "إغلاق", id: "media.close", visual: 36) { dismiss() }
            }
            SarySegmented(options: MediaChannel.allCases, selection: Binding(get: { center.tab }, set: { center.select($0) }),
                          label: { $0.title }, systemImage: { $0 == .mine ? "person.fill" : "person.3.fill" }, id: "media.tabs")
            ScrollView {
                VStack(spacing: theme.space(.m)) {
                    /* «إذاعة الطلعة» first: it is what works in the car (background, locked, CarPlay audio). */
                    if let radio = GroupAudioCenters.existing(center.outingId) {
                        GroupAudioPromoCard {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { radio.open() }
                        }
                    }
                    if center.onCarPlay {
                        SaryBanner(text: "الجوال متصل بـ CarPlay: يوتيوب ما يشتغل على شاشة السيارة ولا من خلالها.", tone: .warning, systemImage: "car.fill")
                            .accessibilityIdentifier("media.carplay")
                    }
                    switch center.tab {
                    case .mine: MineTab(center: center)
                    case .outing: OutingTab(center: center)
                    }
                    Text("يشتغل داخل مشغّل يوتيوب الرسمي. يتوقف التشغيل إذا طلعت من التطبيق أو قفلت الشاشة أو سكّرت هذي الصفحة (شرط يوتيوب)، وما يشتغل على CarPlay. كل جوال يشغّل الفيديو بنفسه، والخادم يعرف بس أي فيديو ووين وصل.")
                        .saryText(.caption).foregroundStyle(p.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("media.policy")
                }
                .padding(.bottom, theme.space(.xl))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, theme.space(.l))
        .padding(.top, theme.space(.l))
        .background(p.elevated.ignoresSafeArea())
        .onAppear(perform: center.sheetAppeared)
        .onDisappear(perform: center.sheetDisappeared)
        .alert("يوتيوب", isPresented: Binding(get: { center.errorText != nil }, set: { if !$0 { center.errorText = nil } })) {
            Button("حسنًا", role: .cancel) {}
        } message: { Text(center.errorText ?? "") }
    }
}

/// Paste a link: a text field, the system paste button (no paste prompt) and the action.
private struct LinkInput: View {
    var title: String
    var actionTitle: String
    var actionIcon: String = SaryIcon.play
    var id: String
    var busy = false
    var submit: (YouTubeLink) -> Void
    @State private var text = ""
    @State private var invalid = false
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            SaryTextField(title: title, placeholder: "youtu.be/… أو youtube.com/watch?v=…", text: $text, id: "\(id).field",
                          keyboard: .URL, state: invalid ? .error("هذا مو رابط فيديو يوتيوب.") : .normal)
                .environment(\.layoutDirection, .rightToLeft)
                .onChange(of: text) { _, _ in invalid = false }
            HStack(spacing: theme.space(.s)) {
                PasteButton(payloadType: String.self) { items in
                    guard let s = items.first else { return }
                    Task { @MainActor in
                        text = s
                        go()
                    }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("\(id).paste")
                Button(action: go) { SaryButtonLabel(title: actionTitle, systemImage: actionIcon, busy: busy) }
                    .buttonStyle(.saryPrimary)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    .accessibilityIdentifier("\(id).go")
            }
        }
    }

    private func go() {
        guard let link = YouTubeLink.parse(text) else { invalid = true; return }
        invalid = false
        text = ""
        submit(link)
    }
}

/// The player at the size drive safety allows — never smaller than 200 × 200 pt, never covered.
private struct PlayerBlock: View {
    @ObservedObject var center: MediaCenter
    @State private var fullWidth: CGFloat = 0
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.s)) {
            if center.presentation == .compact {
                VStack(alignment: .leading, spacing: theme.space(.s)) {
                    HStack(spacing: theme.space(.s)) {
                        Image(systemName: "person.2.fill")
                        Text("للركّاب").saryText(.headline, weight: .heavy)
                    }
                    .foregroundStyle(p.warningText)
                    Text("السيارة تمشي: المشغّل صغير عشان السائق يركّز على الطريق. الصوت يشتغل والمشغّل ظاهر.")
                        .saryText(.footnote).foregroundStyle(p.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { center.passengerConfirmed = true } label: { SaryButtonLabel(title: "أنا راكب", systemImage: "person.fill.checkmark") }
                        .buttonStyle(.sary(.secondary, compact: true))
                        .accessibilityIdentifier("media.passenger")
                }
                .padding(theme.space(.m))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: SaryRadius.m, style: .continuous).fill(p.warning.opacity(0.14)))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("media.passengerNotice")
                MediaPlayerHost(engine: center.engine)
                    .frame(width: DriveGate.minPlayerSide, height: DriveGate.minPlayerSide)
                    .clipShape(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous))
                    .accessibilityIdentifier("media.player.compact")
            } else {
                /* 16:9 across the sheet's width, but never under YouTube's 200 × 200 pt: an explicit
                 * height (an aspect-fit inside a min-height frame still drew 194.7 pt on a 6.3" phone), with 2 pt
                 * to spare so rounding on screen never lands a hair under 200 (measured 199.99999). */
                MediaPlayerHost(engine: center.engine)
                    .frame(maxWidth: .infinity)
                    .frame(minWidth: DriveGate.minPlayerSide)
                    .frame(height: max(DriveGate.minPlayerSide + 2, (fullWidth * 9 / 16).rounded(.up)))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fullWidth = $0 }
                    .clipShape(RoundedRectangle(cornerRadius: SaryRadius.s, style: .continuous))
                    .accessibilityIdentifier("media.player.full")
            }
            if let e = center.playerError {
                SaryBanner(text: e, tone: .error).accessibilityIdentifier("media.playerError")
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}

private struct NowPlayingLine: View {
    var title: String
    var detail: String
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).saryText(.headline, weight: .bold).foregroundStyle(theme.palette.textPrimary).lineLimit(2)
                .accessibilityIdentifier("media.nowPlaying")
            Text(detail).saryNumber(.footnote).foregroundStyle(theme.palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: «قناتي»

private struct MineTab: View {
    @ObservedObject var center: MediaCenter
    @Environment(\.sary) private var theme

    var body: some View {
        VStack(spacing: theme.space(.m)) {
            if let item = center.privateItem, center.activeChannel == .mine {
                PlayerBlock(center: center)
                NowPlayingLine(title: center.title(for: item.videoId, fallback: item.title),
                               detail: "لك وحدك • \(MediaFormat.ltr(MediaFormat.time(center.reading?.position ?? item.start)))")
                HStack(spacing: theme.space(.s)) {
                    Button { center.reading?.playing == true ? center.engine.pause() : center.resumePrivate() } label: {
                        SaryButtonLabel(title: center.reading?.playing == true ? "إيقاف مؤقت" : "شغّل", systemImage: center.reading?.playing == true ? SaryIcon.pause : SaryIcon.play)
                    }
                    .buttonStyle(.sarySecondary)
                    .accessibilityIdentifier("media.mine.toggle")
                    Button(action: center.stopPrivate) { SaryButtonLabel(title: "سكّر الفيديو", systemImage: SaryIcon.stop) }
                        .buttonStyle(.sarySecondary)
                        .accessibilityIdentifier("media.mine.stop")
                }
            } else if let item = center.privateItem {
                NowPlayingLine(title: center.title(for: item.videoId, fallback: item.title), detail: "موقّف")
                Button(action: center.resumePrivate) { SaryButtonLabel(title: "كمّل هنا", systemImage: SaryIcon.play) }
                    .buttonStyle(.sarySecondary)
                    .accessibilityIdentifier("media.mine.resume")
            } else {
                VStack(alignment: .leading, spacing: theme.space(.xs)) {
                    Text("قناتي").saryText(.headline, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                    Text("فيديو لك أنت بس، ما يشوفه أحد من الطلعة.").saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if center.joined {
                SaryInlineMessage(text: "تشغيل فيديو هنا يطلعك من قناة الطلعة (مشغّل واحد بس).", tone: .info)
            }
            LinkInput(title: "رابط يوتيوب", actionTitle: "شغّل", id: "media.mine") { center.playPrivate($0) }
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.l)
    }
}

// MARK: «قناة الطلعة»

private struct OutingTab: View {
    @ObservedObject var center: MediaCenter
    @Environment(\.sary) private var theme

    var body: some View {
        let p = theme.palette
        VStack(spacing: theme.space(.m)) {
            switch center.availability {
            case .unknown:
                HStack(spacing: theme.space(.s)) {
                    ProgressView()
                    Text("جارٍ التحميل…").saryText(.callout).foregroundStyle(p.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            case .notDeployed:
                VStack(spacing: theme.space(.s)) {
                    Image(systemName: "clock.badge.exclamationmark").font(.system(size: 30, weight: .bold)).foregroundStyle(p.textTertiary)
                    Text("غير متاح بعد").saryText(.headline, weight: .bold).foregroundStyle(p.textPrimary)
                        .accessibilityIdentifier("media.unavailable")
                    Text("قناة الطلعة تحتاج تحديث الخادم. «قناتي» تشتغل عادي.").saryText(.footnote).foregroundStyle(p.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, theme.space(.l))
            case let .failed(msg):
                SaryBanner(text: msg, tone: .error)
                Button { Task { await center.refresh() } } label: { SaryButtonLabel(title: "أعد المحاولة", systemImage: SaryIcon.retry) }
                    .buttonStyle(.sarySecondary)
            case .ready:
                if let s = center.shared { active(s) } else { idle }
            }
        }
        .padding(theme.space(.m))
        .sarySurface(radius: SaryRadius.l)
    }

    private var idle: some View {
        VStack(spacing: theme.space(.m)) {
            VStack(alignment: .leading, spacing: theme.space(.xs)) {
                Text("ما فيه شي شغّال").saryText(.headline, weight: .bold).foregroundStyle(theme.palette.textPrimary)
                    .accessibilityIdentifier("media.outing.idle")
                Text("شغّل فيديو للطلعة: اللي ينضم يشوفه معك بنفس اللحظة، وأنت تتحكم فيه.").saryText(.footnote).foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LinkInput(title: "رابط يوتيوب", actionTitle: "شغّل للطلعة", id: "media.outing", busy: center.busy) { link in
                Task { await center.startShared(link) }
            }
        }
    }

    @ViewBuilder
    private func active(_ s: SharedMediaState) -> some View {
        let p = theme.palette
        let pos = center.joined ? (center.reading?.position ?? center.expectedSharedPosition ?? 0) : (center.expectedSharedPosition ?? 0)
        VStack(spacing: theme.space(.m)) {
            if center.joined, center.activeChannel == .outing {
                PlayerBlock(center: center)
            }
            NowPlayingLine(title: center.title(for: s.video_id, fallback: s.title),
                           detail: "\(s.playing ? "يشتغل" : "موقّف") • \(MediaFormat.ltr(MediaFormat.time(pos)))")
            HStack(spacing: theme.space(.s)) {
                Image(systemName: SaryIcon.crown).font(.system(size: 12, weight: .bold)).foregroundStyle(p.accentText)
                Text("يتحكم: \(center.name(of: s.controller_user_id))").saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
                    .accessibilityIdentifier("media.controller")
                Spacer()
                if center.canTakeover {
                    Button { Task { await center.takeover() } } label: { Text("خذ التحكم") }
                        .buttonStyle(.sary(.secondary, width: .hug, compact: true))
                        .accessibilityIdentifier("media.takeover")
                }
            }
            if center.joined {
                if center.localHold {
                    Button(action: center.resync) { SaryButtonLabel(title: "رجّع للمزامنة", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.sarySecondary)
                        .accessibilityIdentifier("media.resync")
                }
                if center.canControl { controls(s) }
                Button(action: center.leaveShared) { SaryButtonLabel(title: "اطلع من القناة", systemImage: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(.sarySecondary)
                    .accessibilityIdentifier("media.leave")
            } else {
                Button(action: center.join) { SaryButtonLabel(title: "انضم", systemImage: "person.badge.plus") }
                    .buttonStyle(.saryPrimary)
                    .disabled(center.onCarPlay)
                    .accessibilityIdentifier("media.join")
                if center.activeChannel == .mine {
                    SaryInlineMessage(text: "الانضمام يوقّف فيديو «قناتي».", tone: .info)
                }
            }
            queue(s)
        }
    }

    private func controls(_ s: SharedMediaState) -> some View {
        HStack(spacing: theme.space(.s)) {
            round("gobackward.10", "رجوع ١٠ ثواني", "media.back10") { Task { await center.skip(by: -10) } }
            round(s.playing ? SaryIcon.pause : SaryIcon.play, s.playing ? "إيقاف مؤقت للجميع" : "شغّل للجميع", "media.toggle", primary: true) { Task { await center.togglePlay() } }
            round("goforward.10", "تقديم ١٠ ثواني", "media.fwd10") { Task { await center.skip(by: 10) } }
            round("forward.end.fill", "التالي", "media.next") { Task { await center.control(.next) } }
            round(SaryIcon.stop, "أوقف القناة", "media.stop") { Task { await center.control(.stop) } }
        }
        .frame(maxWidth: .infinity)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func round(_ icon: String, _ label: String, _ id: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        let p = theme.palette
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: primary ? 20 : 16, weight: .bold))
                .foregroundStyle(primary ? p.onAccent : p.textPrimary)
                .frame(width: primary ? 58 : 48, height: primary ? 58 : 48)
                .background(Circle().fill(primary ? p.accent : p.sunken))
        }
        .buttonStyle(.plain)
        .disabled(center.busy)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func queue(_ s: SharedMediaState) -> some View {
        let p = theme.palette
        VStack(alignment: .leading, spacing: theme.space(.s)) {
            SaryDivider()
            Text("القائمة (\(SaryFormat.number(s.queue.count))/\(SaryFormat.number(MediaPermissions.queueMax)))")
                .saryText(.footnote, weight: .bold).foregroundStyle(p.textSecondary)
            if s.queue.isEmpty {
                Text("ما فيه شي بعده. أي أحد يقدر يقترح فيديو.").saryText(.footnote).foregroundStyle(p.textTertiary)
            } else {
                ForEach(Array(s.queue.enumerated()), id: \.offset) { i, id in
                    HStack(spacing: theme.space(.s)) {
                        Text(SaryFormat.number(i + 1)).saryNumber(.footnote, weight: .bold).foregroundStyle(p.textTertiary).frame(width: 22)
                        Text(center.title(for: id)).saryText(.callout).foregroundStyle(p.textPrimary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("media.queue.item")
                }
            }
            if center.canQueue {
                LinkInput(title: "اقترح فيديو بعده", actionTitle: "أضف للقائمة", actionIcon: "text.badge.plus", id: "media.queue", busy: center.busy) { link in
                    Task { await center.queue(link) }
                }
            }
        }
    }
}
