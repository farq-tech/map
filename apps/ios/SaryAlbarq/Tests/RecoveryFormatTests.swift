import XCTest
@testable import SaryAlbarq

final class RecoveryFormatTests: XCTestCase {
    func testNormalizesLikeTheServer() {
        let raw = "7k3q-m9xd 2hpa-vr6t-wc4n-8b1f-zj5e"
        XCTAssertEqual(RecoveryCodeFormat.normalize(raw), "7K3QM9XD2HPAVR6TWC4N8B1FZJ5E")
        XCTAssertTrue(RecoveryCodeFormat.isComplete(raw))
        /* Arabic-Indic digits and look-alikes. */
        XCTAssertEqual(RecoveryCodeFormat.normalize("٧K٣Q-OIL"), "7K3Q011")
        XCTAssertFalse(RecoveryCodeFormat.isComplete("ABCD"))
        /* U is not in the alphabet. */
        XCTAssertFalse(RecoveryCodeFormat.isComplete("UUUUUUUUUUUUUUUUUUUUUUUUUUUU"))
    }

    func testQRPayloadAndGrouping() {
        let qr = RecoveryCodeFormat.qrPrefix + "7K3QM9XD2HPAVR6TWC4N8B1FZJ5E"
        XCTAssertTrue(RecoveryCodeFormat.isComplete(qr))
        XCTAssertEqual(RecoveryCodeFormat.grouped(qr), "7K3Q-M9XD-2HPA-VR6T-WC4N-8B1F-ZJ5E")
    }

    func testAvatarFitsTheServerLimit() {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1500)).image { c in
            for i in 0..<200 {
                UIColor(hue: CGFloat(i) / 200, saturation: 1, brightness: 1, alpha: 1).setFill()
                c.fill(CGRect(x: i * 10, y: (i * 37) % 1500, width: 10, height: 1500))
            }
        }
        let url = AvatarCodec.dataURL(from: big)
        XCTAssertNotNil(url)
        XCTAssertLessThanOrEqual(url!.count, AvatarCodec.maxChars)
        XCTAssertTrue(url!.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertNotNil(AvatarCodec.image(from: url))
    }
}
