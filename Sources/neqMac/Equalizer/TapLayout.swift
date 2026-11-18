import CoreAudio
import EqualizerIO

struct TapLayout {
    let streamIndex: UInt32
    let streamCount: UInt32
    let buffers: EQInputLayout

    init(tapID: AudioStreamID, streams: [AudioStreamID], startingChannel: UInt32,
         bufferWidths: [UInt32], format: AudioStreamBasicDescription,
         streamFormat: AudioStreamBasicDescription) throws {
        guard tapID != kAudioObjectUnknown, Set(streams).count == streams.count,
              let streamIndex = streams.firstIndex(of: tapID),
              Self.supported(format), Self.supported(streamFormat),
              format.mSampleRate == streamFormat.mSampleRate, format.mFormatFlags == streamFormat.mFormatFlags,
              format.mChannelsPerFrame == streamFormat.mChannelsPerFrame,
              format.mBytesPerPacket == streamFormat.mBytesPerPacket, startingChannel > 0 else {
            throw SessionError.layout("Tap stream identity or Float32 format could not be verified")
        }
        let channels = format.mChannelsPerFrame
        let planar = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let planes = planar ? Int(channels) : 1
        let width: UInt32 = planar ? 1 : channels
        var firstChannel: UInt64 = 1
        guard let first = bufferWidths.indices.first(where: { i in
            defer { firstChannel += UInt64(bufferWidths[i]) }
            return firstChannel == UInt64(startingChannel)
        }), planes <= bufferWidths.count - first,
              bufferWidths[first..<(first + planes)].allSatisfy({ $0 == width }) else {
            throw SessionError.layout("Tap channel range does not match aggregate input buffers")
        }
        self.streamIndex = UInt32(streamIndex)
        streamCount = UInt32(streams.count)
        buffers = EQInputLayout(firstBuffer: UInt32(first), bufferCount: UInt32(planes),
                                totalBuffers: UInt32(bufferWidths.count), channelsPerBuffer: width)
    }

    static func supported(_ format: AudioStreamBasicDescription) -> Bool {
        let width = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 1 : Int(format.mChannelsPerFrame)
        return format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 &&
            format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 &&
            format.mChannelsPerFrame > 0 && format.mFramesPerPacket == 1 && format.mBytesPerFrame == width * 4
    }
}
