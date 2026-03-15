import Testing

@testable import Sensors

@Suite struct AmbientLightDetectorTests {

  // MARK: - estimateLux

  @Test func estimateLuxBasicCalculation() {
    // lux = 12.5 * f^2 / (ISO * t)
    // f=2.0, ISO=100, t=1/100 → 12.5 * 4 / (100 * 0.01) = 50 / 1 = 50
    let lux = AmbientLightDetector.estimateLux(iso: 100, exposureDuration: 0.01, aperture: 2.0)
    #expect(abs(lux - 50.0) < 0.01)
  }

  @Test func estimateLuxClampsToMinimum() {
    // Very bright: high aperture, low ISO, short exposure → huge raw value,
    // but we test the minimum clamp with very high ISO and long exposure.
    let lux = AmbientLightDetector.estimateLux(
      iso: 100_000, exposureDuration: 10.0, aperture: 1.0)
    #expect(lux >= 0.0001)
  }

  @Test func estimateLuxClampsToMaximum() {
    // Very low ISO, very short exposure, wide aperture → huge lux
    let lux = AmbientLightDetector.estimateLux(
      iso: 1, exposureDuration: 0.000001, aperture: 2.0)
    #expect(lux == 100_000)
  }

  @Test func estimateLuxInverseRelationshipWithISO() {
    let lux1 = AmbientLightDetector.estimateLux(iso: 100, exposureDuration: 0.01, aperture: 2.0)
    let lux2 = AmbientLightDetector.estimateLux(iso: 200, exposureDuration: 0.01, aperture: 2.0)
    #expect(abs(lux1 / lux2 - 2.0) < 0.01)
  }

  @Test func estimateLuxInverseRelationshipWithDuration() {
    let lux1 = AmbientLightDetector.estimateLux(iso: 100, exposureDuration: 0.01, aperture: 2.0)
    let lux2 = AmbientLightDetector.estimateLux(iso: 100, exposureDuration: 0.02, aperture: 2.0)
    #expect(abs(lux1 / lux2 - 2.0) < 0.01)
  }

  @Test func estimateLuxSquareRelationshipWithAperture() {
    let lux1 = AmbientLightDetector.estimateLux(iso: 100, exposureDuration: 0.01, aperture: 2.0)
    let lux2 = AmbientLightDetector.estimateLux(iso: 100, exposureDuration: 0.01, aperture: 4.0)
    #expect(abs(lux2 / lux1 - 4.0) < 0.01)
  }

  // MARK: - shouldNotify

  @Test func shouldNotifyFirstReading() {
    #expect(AmbientLightDetector.shouldNotify(previous: 0, current: 42.0))
  }

  @Test func shouldNotifyLargeChange() {
    // 20% change
    #expect(AmbientLightDetector.shouldNotify(previous: 100, current: 120))
  }

  @Test func shouldNotNotifySmallChange() {
    // 5% change
    #expect(!AmbientLightDetector.shouldNotify(previous: 100, current: 105))
  }

  @Test func shouldNotifyAtThresholdBoundary() {
    // Exactly 10% — not greater than, so should NOT notify
    #expect(!AmbientLightDetector.shouldNotify(previous: 100, current: 110))
    // Just over 10%
    #expect(AmbientLightDetector.shouldNotify(previous: 100, current: 110.1))
  }

  @Test func shouldNotifyWorksForDecreases() {
    // 15% decrease
    #expect(AmbientLightDetector.shouldNotify(previous: 100, current: 85))
  }
}
