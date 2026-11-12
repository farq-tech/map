import XCTest
@testable import SaryAlbarq

final class NewUITests: XCTestCase {
    func testOffByDefaultAndFollowsDefaultsKey() {
        let d = UserDefaults(suiteName: "NewUITests.\(UUID().uuidString)")!
        XCTAssertFalse(NewUI.isOn(defaults: d, arguments: []))
        d.set(true, forKey: NewUI.key)
        XCTAssertTrue(NewUI.isOn(defaults: d, arguments: []))
    }

    func testLaunchArgumentsInDebug() {
        let d = UserDefaults(suiteName: "NewUITests.\(UUID().uuidString)")!
        #if DEBUG
        XCTAssertTrue(NewUI.isOn(defaults: d, arguments: [NewUI.argument]))
        d.set(true, forKey: NewUI.key)
        XCTAssertFalse(NewUI.isOn(defaults: d, arguments: [NewUI.legacyArgument]))
        #endif
    }
}
