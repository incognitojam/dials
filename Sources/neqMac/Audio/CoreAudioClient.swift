import CoreAudio
import Foundation

enum CoreAudioError: LocalizedError {
    case propertyRead(selector: AudioObjectPropertySelector, status: OSStatus)
    case propertyWrite(selector: AudioObjectPropertySelector, status: OSStatus)
    case missingValue(selector: AudioObjectPropertySelector)

    var errorDescription: String? {
        switch self {
        case let .propertyRead(selector, status):
            "Could not read Core Audio property \(fourCharacterCode(selector)) (OSStatus \(status))."
        case let .propertyWrite(selector, status):
            "Could not change Core Audio property \(fourCharacterCode(selector)) (OSStatus \(status))."
        case let .missingValue(selector):
            "Core Audio returned no value for \(fourCharacterCode(selector))."
        }
    }

    private func fourCharacterCode(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }
}

protocol AudioDeviceClient: AnyObject {
    var onHardwareChange: (() -> Void)? { get set }
    func devices() throws -> [AudioDevice]
    func defaultDeviceID(for direction: DeviceDirection) throws -> AudioObjectID
    func defaultSystemOutputDeviceID() throws -> AudioObjectID
    func setDefaultDevice(_ device: AudioDevice, includeSystemSounds: Bool) throws
}

final class CoreAudioClient: AudioDeviceClient {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    var onHardwareChange: (() -> Void)?

    init() {
        installListeners()
    }

    deinit {
        removeListeners()
    }

    func devices() throws -> [AudioDevice] {
        let ids: [AudioObjectID] = try readArray(
            objectID: systemObject,
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        )

        return ids.flatMap { id -> [AudioDevice] in
            guard let uid = try? readString(
                objectID: id,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ) else {
                // Devices can remain in Core Audio's list briefly while being
                // torn down. An object ID is not stable enough to persist.
                return []
            }
            let name = (try? readString(
                objectID: id,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
            )) ?? AudioDevice.unknownName
            // Constrain the generic read inside try? so its storage is UInt32, not Optional<UInt32>.
            let transport = (try? readScalar(
                objectID: id,
                selector: kAudioDevicePropertyTransportType,
                scope: kAudioObjectPropertyScopeGlobal
            ) as UInt32) ?? kAudioDeviceTransportTypeUnknown

            var result: [AudioDevice] = []
            if hasStreams(deviceID: id, scope: kAudioDevicePropertyScopeInput) {
                result.append(AudioDevice(
                    audioObjectID: id,
                    uid: uid,
                    name: name,
                    direction: .input,
                    transportType: transport
                ))
            }
            if hasStreams(deviceID: id, scope: kAudioDevicePropertyScopeOutput) {
                result.append(AudioDevice(
                    audioObjectID: id,
                    uid: uid,
                    name: name,
                    direction: .output,
                    transportType: transport
                ))
            }
            return result
        }
        .sorted {
            if $0.direction != $1.direction {
                return $0.direction.rawValue < $1.direction.rawValue
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func defaultDeviceID(for direction: DeviceDirection) throws -> AudioObjectID {
        let selector = direction == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        return try readScalar(
            objectID: systemObject,
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    func defaultSystemOutputDeviceID() throws -> AudioObjectID {
        try readScalar(
            objectID: systemObject,
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    func setDefaultDevice(_ device: AudioDevice, includeSystemSounds: Bool) throws {
        let selector = device.direction == .input
            ? kAudioHardwarePropertyDefaultInputDevice
            : kAudioHardwarePropertyDefaultOutputDevice
        try writeScalar(
            device.audioObjectID,
            objectID: systemObject,
            selector: selector,
            scope: kAudioObjectPropertyScopeGlobal
        )

        if device.direction == .output, includeSystemSounds {
            try writeScalar(
                device.audioObjectID,
                objectID: systemObject,
                selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                scope: kAudioObjectPropertyScopeGlobal
            )
        }
    }

    private func installListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onHardwareChange?()
        }
        listenerBlock = block

        for selector in Self.observedSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(systemObject, &address, .main, block)
        }
    }

    private func removeListeners() {
        guard let listenerBlock else { return }
        for selector in Self.observedSelectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, .main, listenerBlock)
        }
    }

    private static let observedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice
    ]

    private func hasStreams(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        return status == noErr && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> String {
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
        }
        guard status == noErr else {
            throw CoreAudioError.propertyRead(selector: selector, status: status)
        }
        return value as String
    }

    private func readScalar<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> T {
        var size = UInt32(MemoryLayout<T>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size,
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }

        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage)
        guard status == noErr else {
            throw CoreAudioError.propertyRead(selector: selector, status: status)
        }
        guard size == UInt32(MemoryLayout<T>.size) else {
            throw CoreAudioError.missingValue(selector: selector)
        }
        return storage.load(as: T.self)
    }

    private func readArray<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard status == noErr else {
            throw CoreAudioError.propertyRead(selector: selector, status: status)
        }
        guard size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<T>.stride
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { storage.deallocate() }

        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage)
        guard status == noErr else {
            throw CoreAudioError.propertyRead(selector: selector, status: status)
        }
        let buffer = UnsafeBufferPointer(start: storage.assumingMemoryBound(to: T.self), count: count)
        return Array(buffer)
    }

    private func writeScalar<T>(
        _ value: T,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws {
        var value = value
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<T>.size),
                $0
            )
        }
        guard status == noErr else {
            throw CoreAudioError.propertyWrite(selector: selector, status: status)
        }
    }
}
