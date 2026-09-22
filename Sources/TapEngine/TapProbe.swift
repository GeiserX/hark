import CoreAudio
import Foundation

/// A capture session whose system side is a process tap that can go dead while
/// buffers keep arriving: with a microphone as the aggregate's clock master the
/// IOProc never stalls, it just delivers zeros on the tap stream. The session
/// reports per-cycle tap silence and can be asked whether a *fresh* tap hears
/// audio, which is what tells a dead tap from a quiet room.
public protocol TapHealthCaptureSession: CaptureSession {
    /// Called on the IO thread once per cycle with whether the tap stream was
    /// digitally silent. Set before `start`. Only invoked when a microphone
    /// clocks the aggregate; a tap that is its own clock stops delivering
    /// instead, which the stall watchdog already handles.
    var onTapActivity: (@Sendable (_ silent: Bool) -> Void)? { get set }
    /// False when the tap is its own clock (no mic): nothing to monitor.
    var reportsTapActivity: Bool { get }
    /// Builds a throwaway tap with the session's scope and listens for up to
    /// `maxSeconds`, returning as soon as it hears a non-silent sample. Blocks
    /// the caller; never touches the live capture.
    func probeTap(maxSeconds: Double) -> TapProbeResult
    /// One line describing the tap and the output device, for the log line
    /// written when a tap is found dead.
    var tapDiagnostics: String { get }
}

public enum TapProbeResult: Sendable, Equatable {
    case heardAudio
    case silent
    /// The throwaway tap could not be built or started, so it says nothing
    /// about the live one.
    case failed(String)
}

/// Tap-side level check shared by the live IOProc and the probe.
enum TapLevel {
    /// About -90 dBFS: below any real signal, above denormal noise.
    static let silencePeak: Float32 = 3.2e-5

    /// True when `asbd` is the packed 32-bit float layout `isSilent` reads. A tap
    /// stream in any other format would make the silence verdict meaningless in
    /// both directions — a false "non-silent" leaves a dead tap unnoticed, a
    /// false "silent" rebuilds a healthy tap and puts a real gap in the
    /// recording — so such a stream is not monitored at all.
    static func isFloat32(_ asbd: AudioStreamBasicDescription) -> Bool {
        asbd.mFormatID == kAudioFormatLinearPCM
            && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && asbd.mBitsPerChannel == 32
    }

    /// True when every float32 sample in `buffer` is below `silencePeak`.
    static func isSilent(_ buffer: AudioBuffer) -> Bool {
        guard let samples = buffer.mData?.assumingMemoryBound(to: Float32.self) else { return true }
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
        for index in 0..<count where abs(samples[index]) >= silencePeak { return false }
        return true
    }
}

/// A second, short-lived tap + tap-only private aggregate used to check
/// whether the system is producing audio right now.
enum TapProbe {
    static func listen(scope: TapScope, maxSeconds: Double) -> TapProbeResult {
        let tap: ProcessTap
        do { tap = try ProcessTap(scope: scope) } catch { return .failed("\(error)") }
        defer { tap.destroy() }
        guard TapLevel.isFloat32(tap.format) else {
            return .failed("tap stream is not 32-bit float")
        }

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "hark-probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            return .failed("\(TapEngineError.aggregateCreationFailed(status))")
        }
        defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

        // Signalling more than once is harmless: the surplus count dies with the
        // semaphore when `listen` returns.
        let heard = DispatchSemaphore(value: 0)
        var ioProcID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, aggregateID, DispatchQueue(label: "hark.tap.probe")
        ) { _, inInputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let tapBuffer = buffers.last, !TapLevel.isSilent(tapBuffer) else { return }
            heard.signal()
        }
        guard status == noErr, let ioProcID else {
            return .failed("\(TapEngineError.ioProcFailed(status))")
        }
        defer { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { return .failed("\(TapEngineError.ioProcFailed(status))") }
        defer { AudioDeviceStop(aggregateID, ioProcID) }
        return heard.wait(timeout: .now() + maxSeconds) == .success ? .heardAudio : .silent
    }

    /// "output <id> [<uid>] @ <rate> Hz" for the current default output device.
    static func defaultOutputDescription() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != kAudioObjectUnknown
        else { return "output unknown" }

        let uid = (try? AudioObjectProperty.readTapString(deviceID, kAudioDevicePropertyDeviceUID)) ?? "?"
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        var rate: Double = 0
        size = UInt32(MemoryLayout<Double>.size)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
        return "output \(deviceID) [\(uid)] @ \(Int(rate)) Hz"
    }
}
