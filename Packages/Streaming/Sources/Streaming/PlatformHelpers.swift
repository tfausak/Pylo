import AVFoundation
import os

#if os(iOS)
  import UIKit
#endif

// MARK: - AVCaptureSession Helpers

extension AVCaptureSession {
  /// Enable multitasking camera access if supported (iOS 16+ only, no-op on macOS).
  nonisolated func enableMultitaskingCameraIfSupported() {
    #if os(iOS)
      if #available(iOS 16.0, *), isMultitaskingCameraAccessSupported {
        isMultitaskingCameraAccessEnabled = true
      }
    #endif
  }

  /// Extract the interruption reason from a session-interrupted notification.
  /// Returns nil on macOS where the key is unavailable.
  nonisolated static func interruptionReason(from notification: Notification) -> Int? {
    #if os(iOS)
      return notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
    #else
      return nil
    #endif
  }
}

// MARK: - Audio Session

/// Configure the shared AVAudioSession for voice chat recording (iOS only, no-op on macOS).
nonisolated func configureAudioSessionForVoiceChat(logger: Logger) {
  #if os(iOS)
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
      try session.setPreferredSampleRate(16000)
      try session.setActive(true)
    } catch {
      logger.error("AVAudioSession setup error: \(error)")
    }
  #endif
}
