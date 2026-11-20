import CoreAudio
import XCTest
@testable import neqMac

final class CoreAudioClientTests: XCTestCase {
    @available(macOS 14.2, *)
    func testLiveDefaultOutputIsCurrentAndHasNominalRate() throws {
        let client = CoreAudioClient()
        let id = try client.defaultDeviceID(for: .output)
        try XCTSkipIf(id == kAudioObjectUnknown, "No default output on this host")
        let devices = try client.devices()
        let output = try XCTUnwrap(devices.first { $0.audioObjectID == id && $0.direction == .output })
        let hardware = SystemEqualizerHardware()
        XCTAssertTrue(try hardware.isCurrent(output))
        XCTAssertGreaterThan(try XCTUnwrap(hardware.rate(output)), 0)
    }

    func testCoreAudioDiscoveryReadsLiveTransportMetadata() throws {
        let devices = try CoreAudioClient().devices()
        var checkedDevices = 0
        for device in devices {
            var transport: UInt32 = kAudioDeviceTransportTypeUnknown
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectGetPropertyData(device.audioObjectID, &address, 0, nil, &size, &transport)
            guard status == noErr, transport != kAudioDeviceTransportTypeUnknown else { continue }
            checkedDevices += 1
            XCTAssertEqual(device.transportType, transport)
        }
        try XCTSkipIf(checkedDevices == 0, "No audio devices with readable transport metadata are available")
    }
}
