import AVFoundation
import SwiftUI
import UIKit

/// Recovery codes as people see them: 28 Crockford-base32 characters in groups of four.
enum RecoveryCodeFormat {
    static let length = 28
    static let qrPrefix = "SARY-RECOVERY:"
    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Same forgiveness as the server: spaces, dashes, case, Arabic-Indic digits, O→0, I/L→1.
    static func normalize(_ raw: String) -> String {
        var t = raw.hasPrefix(qrPrefix) ? String(raw.dropFirst(qrPrefix.count)) : raw
        t = String(t.map { ch -> Character in
            if let v = ch.wholeNumberValue, !ch.isASCII { return Character(String(v)) }
            return ch
        })
        t = t.uppercased().filter { !" -_.\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}\u{2015}\n\t".contains($0) }
        t = t.replacingOccurrences(of: "O", with: "0").replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "L", with: "1")
        return t
    }

    static func isComplete(_ raw: String) -> Bool {
        let n = normalize(raw)
        return n.count == length && n.allSatisfy { alphabet.contains($0) }
    }

    /// "XXXX-XXXX-…" for display (Latin, left-to-right).
    static func grouped(_ raw: String) -> String {
        let n = normalize(raw)
        return stride(from: 0, to: n.count, by: 4).map { i in
            let a = n.index(n.startIndex, offsetBy: i)
            let b = n.index(a, offsetBy: min(4, n.count - i))
            return String(n[a..<b])
        }.joined(separator: "-")
    }
}

// MARK: - Restore on a new device

/// «عندي حساب سابق»: type the recovery code or scan its QR from the old phone.
struct RecoveryRestoreScreen: View {
    var close: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State private var code = ""
    @State private var phase: RecoveryPhaseUI = .enterCode
    @State private var scanning = false

