import XCTest
@testable import EqualizerCore

final class PlaybackPlanTests: XCTestCase {
    func testHeadroomAtNarrowBandCenterAndCompareGain() throws {
        let band = try Band(.peakDip, frequency: 1234.567, gainDB: 20, q: 900)
        let profile = ParametricEQ(gainDB: 30, bands: [band])
        for rate in [44_100.0, 96_000] {
            let raw = try EqualizerPlan(profile, sampleRate: rate)
            let capped = try EqualizerPlan.playback(profile, sampleRate: rate)
            XCTAssertEqual(capped.headroomDB, 50, accuracy: 0.00001)
            XCTAssertEqual(capped.magnitudeDB(at: band.frequency), 0, accuracy: 0.00001)
            XCTAssertEqual(capped.compareGain / raw.compareGain, capped.preampGain / raw.preampGain, accuracy: 1e-12)
        }
    }

    func testInfrasonicPeakAndShelfStayBelowCeilingThroughDC() throws {
        let bands = [try Band(.peakDip, frequency: 5, gainDB: 30, q: 4),
                     try Band(.lowShelf, frequency: 8, gainDB: 24, q: 0.7),
                     try Band(.peakDip, frequency: 0.5, gainDB: 10, q: 40)]
        for band in bands {
            let plan = try EqualizerPlan.playback(.init(gainDB: 0, bands: [band]), sampleRate: 48_000)
            XCTAssertEqual(plan.headroomDB, band.gainDB, accuracy: 0.01)
            var peak = max(plan.magnitudeDB(at: 0), plan.magnitudeDB(at: band.frequency))
            for bin in 0...40_000 {
                let hz = min(24_000, 0.01 * pow(2_400_000, Double(bin) / 40_000))
                peak = max(peak, plan.magnitudeDB(at: hz))
            }
            XCTAssertLessThanOrEqual(peak, 0.01)
        }
    }

    func testGridFindsPeakBetweenBandsAndPreservesCuts() throws {
        let bands = try [1000.0, 1250].map { try Band(.peakDip, frequency: $0, gainDB: 10, q: 1) }
        let profile = ParametricEQ(gainDB: 0, bands: bands)
        let raw = try EqualizerPlan(profile, sampleRate: 48_000)
        let safe = try EqualizerPlan.playback(profile, sampleRate: 48_000)
        XCTAssertGreaterThan(safe.headroomDB, raw.magnitudeDB(at: 1000))
        XCTAssertLessThanOrEqual((1000...1250).map { safe.magnitudeDB(at: Double($0)) }.max()!, 1e-8)
        let cut = try EqualizerPlan.playback(.init(gainDB: -6, bands: []), sampleRate: 48_000)
        XCTAssertEqual(cut.headroomDB, 0)
        XCTAssertEqual(cut.magnitudeDB(at: 1000), -6, accuracy: 1e-10)
    }
}
