import XCTest
@testable import SaryAlbarq

/// «اطلب إنجاد»: the prefilled message (stale fix, missing phone), the URLs and their encoding.
final class EnjadTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func input(fixAgeS: Double? = 20, phone: String? = "0551234567") -> Enjad.Input {
        let fix = fixAgeS.map { DeviceFix(lat: 24.7136123, lng: 46.6753456, accuracy: 8.4, heading: nil, speed: nil, atMs: (now.timeIntervalSince1970 - $0) * 1000) }
        return Enjad.Input(situation: .stuck, name: "أبو فهد", phone: phone, fix: fix, now: now, batteryPercent: 42, memberCount: 5,
                           car: nil, leaderName: "سلطان", leaderPhone: "0509999999")
    }

    func testFreshMessage() {
        let m = Enjad.message(input())
        XCTAssertTrue(m.hasPrefix("طلب مساعدة — سَرى البارق"))
        XCTAssertTrue(m.contains("الحالة: غرّزت"))
        XCTAssertTrue(m.contains("الاسم: أبو فهد"))
        XCTAssertTrue(m.contains("رقم التواصل: 0551234567"))
        XCTAssertTrue(m.contains("الموقع: 24.713612, 46.675346"))
        XCTAssertFalse(m.contains("آخر موقع معروف"))
        XCTAssertTrue(m.contains("https://maps.google.com/?q=24.713612,46.675346"))
        XCTAssertTrue(m.contains("24°42'49.0\"N"))
        XCTAssertTrue(m.contains("دقة الموقع: ±٨ م"))
        XCTAssertTrue(m.contains("آخر تحديث: "))
        XCTAssertTrue(m.contains("البطارية: ٤٢٪"))
        XCTAssertTrue(m.contains("عدد الأفراد في الطلعة: ٥"))
        XCTAssertTrue(m.contains("أمير الطلعة: سلطان — 0509999999"))
        XCTAssertFalse(m.contains("السيارة"), "unknown car: not said")
    }

    func testStaleFixIsSaidAsLastKnown() {
        let m = Enjad.message(input(fixAgeS: 7 * 60 + 10))
        XCTAssertTrue(m.contains("الموقع: آخر موقع معروف قبل ٧ د: 24.713612, 46.675346"))
        XCTAssertTrue(Enjad.message(input(fixAgeS: 119)).contains("الموقع: 24.713612"))
    }

    func testNoFixAndMissingPhone() {
        let i = input(fixAgeS: nil, phone: "  ")
        XCTAssertFalse(Enjad.hasPhone(i))
        let m = Enjad.message(i)
        XCTAssertTrue(m.contains("رقم التواصل: لم يُضف"))
        XCTAssertTrue(m.contains("الموقع: غير متوفر"))
        XCTAssertFalse(m.contains("maps.google.com"))
    }

    func testSituations() {
        var i = input()
        i.situation = .emergency
        XCTAssertTrue(Enjad.message(i).contains("الحالة: طوارئ"))
        i.situation = .breakdown
        XCTAssertTrue(Enjad.message(i).contains("الحالة: عطل"))
    }

    func testURLsAndEncoding() {
        let text = "طلب مساعدة\nخرائط: https://maps.google.com/?q=1,2&x=y #1"
        let wa = Enjad.whatsappURL(text).absoluteString
        XCTAssertTrue(wa.hasPrefix("https://wa.me/966507911999?text="))
        let q = String(wa.dropFirst("https://wa.me/966507911999?text=".count))
        XCTAssertFalse(q.contains("&") || q.contains("?") || q.contains("#") || q.contains(" ") || q.contains("\n"))
        XCTAssertEqual(q.removingPercentEncoding, text, "round-trips exactly")
        let sms = Enjad.smsURL(text).absoluteString
        XCTAssertTrue(sms.hasPrefix("sms:0507911999&body="))
        XCTAssertEqual(String(sms.dropFirst("sms:0507911999&body=".count)).removingPercentEncoding, text)
        XCTAssertEqual(Enjad.callURL.absoluteString, "tel:0507911999")
        /* UI-AUDIT 0.5: «اتصل ٩١١» dials the official emergency line, never Enjad's number. */
        XCTAssertEqual(Enjad.officialCallURL.absoluteString, "tel:911")
        XCTAssertEqual(Enjad.officialCallURL.scheme, "tel")
        XCTAssertEqual(Enjad.sendURL(text, whatsappInstalled: true, online: true).host, "wa.me")
        XCTAssertEqual(Enjad.sendURL(text, whatsappInstalled: false, online: true).scheme, "sms")
        XCTAssertEqual(Enjad.sendURL(text, whatsappInstalled: true, online: false).scheme, "sms", "no data: SMS")
    }
}
