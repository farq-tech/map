import XCTest
@testable import SaryAlbarq

/// App Store required-reason APIs (ITMS-91053): every category the code uses is declared.
final class PrivacyManifestTests: XCTestCase {
    private func manifest() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"), "PrivacyInfo.xcprivacy in the app")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    private func reasons(_ m: [String: Any]) -> [String: Set<String>] {
        let types = m["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        var out: [String: Set<String>] = [:]
        for t in types {
            guard let k = t["NSPrivacyAccessedAPIType"] as? String else { continue }
            out[k, default: []].formUnion(t["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
        }
        return out
    }

    func testRequiredReasonAPIsAreDeclared() throws {
        let r = reasons(try manifest())
        XCTAssertEqual(r["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"], "file dates of our own files (TrailMatching, TrailRawLog)")
        XCTAssertTrue(r["NSPrivacyAccessedAPICategoryUserDefaults"]?.isSuperset(of: ["CA92.1", "1C8F.1"]) == true, "app-only and the App Group")
        XCTAssertEqual(r["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
    }

    func testContactsForPersonalInvitesAreDeclared() throws {
        let types = (try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []).compactMap { $0["NSPrivacyCollectedDataType"] as? String }
        XCTAssertTrue(types.contains("NSPrivacyCollectedDataTypeContacts"))
        XCTAssertFalse(try manifest()["NSPrivacyTracking"] as? Bool ?? true)
    }

    func testTheShareExtensionHasItsOwnManifest() throws {
        let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("SaryShare.appex/PrivacyInfo.xcprivacy")
        let url = try XCTUnwrap(appex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "SaryShare.appex/PrivacyInfo.xcprivacy")
    }

    /// One truth for the permission texts: Info.plist and the Arabic strings say the same thing.
    func testMicrophoneAndCameraTextsAgreeEverywhere() throws {
        let info = try XCTUnwrap(NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Info.plist")))
        let arURL = try XCTUnwrap(Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: "ar"))
        let ar = try XCTUnwrap(NSDictionary(contentsOf: arURL))
        let enURL = try XCTUnwrap(Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: "en"))
        let en = try XCTUnwrap(NSDictionary(contentsOf: enURL))
        for key in ["NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSLocationWhenInUseUsageDescription"] {
            XCTAssertEqual(info[key] as? String, ar[key] as? String, key)
        }
        let mic = try XCTUnwrap(ar["NSMicrophoneUsageDescription"] as? String)
        XCTAssertTrue(mic.contains("٦ ساعات") && mic.contains("محاولة الإرسال التالية"), "pending recordings can remain in local app storage until a retry checks their age")
        XCTAssertTrue(mic.contains("٢٤ ساعة") && mic.contains("١٠ دقائق"), "the two server-side audio paths have distinct retention times")
        let enMic = try XCTUnwrap(en["NSMicrophoneUsageDescription"] as? String)
        XCTAssertTrue(enMic.contains("temporarily keep it in app storage") && enMic.contains("six hours"), "the English disclosure also covers the local outbox")
        XCTAssertTrue(enMic.contains("24 hours") && enMic.contains("10 minutes"), "the English disclosure matches both server retention paths")
        let cam = try XCTUnwrap(ar["NSCameraUsageDescription"] as? String)
        XCTAssertTrue(cam.contains("تصوير نقطة"), "the camera also takes a point's photo")
    }
}