    var body: some View {
        let p = theme.palette
        SaryPage(title: "استرجع حسابك", subtitle: "بدون كلمة مرور: برمز الاسترجاع من جوالك القديم", close: close) {
            switch phase {
            case .restored(let name):
                VStack(spacing: theme.space(.l)) {
                    Image(systemName: SaryIcon.checkCircle).font(.system(size: 56)).foregroundStyle(p.liveText)
                        .accessibilityHidden(true)
                    Text("أهلًا \(name)").saryText(.title, weight: .bold).foregroundStyle(p.textPrimary)
                        .lineLimit(2).minimumScaleFactor(0.85)
                    Text("رجعت طلعاتك على هذا الجهاز. جوالك القديم خرج من الحساب، والرمز الذي استخدمته انتهى — احفظ رمزًا جديدًا من «ملفي».")
                        .saryText(.callout).foregroundStyle(p.textSecondary).multilineTextAlignment(.center)
                    Button(action: close) { SaryButtonLabel(title: "متابعة") }
                        .buttonStyle(.sary(.primary))
                        .accessibilityIdentifier("recovery.done")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, theme.space(.xl))
            default:
                SaryTextField(title: "رمز الاسترجاع", placeholder: "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $code, id: "recovery.code",
                              maxLength: 40, disabled: phase == .restoring,
                              help: "٢٨ حرفًا ورقمًا. المسافات والشرطات لا تهم.")
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                if case .error(let m) = phase { SaryInlineMessage(text: m, tone: .error) }
                Button {
                    submit(code)
                } label: { SaryButtonLabel(title: "استرجع", busy: phase == .restoring, busyTitle: "نسترجع…") }
                    .buttonStyle(.sary(.primary))
                    .disabled(!RecoveryCodeFormat.isComplete(code) || phase == .restoring)
                    .accessibilityIdentifier("recovery.submit")
                Button { scanning = true } label: { SaryButtonLabel(title: "امسح رمز QR من جوالك القديم", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(.sary(.secondary))
                    .disabled(phase == .restoring)
                    .accessibilityIdentifier("recovery.scan")
                SarySection(title: "من وين أجيب الرمز؟") {
                    VStack(alignment: .leading, spacing: theme.space(.s)) {
                        Text("في جوالك القديم: «ملفي» ← «رمز الاسترجاع». يظهر الرمز ورمز QR مرة واحدة عند إنشائه.")
                        Text("إذا ما حفظت رمز من قبل، ما نقدر نسترجع الحساب. ابدأ باسم جديد، وأمير الطلعة يرسل لك دعوة.")
                    }
                    .saryText(.subhead)
                    .foregroundStyle(p.textSecondary)
                    .padding(.vertical, theme.space(.s))
                }
            }
        }
        .sheet(isPresented: $scanning) {
            QRScanSheet(title: "امسح رمز الاسترجاع", hint: "وجّه الكاميرا لرمز QR في «ملفي» على جوالك القديم.") { text in
                scanning = false
                code = RecoveryCodeFormat.grouped(text)
                if RecoveryCodeFormat.isComplete(text) { submit(text) } else { phase = .error("هذا مو رمز استرجاع. امسح الرمز اللي في «ملفي» بجوالك القديم.") }
            } cancel: { scanning = false }
            .rtl()
        }
    }

    private func submit(_ raw: String) {
        phase = .restoring
        Task {
            do {
                let name = try await model.recover(code: RecoveryCodeFormat.normalize(raw))
                phase = .restored(name: name)
            } catch let e as OutingAPIError {
                phase = .error(e.arabic)
            } catch {
                phase = .error("ما قدرنا نسترجع الحساب. جرّب مرة ثانية.")
            }
        }
    }
}

// MARK: - Save a code on this device

/// «رمز الاسترجاع» in «ملفي»: make a code (shown once) and its QR.
struct RecoveryCodeScreen: View {
    var back: () -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.sary) private var theme
    @State var code: OutingsAPI.RecoveryCode? = nil
    @State private var busy = false
    @State private var confirmReplace = false
    @State private var copied = false

    var body: some View {
        let p = theme.palette
        SaryPage(title: "رمز الاسترجاع", subtitle: "لتنقل حسابك لجوال جديد", back: back) {
            if let code {
                VStack(spacing: theme.space(.l)) {
                    SaryQRCode(text: RecoveryCodeFormat.qrPrefix + RecoveryCodeFormat.normalize(code.code), size: 200)
                    Text(RecoveryCodeFormat.grouped(code.code))
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .foregroundStyle(p.textPrimary)
                        .multilineTextAlignment(.center)
                        .environment(\.layoutDirection, .leftToRight)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("recovery.shownCode")
                    Button {
                        UIPasteboard.general.string = RecoveryCodeFormat.grouped(code.code)
                        copied = true
                    } label: { SaryButtonLabel(title: copied ? "نُسخ" : "انسخ الرمز", systemImage: copied ? SaryIcon.check : SaryIcon.copy) }
                        .buttonStyle(.sary(.secondary))
                    SaryBanner(text: "يظهر مرة واحدة فقط. اكتبه في مكان آمن أو صوّر رمز QR. من معه الرمز يقدر يدخل حسابك.", tone: .warning)
                }
                .frame(maxWidth: .infinity)
            } else {
                SarySection {
                    VStack(alignment: .leading, spacing: theme.space(.s)) {
                        Label {
                            Text(model.recovery?.active == true ? "عندك رمز محفوظ" : "ما حفظت رمزًا بعد")
                                .saryText(.headline)
                        } icon: {
                            Image(systemName: model.recovery?.active == true ? SaryIcon.checkCircle : SaryIcon.warning)
                                .foregroundStyle(model.recovery?.active == true ? p.liveText : p.warningText)
                        }
                        .foregroundStyle(p.textPrimary)
                        if let at = ISODate.parse(model.recovery?.created_at) {
                            Text("أُنشئ \(SaryFormat.elapsed(since: at, now: Date()))").saryText(.footnote).foregroundStyle(p.textSecondary)
                        }
                        Text("ما فيه كلمات مرور. إذا غيّرت جوالك أو حذفت التطبيق، هذا الرمز هو الطريقة الوحيدة لاسترجاع اسمك وطلعاتك.")
                            .saryText(.subhead).foregroundStyle(p.textSecondary)
                    }
                    .padding(.vertical, theme.space(.s))
                }
                Button {
                    if model.recovery?.active == true { confirmReplace = true } else { make() }
                } label: { SaryButtonLabel(title: model.recovery?.active == true ? "أنشئ رمزًا جديدًا" : "أنشئ رمز الاسترجاع", systemImage: "key.fill", busy: busy) }
                    .buttonStyle(.sary(.primary))
                    .disabled(busy)
                    .accessibilityIdentifier("recovery.make")
            }
        }
        .task { await model.loadMe() }
        .saryDialog($confirmReplace, systemImage: "key.fill", title: "رمز جديد؟", message: "الرمز القديم يتوقف عن العمل فورًا.", confirmTitle: "أنشئ رمزًا جديدًا", kind: .primary) {
            confirmReplace = false
            make()
        }
    }

    private func make() {
        busy = true
        Task {
            code = await model.makeRecoveryCode()
            busy = false
        }
    }
}

// MARK: - QR scanner

/// Camera QR scanner (needs NSCameraUsageDescription). Honest when there is no camera
/// (simulator) or the person refused it.
struct QRScanSheet: View {
    var title: String
    var hint: String
    var found: (String) -> Void
    var cancel: () -> Void
    @Environment(\.sary) private var theme
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        let p = theme.palette
        SaryPage(title: title, close: cancel, scrolls: false) {
            VStack(spacing: theme.space(.l)) {
                Group {
                    if AVCaptureDevice.default(for: .video) == nil {
                        SaryStateView(kind: .error(title: "ما فيه كاميرا", message: "اكتب الرمز بيدك بدل المسح."),
                                      actionTitle: "اكتب الرمز بيدك", actionIcon: "keyboard", action: cancel)
                    } else if status == .denied || status == .restricted {
                        SaryStateView(kind: .error(title: "الكاميرا مقفلة عن التطبيق", message: "اسمح بها من إعدادات iOS ← سَرى البارق، أو اكتب الرمز بيدك."),
                                      actionTitle: "افتح الإعدادات") {
                            if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                        }
                    } else {
                        QRCameraView(found: found)
                            .clipShape(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: SaryRadius.l, style: .continuous).stroke(p.accent, lineWidth: 2))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                Text(hint).saryText(.callout).foregroundStyle(p.textSecondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(theme.space(.l))
        }
        .task {
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                status = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }
}

struct QRCameraView: UIViewControllerRepresentable {
    var found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let c = ScannerController()
        c.found = found
        return c
    }

    func updateUIViewController(_ c: ScannerController, context: Context) { c.found = found }

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var found: (String) -> Void = { _ in }
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        private var done = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input) else { return }
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            out.metadataObjectTypes = [.qr]
            let l = AVCaptureVideoPreviewLayer(session: session)
            l.videoGravity = .resizeAspectFill
            view.layer.addSublayer(l)
            preview = l
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            done = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            found(s)
        }
    }
}
