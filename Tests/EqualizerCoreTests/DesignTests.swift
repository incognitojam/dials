import EqualizerCore
import Foundation
import XCTest

func plan(_ bands: [Band], gain: Double = 0, rate: Double = 48_000) throws -> EqualizerPlan {
    try EqualizerPlan(ParametricEQ(gainDB: gain, bands: bands), sampleRate: rate)
}

final class DesignTests: XCTestCase {
    func testBilinearPrototypeReferences() throws {
        let cases: [(Band, Double, [Double])] = try [
            (Band(.peakDip, frequency: 20, gainDB: 6, q: 2), 192000,
             [1.00011527519577, -1.9997679238152157, 0.9996530769380617, -1.9997679238152157, 0.9997683521338318]),
            (Band(.lowShelf, frequency: 105, gainDB: -4, q: 0.7), 44100,
             [0.9975377440940901, -1.9760791931862862, 0.9787171083354412, -1.9760278222385028, 0.9763062233773149]),
            (Band(.highShelf, frequency: 8500, gainDB: 8, q: 1.2), 96000,
             [2.1807640458665776, -3.33509131183151, 1.5161447333824687, -1.2188360960872393, 0.5806535635047753]),
            (Band(.bandPass, frequency: 3200, q: 3), 48000,
             [0.06348577532297794, 0, -0.06348577532297794, -1.7110966319427514, 0.8730284493540441]),
            (Band(.bandStop, frequency: 20000, q: 12), 48000,
             [0.9795918367346939, 1.6967028319042066, 0.9795918367346939, 1.6967028319042066, 0.9591836734693878]),
            (Band(.highPass, frequency: 500), 48000,
             [0.954774030661509, -1.909548061323018, 0.954774030661509, -1.9075016260460762, 0.9115944965999598]),
            (Band(.lowPass, frequency: 500), 48000,
             [0.0010232176384709, 0.0020464352769418, 0.0010232176384709, -1.9075016260460762, 0.9115944965999598])
        ]
        for (band, rate, expected) in cases {
            let k = try plan([band], rate: rate).sections[0]
            for (actual, ref) in zip([k.b0, k.b1, k.b2, k.a1, k.a2], expected) {
                XCTAssertEqual(actual, ref, accuracy: 1e-14)
            }
        }
    }

    func testWholeProfileReference() throws {
        let p = try plan([Band(.lowShelf, frequency: 100, gainDB: 4, q: 0.7),
                          Band(.peakDip, frequency: 2000, gainDB: -6, q: 2),
                          Band(.highShelf, frequency: 8000, gainDB: 3, q: 1)], gain: -5)
        for (f, ref) in zip([20.0, 250, 2000, 10000], [-1.010056454068, -4.911766181404, -11.07356645157, -2.216605522773]) {
            XCTAssertEqual(p.magnitudeDB(at: f), ref, accuracy: 1e-8)
        }
    }

    func testThumbnailResponseUsesDefaultOrSuppliedRate() throws {
        let eq = try ParametricEQ(gainDB: -2, bands: [Band(.peakDip, frequency: 20000, gainDB: 6, q: 2)])
        let thumbnail = try EqualizerPlan.thumbnail(eq)
        let hz = [20000.0, 20, 1000, 20]
        XCTAssertEqual(thumbnail.magnitudeDB(at: hz), hz.map { thumbnail.magnitudeDB(at: $0) })
        XCTAssertEqual(thumbnail.magnitudeDB(at: hz)[0], 4, accuracy: 1e-8)
        XCTAssertEqual(try EqualizerPlan(eq, sampleRate: 44100).magnitudeDB(at: hz)[0], 4, accuracy: 1e-12)
        XCTAssertEqual(thumbnail.magnitudeDB(at: []), [])
    }

