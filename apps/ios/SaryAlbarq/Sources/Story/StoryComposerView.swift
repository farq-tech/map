import PhotosUI
import SwiftUI

/// «قصة الطلعة»: preview, privacy switches, photos from the outing, then share / save.
/// Everything is built on this phone; nothing is uploaded.
struct StoryComposerView: View {
    let facts: StoryFacts
    var close: () -> Void
    @Environment(\.sary) private var theme
    @State private var options = StoryOptions()
    @State private var preview: UIImage?
    @State private var rendering = false
    @State private var picks: [PhotosPickerItem] = []
    @State private var photos: [StoryPhoto] = []
    @State private var photoNote: String?
    @State private var shareURL: URL?
    @State private var toast: String?
    @State private var videoProgress: Double?
    @State private var saving = false
    /// Snapshots already taken, per camera (switching back and forth costs nothing).
    @State private var maps: [String: UIImage] = [:]
    @State private var mark: UIImage?
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        let p = theme.palette
        SaryPage(title: "قصة الطلعة", subtitle: facts.outingName, close: { StoryExport.cleanUp(); close() }) {
            previewCard
            SarySegmented(options: StoryFormat.allCases, selection: $options.format, label: \.label,
                          systemImage: { $0 == .vertical ? "rectangle.portrait" : "square" }, id: "story.format")
            SarySection(title: "الخصوصية", footer: "القصة تُصنع على جوالك ولا تُرفع لأي خادم. افتراضيًا نقصّ أول وآخر ٥٠٠ م من مسارك حتى لا يبان بيتك أو مكان انطلاقك، ونكتب عدد الأصدقاء بدل أسمائهم.") {
                SaryToggleRow(title: "أظهر نقطة البداية", subtitle: "يظهر المسار كاملًا من أول نقطة لآخر نقطة",
                              systemImage: "mappin.and.ellipse", isOn: $options.showStartEnd, id: "story.showStart")
                SaryDivider()
                SaryToggleRow(title: "أظهر أسماء الأصدقاء", subtitle: "تأكد أنهم موافقون: القصة تنتشر خارج الطلعة",
                              systemImage: "person.2.fill", isOn: $options.showNames, id: "story.showNames")
            }
            SarySection(title: "صور من الطلعة", footer: "حتى ٣ صور التُقطت وقت الطلعة. تُرسم داخل القصة فقط وتبقى على جوالك، ولا يدخل القصة موقع الصورة ولا بياناتها.") {
                PhotosPicker(selection: $picks, maxSelectionCount: StoryLayout.maxPhotos, matching: .images, preferredItemEncoding: .current) {
                    HStack(spacing: theme.space(.m)) {
                        SaryRowIcon(systemImage: "photo.on.rectangle.angled")
                        Text(photos.isEmpty ? "أضف صورًا" : "غيّر الصور (\(SaryFormat.number(photos.count)))")
                            .saryText(.body, weight: .medium).foregroundStyle(p.textPrimary)
                        Spacer()
                        Image(systemName: SaryIcon.disclosure).font(.system(size: 13, weight: .semibold)).foregroundStyle(p.textTertiary)
                    }
                    .frame(minHeight: theme.minTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("story.photos")
                if let photoNote {
                    SaryDivider()
                    Text(photoNote).saryText(.footnote).foregroundStyle(p.warningText).padding(.vertical, theme.space(.s))
                }
            }
            VStack(spacing: theme.space(.s)) {
                Button { share() } label: { SaryButtonLabel(title: "شارك الصورة", systemImage: SaryIcon.share) }
                    .buttonStyle(.sary(.primary))
                    .disabled(preview == nil || rendering)
                    .accessibilityIdentifier("story.share")
                Button { Task { await save() } } label: { SaryButtonLabel(title: "احفظ في الصور", systemImage: "square.and.arrow.down", busy: saving) }
                    .buttonStyle(.sary(.secondary))
                    .disabled(preview == nil || rendering || saving)
                    .accessibilityIdentifier("story.save")
                Button { Task { await makeVideo() } } label: {
                    SaryButtonLabel(title: "فيديو قصير يرسم المسار", systemImage: "play.rectangle.fill", busy: videoProgress != nil,
                                    busyTitle: "نجهّز الفيديو… \(SaryFormat.percent(Int((videoProgress ?? 0) * 100)))")
                }
                .buttonStyle(.sary(.secondary))
                .disabled(preview == nil || rendering || videoProgress != nil || facts.trail.count < 2)
                .accessibilityIdentifier("story.video")
            }
        }
        .overlay(alignment: .bottom) {
            if let toast { SaryToast(text: toast).padding(.bottom, theme.space(.xl)).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .task {
            mark = StoryRenderer.markImage()
            scheduleRender(debounce: false)
        }
        .onChange(of: options) { scheduleRender(debounce: false) }
        .onChange(of: picks) { Task { await loadPhotos() } }
        .sheet(item: Binding(get: { shareURL.map(ShareTarget.init) }, set: { if $0 == nil { shareURL = nil } })) { s in
            ShareSheet(items: [s.url]).presentationDetents([.medium, .large])
        }
    }

    private var previewCard: some View {
        let ratio = options.format.pixelSize.width / options.format.pixelSize.height
        let maxWidth: CGFloat = options.format == .vertical ? 300 : 360
        return ZStack {
            RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).fill(theme.palette.sunken)
            if let preview {
                Image(uiImage: preview).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous))
                    .accessibilityLabel(Text("معاينة قصة الطلعة"))
            }
            if rendering || preview == nil {
                ProgressView().controlSize(.large).tint(theme.palette.accent)
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        .frame(maxWidth: maxWidth)
        /* The 9:16 preview is 533 pt tall: on a 375×667 SE it filled the whole screen and pushed
           every control below the fold. Same size on standard phones (cover ≈ 669 pt), smaller there. */
        .saryFitHeight(maxWidth / ratio, reference: 660)
        .frame(maxWidth: .infinity)
        .saryShadow(.raised, theme)
        .accessibilityIdentifier("story.preview")
    }

    // MARK: actions

    private func scheduleRender(debounce: Bool) {
        renderTask?.cancel()
        renderTask = Task { await render() }
    }

    @MainActor
    private func render() async {
        rendering = true
        defer { rendering = false }
        let imgs = photos.map(\.image)
        var map: UIImage?
        if let cam = StoryRenderer.camera(facts, options, photoCount: imgs.count) {
            let key = "\(cam.centerLat),\(cam.centerLng),\(cam.zoom),\(cam.sizePt.width)x\(cam.sizePt.height)"
            if let m = maps[key] { map = m } else if let m = await StoryMapSnapshot.take(cam) {
                maps[key] = m
                map = m
            }
        }
        guard !Task.isCancelled else { return }
        let scene = StoryRenderer.scene(facts, options, photos: imgs, mapImage: map, mark: mark)
        let img = await Task.detached(priority: .userInitiated) { StoryRenderer.image(scene) }.value
        guard !Task.isCancelled else { return }
        preview = img
    }

    private func loadPhotos() async {
        var out: [StoryPhoto] = []
        var outside = 0, undated = 0
        for item in picks {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            /* Reading EXIF and decoding + downscaling a 12 MP photo (ImageIO) took the main thread
             * for each pick; it runs off it now. */
            let window = facts.photoWindow
            let read = await Task.detached(priority: .userInitiated) { () -> (StoryPhotoReader.Outcome, UIImage?) in
                let outcome = StoryPhotoReader.check(data, window: window)
                guard case .ok = outcome else { return (outcome, nil) }
                return (outcome, StoryPhotoReader.image(data))
            }.value
            switch read.0 {
            case .ok(let d):
                if let img = read.1 { out.append(StoryPhoto(image: img, takenAt: d)) }
            case .outsideWindow: outside += 1
            case .noDate, .unreadable: undated += 1
            }
        }
        out.sort { $0.takenAt < $1.takenAt }
        photos = out
        var notes: [String] = []
        if outside > 0 { notes.append(outside == 1 ? "صورة واحدة ليست من وقت الطلعة، ما أضفناها." : "\(SaryFormat.number(outside)) صور ليست من وقت الطلعة، ما أضفناها.") }
        if undated > 0 { notes.append(undated == 1 ? "صورة واحدة ما فيها وقت التقاط، ما أضفناها." : "\(SaryFormat.number(undated)) صور ما فيها وقت التقاط، ما أضفناها.") }
        photoNote = notes.isEmpty ? nil : notes.joined(separator: "\n")
        scheduleRender(debounce: false)
    }

    private func share() {
        guard let preview, let url = StoryExport.jpeg(preview) else { return }
        shareURL = url
    }

    private func save() async {
        guard let preview else { return }
        saving = true
        let r = await StoryExport.saveToPhotos(image: preview)
        saving = false
        show(r == .saved ? "انحفظت القصة في الصور" : r == .denied ? "اسمح بإضافة الصور من الإعدادات لحفظ القصة" : "تعذّر الحفظ، حاول مرة ثانية")
    }

    @MainActor
    private func makeVideo() async {
        videoProgress = 0
        defer { videoProgress = nil }
        let imgs = photos.map(\.image)
        var map: UIImage?
        if let cam = StoryRenderer.camera(facts, options, photoCount: imgs.count) {
            let key = "\(cam.centerLat),\(cam.centerLng),\(cam.zoom),\(cam.sizePt.width)x\(cam.sizePt.height)"
            map = maps[key]
            if map == nil { map = await StoryMapSnapshot.take(cam) }
        }
        let scene = StoryRenderer.scene(facts, options, photos: imgs, mapImage: map, mark: mark)
        let url = StoryExport.videoURL()
        do {
            try await StoryVideo.write(scene, to: url) { p in Task { @MainActor in videoProgress = p } }
            shareURL = url
        } catch {
            show("تعذّر تجهيز الفيديو")
        }
    }

    private func show(_ s: String) {
        withAnimation(theme.animation(.smooth)) { toast = s }
        Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(theme.animation(.smooth)) { toast = nil }
        }
    }
}
