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
    /// Builds a throwaway tap with the session's scope, listens for up to
    /// `maxSeconds`, and returns true as soon as it hears a non-silent sample.
    /// Blocks the caller; never touches the live capture.
    func probeTap(maxSeconds: Double) -> Bool
    /// One line describing the tap and the output device, for the log line
    /// written when a tap is found dead.
    var tapDiagnostics: String { get }
}

/// Tap-side level check shared by the live IOProc and the probe.
enum TapLevel {
    /// About -90 dBFS: below any real signal, above denormal noise.
    static let silencePeak: Float32 = 3.2e-5

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
    static func hearsAudio(scope: TapScope, maxSeconds: Double) -> Bool {
        guard let tap = try? ProcessTap(scope: scope) else { return false }
        defer { tap.destroy() }

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
        guard
            AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID) == noErr,
            aggregateID != kAudioObjectUnknown
        else { return false }
        defer { AudioHardwareDestroyAggregateDevice(aggregateID) }

        let heard = DispatchSemaphore(value: 0)
        let once = NSLock()
        nonisolated(unsafe) var signalled = false
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, aggregateID, DispatchQueue(label: "hark.tap.probe")
        ) { _, inInputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            guard let tapBuffer = buffers.last, !TapLevel.isSilent(tapBuffer) else { return }
            once.lock()
            let first = !signalled
            signalled = true
            once.unlock()
            if first { heard.signal() }
        }
        guard status == noErr, let ioProcID else { return false }
        defer { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }

        guard AudioDeviceStart(aggregateID, ioProcID) == noErr else { return false }
        defer { AudioDeviceStop(aggregateID, ioProcID) }
        return heard.wait(timeout: .now() + maxSeconds) == .success
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
