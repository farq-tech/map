import XCTest
@testable import SaryAlbarq

final class WindRainMotionTests: XCTestCase {
    private func wind(_ json: String) throws -> WindReading { try JSONDecoder().decode(WindReading.self, from: Data(json.utf8)) }
    private func rain(_ json: String) throws -> RainMotion { try JSONDecoder().decode(RainMotion.self, from: Data(json.utf8)) }

    func testWindPayloadDecodesAndSaysItIsAModelWithItsAge() throws {
        let w = try wind("""
        {"ok":true,"layer":"wind","speed_ms":5.6,"speed_kmh":20,"from_deg":270,"toward_deg":90,"from_ar":"غربية","calm":false,
         "model_age_min":150,"forecast_model":true,"unknown":1}
        """)
        let d = WindRainPresenter.wind(w)
        XCTAssertEqual(d?.arrowDegrees, 90, "the arrow points where the wind blows TO")
        XCTAssertTrue(d?.headline.contains("الريح غربية") == true)
        XCTAssertTrue(d?.headline.contains("عندك") == true)
        XCTAssertTrue(d?.detail.contains("شرقًا") == true)
        XCTAssertTrue(d?.footnote.contains("مو قياس") == true)
        XCTAssertTrue(d?.footnote.contains("ساعتين ونصف") == true, d?.footnote ?? "")
    }

    func testDestinationSubjectAndCalm() throws {
        let w = try wind(#"{"ok":true,"speed_kmh":1,"from_deg":10,"toward_deg":190,"from_ar":"شمالية","calm":true,"model_age_min":30}"#)
        let d = WindRainPresenter.wind(w, subject: .destination)
        XCTAssertNil(d?.arrowDegrees, "no arrow in calm air")
        XCTAssertTrue(d?.headline.contains("عند وجهتك") == true)
    }

    func testStrengthBands() {
        XCTAssertEqual(WindRainPresenter.strength(5), "خفيفة")
        XCTAssertEqual(WindRainPresenter.strength(20), "معتدلة")
        XCTAssertTrue(WindRainPresenter.strength(40).contains("غبار"))
        XCTAssertTrue(WindRainPresenter.strength(70).contains("شديدة"))
    }

    func testFailedWindIsHidden() throws {
        XCTAssertNil(WindRainPresenter.wind(try wind(#"{"ok":false,"speed_kmh":0,"from_deg":0,"toward_deg":0}"#)))
    }

    func testRainMotionShowsDirectionAgeMarginAndNeverPredicts() throws {
        let r = try rain("""
        {"ok":true,"state":"moving","confidence":0.8,"min_confidence":0.45,
         "motion":{"bearing_deg":90,"speed_kmh":27,"direction_ar":"شرقًا","margin_deg":27,"margin_kmh":8},
         "rain_at_point":true,"image_age_min":300}
        """)
        let d = WindRainPresenter.rain(r)
        XCTAssertEqual(d?.arrowDegrees, 90)
        XCTAssertTrue(d?.headline.contains("كان يتجه") == true, "past tense: this is what was seen")
        XCTAssertTrue(d?.headline.contains("شرقًا") == true)
        XCTAssertTrue(d?.detail.contains("±") == true)
        XCTAssertTrue(d?.footnote.contains("٥ ساعات") == true, d?.footnote ?? "")
        XCTAssertTrue(d?.footnote.contains("مو توقع مطر") == true)
    }

    func testRainMotionHiddenWhenWeakOrNoRainOrUncertain() throws {
        let weak = try rain(#"{"ok":true,"state":"moving","confidence":0.3,"motion":{"bearing_deg":90,"speed_kmh":27,"margin_deg":50,"margin_kmh":12},"image_age_min":300}"#)
        XCTAssertNil(WindRainPresenter.rain(weak))
        XCTAssertNil(WindRainPresenter.rain(try rain(#"{"ok":true,"state":"no_rain","confidence":0}"#)))
        XCTAssertNil(WindRainPresenter.rain(try rain(#"{"ok":true,"state":"uncertain","confidence":0.2}"#)))
        XCTAssertNil(WindRainPresenter.rain(try rain(#"{"ok":true,"state":"moving","confidence":0.9}"#)), "no motion payload → nothing to show")
    }

    func testStationaryRainHasNoArrow() throws {
        let d = WindRainPresenter.rain(try rain(#"{"ok":true,"state":"stationary","confidence":0.9,"image_age_min":360}"#))
        XCTAssertNil(d?.arrowDegrees)
        XCTAssertTrue(d?.headline.contains("ثابت") == true)
    }

    func testWindIsALayerInTheLayersList() {
        XCTAssertTrue(WeatherOverlayKind.allCases.contains(.wind))
        XCTAssertEqual(WeatherOverlayKind.wind.label, "اتجاه الرياح")
        XCTAssertTrue(WeatherOverlayKind.wind.attribution().contains("MET Norway"))
        XCTAssertEqual(WeatherOverlayKind(rawValue: "wind"), .wind)
        XCTAssertFalse(WeatherLegend.items(.wind).isEmpty)
    }

    func testWindLinesDecodeFromTheServerGeoJSON() throws {
        let j = """
        {"ok":true,"layer":"wind_streamlines","model_age_min":90,"type":"FeatureCollection","features":[
         {"type":"Feature","properties":{"speed_ms":5.1,"speed_kmh":18},
          "geometry":{"type":"MultiLineString","coordinates":[[[46.0,24.0],[46.1,24.0],[46.2,24.0]],[[46.15,24.02],[46.2,24.0],[46.15,23.98]]]}}]}
        """
        let l = try JSONDecoder().decode(WindLines.self, from: Data(j.utf8))
        XCTAssertEqual(l.features.count, 1)
        XCTAssertEqual(l.model_age_min, 90)
    }
}
