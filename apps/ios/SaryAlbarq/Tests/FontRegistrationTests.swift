import UIKit
import XCTest
@testable import SaryAlbarq

final class FontRegistrationTests: XCTestCase {
    func testAllFiveHuwiyaWeightsResolve() {
        SaryFonts.registerIfNeeded()
        let names = ["Light", "Regular", "Medium", "Bold", "Black"].map { "itfHuwiyaArabic-\($0)" }
        for n in names { XCTAssertNotNil(UIFont(name: n, size: 16), "PostScript name \(n) does not resolve") }
        XCTAssertEqual(SaryWeight.allCases.map(\.postScript).sorted(), names.sorted())
        XCTAssertEqual(Set(SaryFonts.files), Set(names))
    }

    func testInfoPlistListsAllFiveFiles() throws {
        let fonts = Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String] ?? []
        for w in ["Light", "Regular", "Medium", "Bold", "Black"] {
            XCTAssertTrue(fonts.contains("itfHuwiyaArabic-\(w).otf"), w)
            XCTAssertNotNil(Bundle.main.url(forResource: "itfHuwiyaArabic-\(w)", withExtension: "otf"), "\(w) not bundled")
        }
    }
}
