import Encoders
import Foundation
import Testing

@testable import TapEngine

/// `reportsTapActivity` decides whether the silent-tap monitor runs at all, and
/// the engine tests drive a stub that is simply told what to answer. These pin
/// the real session's own property, which needs no Core Audio state: both of
/// its conjuncts are readable straight after `init`.
@Suite("SystemCaptureSession.reportsTapActivity")
struct SystemCaptureSessionTests {
    private let format = PCMFormat(sampleRate: 16000, bitsPerSample: 16, channels: 1)

    private func session(micDeviceUID: String?) -> SystemCaptureSession {
        SystemCaptureSession(
            scope: .system(excluding: []), micDeviceUID: micDeviceUID, outputFormat: format)
    }

    /// No microphone means the tap clocks the aggregate itself, so a tap that
    /// dies stops delivering buffers altogether. That is the stall watchdog's
    /// case, and monitoring tap silence there would probe a capture that is
    /// simply quiet. The mic-only path is safe by type, since `MicCaptureSession`
    /// does not conform to `TapHealthCaptureSession`, but this path rests
    /// entirely on this one conjunct.
    @Test func aSystemCaptureWithNoMicrophoneIsNotMonitored() {
        #expect(session(micDeviceUID: nil).reportsTapActivity == false)
    }

    /// With a mic clocking the aggregate the tap can die while buffers keep
    /// arriving, which is the case the monitor exists for. The answer is true
    /// before `start` because the owner has to install its callback first; the
    /// stream format that can retract it is only read inside `configure`.
    @Test func aSystemCaptureMixedWithAMicrophoneIsMonitored() {
        #expect(session(micDeviceUID: "BuiltInMicrophoneDevice").reportsTapActivity == true)
    }
}
