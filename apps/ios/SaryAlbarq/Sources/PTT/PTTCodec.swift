import AVFoundation

/// AAC-ELD (Enhanced Low Delay) at 16 kHz mono, 480 samples (30 ms) a packet,
/// through AudioToolbox's own converter — no third-party codec. About 15–25
/// kbit/s for speech; each packet fits one WebSocket frame many times over.
enum PTTAudioFormat {
    static let sampleRate = 16_000.0
    static let samplesPerPacket: AVAudioFrameCount = 480
    static let bitRate = 24_000

    static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    static let eld: AVAudioFormat = {
        var d = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC_ELD, mFormatFlags: 0, mBytesPerPacket: 0,
                                            mFramesPerPacket: UInt32(samplesPerPacket), mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &d)!
    }()
}

/// PCM (16 kHz mono float, exactly 480 samples) → one AAC-ELD packet. Not thread-safe: one queue.
final class PTTEncoder {
    private let converter: AVAudioConverter
    private let maxPacket: Int

    init?() {
        guard let c = AVAudioConverter(from: PTTAudioFormat.pcm, to: PTTAudioFormat.eld) else { return nil }
        c.bitRate = PTTAudioFormat.bitRate
        converter = c
        maxPacket = max(c.maximumOutputPacketSize, 256)
    }

    /// The codec carries state between packets: a new transmission starts clean.
    func reset() { converter.reset() }

    func encode(_ pcm: AVAudioPCMBuffer) -> Data? {
        let out = AVAudioCompressedBuffer(format: PTTAudioFormat.eld, packetCapacity: 1, maximumPacketSize: maxPacket)
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true
            s.pointee = .haveData
            return pcm
        }
        guard status != .error, out.packetCount > 0, out.byteLength > 0 else { return nil }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }
}

/// One AAC-ELD packet → 480 samples of PCM. Not thread-safe: one queue.
final class PTTDecoder {
    private let converter: AVAudioConverter

    init?() {
        guard let c = AVAudioConverter(from: PTTAudioFormat.eld, to: PTTAudioFormat.pcm) else { return nil }
        converter = c
    }

    func reset() { converter.reset() }

    func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        guard !packet.isEmpty, packet.count <= PTTFrame.maxBytes else { return nil }
        let inb = AVAudioCompressedBuffer(format: PTTAudioFormat.eld, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { inb.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        inb.byteLength = UInt32(packet.count)
        inb.packetCount = 1
        inb.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: PTTAudioFormat.pcm, frameCapacity: PTTAudioFormat.samplesPerPacket) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, s in
            if fed { s.pointee = .noDataNow; return nil }
            fed = true
            s.pointee = .haveData
            return inb
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

/// Cuts any stream of 16 kHz mono samples into exact 480-sample packets.
struct PTTChunker {
    private var pending: [Float] = []

    mutating func push(_ samples: UnsafeBufferPointer<Float>) -> [[Float]] {
        pending.append(contentsOf: samples)
        var out: [[Float]] = []
        let n = Int(PTTAudioFormat.samplesPerPacket)
        while pending.count >= n {
            out.append(Array(pending.prefix(n)))
            pending.removeFirst(n)
        }
        return out
    }

    mutating func reset() { pending.removeAll(keepingCapacity: true) }
}

extension AVAudioPCMBuffer {
    static func ptt(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: PTTAudioFormat.pcm, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return b
    }

    /// Root mean square of channel 0 (0 for silence).
    var pttRMS: Float {
        guard let d = floatChannelData?[0], frameLength > 0 else { return 0 }
        var s: Float = 0
        for i in 0..<Int(frameLength) { s += d[i] * d[i] }
        return (s / Float(frameLength)).squareRoot()
    }
}
