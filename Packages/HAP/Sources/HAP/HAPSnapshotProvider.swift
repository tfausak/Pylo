import Foundation

/// Protocol for accessories that can capture snapshots (used by HAPConnection
/// for POST /resource without depending on HAPCameraAccessory directly).
public protocol HAPSnapshotProvider: HAPAccessoryProtocol, Sendable {
  var hksvEnabled: Bool { get }
  var periodicSnapshotsActive: Bool { get }
  var eventSnapshotsActive: Bool { get }
  func captureSnapshot(width: Int, height: Int) -> Data?
}
