import EqualizerCore
import Foundation
import XCTest

final class ProfileTests: XCTestCase {
    func testOPRARoundTripWithOptionalFieldsAndPriority() throws {
        let json = """
        {"author":"Test Lab","link":"verbatim source label","type":"parametric_eq","parameters":{"gain_db":0.8,"bands":[
         {"type":"low_pass","frequency":500,"slope":18,"extra":true},
         {"type":"peak_dip","frequency":8.5,"q":0.15}]}}
        """
        let info = try JSONDecoder().decode(EQInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.link, "verbatim source label")
        XCTAssertNil(info.productID)
        XCTAssertEqual(info.parameters.gainDB, 0.8)
        XCTAssertEqual(info.parameters.bands.map(\.kind), [.lowPass, .peakDip])
        XCTAssertEqual(info.parameters.bands[0].slope, 18)
        XCTAssertEqual(info.parameters.bands[1].gainDB, 0)
        XCTAssertEqual(try JSONDecoder().decode(EQInfo.self, from: JSONEncoder().encode(info)), info)
    }

    func testBadBandRejectsProfileAtItsIndex() {
        for bad in [#"{"type":"future","frequency":100}"#, #"{"type":"peak_dip","frequency":100}"#,
                    #"{"type":"high_pass","frequency":100,"slope":9}"#, #"{"type":"peak_dip","frequency":-1,"q":1}"#] {
            let json = #"{"gain_db":0,"bands":[{"type":"band_pass","frequency":100,"q":4},"# + bad + "]}"
            XCTAssertThrowsError(try JSONDecoder().decode(ParametricEQ.self, from: Data(json.utf8))) { error in
                let path: [CodingKey]
                switch error {
                case DecodingError.dataCorrupted(let c): path = c.codingPath
                default: return XCTFail("Unexpected error \(error)")
                }
                XCTAssertTrue(path.contains { $0.intValue == 1 })
            }
        }
    }

    func testFractionalSlopeIdentifiesTheField() {
        let json = #"{"type":"low_pass","frequency":200,"slope":12.5}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Band.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted(let context) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(context.codingPath.last?.stringValue, "slope")
            XCTAssertTrue(context.debugDescription.contains("whole-number"))
        }
    }

    func testAutoEqPasteAndJSONRoundTrip() throws {
        let eq = try AutoEq.parse("""
        \u{feff}  preAMP :   -4,5  dB
        Filter 8: ON LSC Fc 50 Hz Gain 3 dB Q 0,7
        Filter 3: OFF None
        Filter: ON   PK Fc 3000 Hz Gain -2.5 dB Q 2
        Filter 6: ON HSC Fc 8000 Hz Gain 1 dB Q 1
        Filter 1: ON LP Fc 15000 Hz
        """.replacingOccurrences(of: " Hz", with: "\tHz").replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(eq.gainDB, -4.5)
        XCTAssertEqual(eq.bands.map(\.kind), [.lowShelf, .peakDip, .highShelf, .lowPass])
        XCTAssertEqual(eq.bands.map(\.frequency), [50, 3000, 8000, 15000])
        XCTAssertEqual(eq.bands.map(\.gainDB), [3, -2.5, 1, 0])
        XCTAssertEqual(eq.bands[0].q, 0.7)
        XCTAssertEqual(try JSONDecoder().decode(ParametricEQ.self, from: JSONEncoder().encode(eq)), eq)
    }

    func testAutoEqReportsOffendingLine() {
        for bad in ["Filter: ON PK Fc 1,000 Hz Gain 3 dB Q 1",
                    "Filter: ON LS Fc 50 Hz Gain 3 dB Q 1", "Filter: ON HS Fc 500 Hz Gain 3 dB",
                    "Filter 1: XX PK", "Preamp: -2 dB", "Filter 1: ON XX Fc 1 Hz",
                    "Filter 1: ON PK Fc 60 Hz Gain 2 dB", "Filter 1: ON PK Fc 60 Hz Gain nan dB Q 1",
                    "Filter 1: ON PK Fc -1 Hz Gain 2 dB Q 1", "Filter 1: ON HP Fc 1 Hz extra"] {
            XCTAssertThrowsError(try AutoEq.parse("Preamp: 0 dB\n\n" + bad)) {
                XCTAssertEqual($0 as? AutoEq.ParseError, .invalidLine(3))
            }
        }
        XCTAssertThrowsError(try AutoEq.parse("Filter 1: OFF")) {
            XCTAssertEqual($0 as? AutoEq.ParseError, .missingPreamp)
        }
    }
}
