import UIKit
import UniformTypeIdentifiers

/// «شارك إلى سَرى البارق» from YouTube / Safari: finds the YouTube link in what
/// was shared and leaves ONLY the video id for the app (App Group inbox), plus a
/// copy on the clipboard. Nothing is fetched or downloaded here.
final class ShareViewController: UIViewController {
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.semanticContentAttribute = .forceRightToLeft
        view.backgroundColor = .systemBackground
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .boldSystemFont(ofSize: 17)
        label.text = "لحظة…"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
        Task { await handle() }
    }

    private func handle() async {
        let texts = await sharedTexts()
        let link = texts.lazy.compactMap { YouTubeLink.parse($0) }.first
        if let link {
            MediaShareInbox.put(link)
            UIPasteboard.general.string = link.watchURL.absoluteString
            label.text = "تم ✓\nافتح سَرى البارق وادخل الطلعة: الفيديو يفتح في «يوتيوب ← قناتي»."
        } else {
            label.text = "ما لقينا رابط فيديو يوتيوب في اللي شاركته."
        }
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func sharedTexts() async -> [String] {
        var out: [String] = []
        for item in (extensionContext?.inputItems as? [NSExtensionItem]) ?? [] {
            if let t = item.attributedContentText?.string { out.append(t) }
            for p in item.attachments ?? [] {
                if p.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let u = try? await p.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    out.append(u.absoluteString)
                } else if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let s = try? await p.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    out.append(s)
                }
            }
        }
        return out
    }
}
