import CoreAudio
import Foundation
import Testing

@testable import TapEngine

@Suite("TapLevel.isSilent")
struct TapLevelTests {
    private func isSilent(_ samples: [Float32]) -> Bool {
        var samples = samples
        return samples.withUnsafeMutableBytes { bytes in
            TapLevel.isSilent(
                AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(bytes.count),
                    mData: bytes.baseAddress))
        }
    }

    @Test func exactZerosAreSilent() {
        #expect(isSilent([Float32](repeating: 0, count: 1024)))
        #expect(isSilent([]))
    }

    /// The line sits at about -90 dBFS peak: just under is silence, at or over
    /// it (either sign, one sample anywhere) is signal.
    @Test func thresholdIsAboutMinus90dBFS() {
        #expect(abs(20 * log10(Double(TapLevel.silencePeak)) + 90) < 0.2)
        var samples = [Float32](repeating: 0, count: 1024)
        samples[1023] = 3.1e-5
        #expect(isSilent(samples))
        samples[1023] = 3.2e-5
        #expect(!isSilent(samples))
        samples[1023] = -3.3e-5
        #expect(!isSilent(samples))
        samples[1023] = 0
        samples[0] = 1.0 / 32768  // one 16-bit LSB, -90.3 dBFS: below the line
        #expect(isSilent(samples))
        samples[0] = 2.0 / 32768
        #expect(!isSilent(samples))
    }
}

@Suite("TapLevel.isFloat32")
struct TapFormatTests {
    private func asbd(
        formatID: AudioFormatID = kAudioFormatLinearPCM,
        flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        bits: UInt32 = 32
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: formatID, mFormatFlags: flags,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: bits, mReserved: 0)
    }

    /// `isSilent` reinterprets the buffer as float32, so every other layout has
    /// to be recognised and left unmonitored rather than misjudged.
    @Test func onlyFloat32LinearPCMQualifies() {
        #expect(TapLevel.isFloat32(asbd()))
        #expect(
            !TapLevel.isFloat32(
                asbd(flags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked)))
        #expect(!TapLevel.isFloat32(asbd(bits: 16)))
        #expect(!TapLevel.isFloat32(asbd(bits: 64)))  // float64
        #expect(!TapLevel.isFloat32(asbd(formatID: kAudioFormatAppleLossless)))
    }
}
