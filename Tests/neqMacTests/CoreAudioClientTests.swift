import CoreAudio
import XCTest
@testable import neqMac

final class CoreAudioClientTests: XCTestCase {
    private func defaultOutput() throws -> AudioDevice {
        let client = CoreAudioClient()
        let id = try client.defaultDeviceID(for: .output)
        try XCTSkipIf(id == kAudioObjectUnknown, "No default output on this host")
        let devices = try client.devices()
        let output = devices.first { $0.audioObjectID == id && $0.direction == .output }
        try XCTSkipUnless(output != nil, "Default output unavailable in device discovery")
        return try XCTUnwrap(output)
    }

    @available(macOS 14.2, *)
    func testLiveOutputMetadataWithoutCreatingTap() throws {
        let output = try defaultOutput()
        let backend = CoreAudioTap(output: output, queue: .main, changed: {})
        _ = try backend.physicalInputsBeforeCapture()
        XCTAssertFalse(backend.removed)
        XCTAssertNotNil(backend.otherProcessPlaying)
        let scope = kAudioObjectPropertyScopeGlobal
        let frames: UInt32 = try CoreAudioClient.readScalar(objectID: output.audioObjectID,
            selector: kAudioDevicePropertyBufferFrameSize, scope: scope)
        XCTAssertGreaterThan(frames, 0)
        let streams = try CoreAudioClient.readArray(objectID: output.audioObjectID,
            selector: kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        let format: AudioStreamBasicDescription = try CoreAudioClient.readScalar(objectID: XCTUnwrap(streams.first),
            selector: kAudioStreamPropertyVirtualFormat, scope: scope)
        XCTAssertGreaterThan(format.mChannelsPerFrame, 0)
        XCTAssertGreaterThan(format.mSampleRate, 0)
    }

    @available(macOS 14.2, *)
    func testLiveDefaultOutputIsCurrentAndHasNominalRate() throws {
        let output = try defaultOutput()
        let hardware = SystemEqualizerHardware()
        XCTAssertTrue(try hardware.isCurrent(output))
        XCTAssertGreaterThan(try hardware.rate(output), 0)
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
