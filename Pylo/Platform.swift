import AVFoundation
import CoreImage
import SwiftUI
import os

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

// MARK: - Platform Image

#if os(iOS)
  typealias PlatformImage = UIImage
#elseif os(macOS)
  typealias PlatformImage = NSImage
#endif

extension PlatformImage {
  /// Create a platform image from a CGImage.
  static func from(cgImage: CGImage) -> PlatformImage {
    #if os(iOS)
      return UIImage(cgImage: cgImage)
    #elseif os(macOS)
      return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    #endif
  }
}

extension Image {
  /// Create a SwiftUI Image from a PlatformImage.
  init(platformImage: PlatformImage) {
    #if os(iOS)
      self.init(uiImage: platformImage)
    #elseif os(macOS)
      self.init(nsImage: platformImage)
    #endif
  }
}

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

// MARK: - Settings

/// Open the system settings/preferences for this app.
func openAppSettings() {
  #if os(iOS)
    if let url = URL(string: UIApplication.openSettingsURLString) {
      UIApplication.shared.open(url)
    }
  #elseif os(macOS)
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
      NSWorkspace.shared.open(url)
    }
  #endif
}
