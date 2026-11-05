import Foundation
import SwiftUI
import UIKit

/// «واقعية القيادة»: the person's choices (this device; on by default) and what the
/// effects read from the world (wind / rain from the weather cache, Low Power, Reduce Motion).
enum DrivingRealismPrefs {
    static let onKey = "sary.realism.on.v1"
    static let dustKey = "sary.realism.dust.v1"
    static let tracksKey = "sary.realism.tracks.v1"
    static let lightsKey = "sary.realism.lights.v1"
    static let tiltKey = "sary.realism.tilt.v1"
    /// «مسارات البر (OSM)» in the layers sheet.
    static let osmKey = "sary.map.osmTracks.v1"
    static var keys: [String] { [onKey, dustKey, tracksKey, lightsKey, tiltKey, osmKey] }

    static func bool(_ k: String, _ d: UserDefaults = .standard) -> Bool { d.object(forKey: k) as? Bool ?? true }

    struct Snapshot: Equatable {
        var dust = true
        var tracks = true
        var lights = true
        var tilt = true
        var osmTracks = true
    }

    /// What is on, with the master switch applied (motion smoothing is never switched off).
    static func snapshot(_ d: UserDefaults = .standard) -> Snapshot {
        let on = bool(onKey, d)
        return Snapshot(dust: on && bool(dustKey, d), tracks: on && bool(tracksKey, d), lights: on && bool(lightsKey, d),
                        tilt: on && bool(tiltKey, d), osmTracks: bool(osmKey, d))
    }
}

/// The weather the effects feel: the outing area's current hour (set by `OutingWeather`).
enum DrivingWeather {
    private(set) static var wind: DustWind?
    private(set) static var raining = false

    static func update(_ h: WeatherHour?) {
        #if DEBUG
        if MotionDemo.active { return } // the demo convoy sets its own wind / rain
        #endif
        wind = DustWind(fromDeg: h?.windFromDeg, kmh: h?.windKmh)
        raining = isRain(h)
    }

    /// Rain now: measurable precipitation, or a rain / shower / thunder weather code.
    static func isRain(_ h: WeatherHour?) -> Bool {
        guard let h else { return false }
        if let mm = h.precipitationMm, mm >= 0.1 { return true }
        guard let c = h.weatherCode else { return false }
        return (51 ... 67).contains(c) || (80 ... 82).contains(c) || c >= 95
    }

    #if DEBUG
    static func debugSet(wind w: DustWind?, raining r: Bool) {
        wind = w
        raining = r
    }
    #endif
}

/// The live sheet's settings group.
struct DrivingRealismSection: View {
    @AppStorage(DrivingRealismPrefs.onKey) private var on = true
    @AppStorage(DrivingRealismPrefs.dustKey) private var dust = true
    @AppStorage(DrivingRealismPrefs.tracksKey) private var tracks = true
    @AppStorage(DrivingRealismPrefs.lightsKey) private var lights = true
    @AppStorage(DrivingRealismPrefs.tiltKey) private var tilt = true
    @Environment(\.sary) private var theme
    @State private var always = true

    var body: some View {
        SarySection(title: "واقعية القيادة",
                    footer: "تأثيرات خفيفة من بياناتك الحقيقية: الغبار خارج الطرق المعبّدة ويتبع اتجاه الرياح الفعلي ولا يظهر وقت المطر، وآثار الكفرات على الرمل فقط. ميل السيارة من بيانات التضاريس (دقتها نحو ٣٠ م) فالنسبة تقريبية. تخفّ التأثيرات في وضع القيادة وتتوقف في وضع توفير الطاقة.") {
            SaryToggleRow(title: "واقعية القيادة", subtitle: on ? "مفعّلة" : "مقفلة", systemImage: "sparkles", isOn: $on, id: "realism.on")
            SaryDivider()
            SaryToggleRow(title: "انسيابية الحركة", subtitle: "دائمًا: السيارات تتحرك بسلاسة بين المواقع", systemImage: "wind", isOn: $always, id: "realism.motion")
                .disabled(true)
            if on {
                SaryDivider()
                SaryToggleRow(title: "الغبار", subtitle: "خلف السيارة خارج الطرق المعبّدة", systemImage: "aqi.medium", isOn: $dust, id: "realism.dust")
                SaryDivider()
                SaryToggleRow(title: "آثار الكفرات", subtitle: "على الرمل، تختفي بعد مسافة قصيرة", systemImage: "road.lanes", isOn: $tracks, id: "realism.tracks")
                SaryDivider()
                SaryToggleRow(title: "ميل السيارة مع التضاريس", subtitle: "صعود ونزول تقريبي", systemImage: "arrow.up.right", isOn: $tilt, id: "realism.tilt")
                SaryDivider()
                SaryToggleRow(title: "الأنوار الليلية", subtitle: "أضواء أمامية خافتة في الليل وظل الشمس في النهار", systemImage: "headlight.low.beam.fill", isOn: $lights, id: "realism.lights")
            }
        }
    }
}