    func testButterworthSlopesAndShelfEndpoints() throws {
        for slope in stride(from: 6, through: 36, by: 6) {
            for kind: Band.Kind in [.lowPass, .highPass] {
                let p = try plan([Band(kind, frequency: 500, slope: slope)])
                XCTAssertEqual(p.sections.count, (slope / 6 + 1) / 2)
                for f in [100.0, 500, 2000] {
                    let ratio = tan(.pi * f / 48000) / tan(.pi * 500 / 48000)
                    let ref = -10 * log10(1 + pow(ratio, Double(kind == .lowPass ? slope / 3 : -slope / 3)))
                    XCTAssertEqual(p.magnitudeDB(at: f), ref, accuracy: 1e-8)
                }
            }
        }
        for kind: Band.Kind in [.lowShelf, .highShelf] {
            let p = try plan([Band(kind, frequency: 1000, gainDB: 8, q: 1)])
            XCTAssertEqual(p.magnitudeDB(at: 1000), 4, accuracy: 1e-8)
            XCTAssertEqual(p.magnitudeDB(at: 0), kind == .lowShelf ? 8 : 0, accuracy: 1e-8)
            XCTAssertEqual(p.magnitudeDB(at: 24000), kind == .highShelf ? 8 : 0, accuracy: 1e-8)
        }
    }

    func testBroadbandTrimSurvivesRateChange() throws {
        let bands = try [Band(.lowShelf, frequency: 20000, gainDB: -10, q: 0.7),
                         Band(.peakDip, frequency: 300, gainDB: 2, q: 1)]
        let a = try plan(bands, gain: 1, rate: 44100)
        let b = try plan(bands, gain: 1, rate: 48000)
        for f in [30.0, 300, 2000, 6000, 10000] {
            XCTAssertLessThan(a.magnitudeDB(at: f), -6)
            XCTAssertEqual(a.magnitudeDB(at: f), b.magnitudeDB(at: f), accuracy: 0.1)
        }
    }

    func testCompareGainMatchesPinkNoisePower() throws {
        let p = try plan([Band(.lowShelf, frequency: 600, gainDB: 10, q: 0.7),
                          Band(.peakDip, frequency: 7000, gainDB: -8, q: 12)], gain: -6)
        let bins = 8192
        let meanPower = (0..<bins).reduce(0.0) { total, bin in
            let f = 20 * pow(1000.0, (Double(bin) + 0.5) / Double(bins))
            return total + pow(10, p.magnitudeDB(at: f) / 10) / Double(bins)
        }
        XCTAssertEqual(20 * log10(p.compareGain), 10 * log10(meanPower), accuracy: 0.002)
        XCTAssertGreaterThan(p.compareGain, p.preampGain * 2)
    }

    func testDesignAtAndAboveNyquist() throws {
        for kind: Band.Kind in [.highShelf, .peakDip, .bandPass, .bandStop, .highPass] {
            let clamped = try plan([Band(kind, frequency: 23520, gainDB: 6, q: 1)])
            for f in [23999.0, 24000, 30000] {
                let p = try plan([Band(kind, frequency: f, gainDB: 6, q: 1)])
                XCTAssertEqual(p.sections[0], clamped.sections[0])
            }
        }
        let shelf = try plan([Band(.lowShelf, frequency: 25000, gainDB: -6, q: 1)])
        XCTAssertEqual(shelf.magnitudeDB(at: 1000), -6, accuracy: 1e-12)
        XCTAssertEqual(try plan([Band(.highPass, frequency: 500)]).magnitudeDB(at: 0), -.infinity)
    }

    func testGuardAndWholeBandPriorityBudget() throws {
        let peak = try Band(.peakDip, frequency: 1000, gainDB: 3, q: 1)
        let bands = try [21600.0, 24000, 30000].map { try Band(.lowPass, frequency: $0) }
            + Array(repeating: peak, count: 23) + [Band(.highPass, frequency: 500, slope: 24), peak]
        var dropped: [Int] = []
        let p = try EqualizerPlan(.init(gainDB: -6, bands: bands), sampleRate: 48000, droppedBandIndices: &dropped)
        XCTAssertEqual(dropped, [1, 2, 26, 27])
        XCTAssertEqual(p.sections.count, 24)
        XCTAssertEqual(p.magnitudeDB(at: 1000), 63, accuracy: 1e-6)
        XCTAssertThrowsError(try plan([], rate: 0))
        XCTAssertThrowsError(try plan([], gain: .nan))
    }
}
