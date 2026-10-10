import Foundation
import IOKit
import IOKit.hid
import os
import Combine
import QuartzCore

final class LidSensor: ObservableObject {
    // Thread-safe angle & velocity read directly by Metal without touching SwiftUI
    private var _atomicAngle: Double = 90.0
    private var _atomicVelocity: Double = 0.0
    private var _atomicTimestamp: CFTimeInterval = 0.0
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    // Sliding window of angle measurements for smooth velocity regression
    private var sampleHistory: [(timestamp: CFTimeInterval, angle: Double)] = []
    private let historyWindowDuration: CFTimeInterval = 0.14 // 140ms sliding window

    var latestAngle: Double {
        os_unfair_lock_lock(lock)
        let val = _atomicAngle
        os_unfair_lock_unlock(lock)
        return val
    }

    var latestVelocity: Double {
        os_unfair_lock_lock(lock)
        let val = _atomicVelocity
        os_unfair_lock_unlock(lock)
        return val
    }

    /// Extrapolates angle ahead in time based on smoothed angular velocity (dead-reckoning / lookahead)
    func extrapolatedAngle(lookahead: Double) -> Double {
        os_unfair_lock_lock(lock)
        let angle = _atomicAngle
        let velocity = _atomicVelocity
        let timestamp = _atomicTimestamp
        os_unfair_lock_unlock(lock)

        let now = CACurrentMediaTime()
        let elapsedSinceSample = max(0.0, now - timestamp)

        // If no new readings arrived for > 150ms, velocity gracefully fades to zero
        let decay = max(0.0, 1.0 - (elapsedSinceSample / 0.15))
        let effectiveVelocity = velocity * decay

        let totalForwardTime = elapsedSinceSample + lookahead
        var forwardDelta = effectiveVelocity * totalForwardTime

        // When lifting the lid up (effectiveVelocity > 0), maintain natural direction
        // but reduce the forward lookahead strength (0.30) and cap lead degrees so it doesn't race ahead
        if effectiveVelocity > 0 {
            forwardDelta *= -0.5
        }

        // Soft-clamp the maximum projection delta
        let maxLeadDegrees = effectiveVelocity > 0 ? 3.5 : 12.0
        forwardDelta = min(max(forwardDelta, -maxLeadDegrees), maxLeadDegrees)

        let projected = angle + forwardDelta
        return min(max(projected, 0.0), 180.0)
    }

    // Published for UI text label and automatic angle tracking
    @Published var displayAngle: Double = 90.0
    @Published var displayVelocity: Double = 0.0
    @Published var isAvailable: Bool = false

    var currentAngle: Double {
        displayAngle
    }

    var currentVelocity: Double {
        displayVelocity
    }

    var onAngleChanged: ((Double) -> Void)?

    private var hidManager: IOHIDManager?
    private var lidDevice: IOHIDDevice?
    private let sensorQueue = DispatchQueue(label: "com.lidperspective.sensor", qos: .userInteractive)
    private var isRunning = false
    private var uiUpdateCounter = 0

    init() {
        lock.initialize(to: os_unfair_lock())
        setupHIDManager()
    }

    deinit {
        isRunning = false
        if let hidManager = hidManager {
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        lock.deallocate()
    }

    private func setupHIDManager() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else { return }

        let matchCriteria: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey as String: 0x0020,
                kIOHIDDeviceUsageKey as String: 0x008A
            ],
            [
                kIOHIDDeviceUsagePageKey as String: 0x0020
            ]
        ]

        IOHIDManagerSetDeviceMatchingMultiple(manager, matchCriteria as CFArray)
        let openStatus = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openStatus == kIOReturnSuccess else { return }

        locateLidDevice()
        isAvailable = (lidDevice != nil)
        startLoop()
    }

    private func locateLidDevice() {
        guard let manager = hidManager,
              let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }

        for device in deviceSet {
            var testReport = [UInt8](repeating: 0, count: 8)
            var reportLength = testReport.count
            let status = IOHIDDeviceGetReport(
                device,
                kIOHIDReportTypeFeature,
                CFIndex(1),
                &testReport,
                &reportLength
            )

            if status == kIOReturnSuccess && reportLength >= 3 {
                self.lidDevice = device
                DispatchQueue.main.async { [weak self] in
                    self?.isAvailable = true
                }
                return
            }
        }
    }

    private func startLoop() {
        isRunning = true
        sensorQueue.async { [weak self] in
            guard let self = self else { return }
            var report = [UInt8](repeating: 0, count: 8)

            while self.isRunning {
                guard let device = self.lidDevice else {
                    self.locateLidDevice()
                    usleep(50000)
                    continue
                }

                var length = report.count
                let result = IOHIDDeviceGetReport(
                    device,
                    kIOHIDReportTypeFeature,
                    CFIndex(1),
                    &report,
                    &length
                )

                if result == kIOReturnSuccess && length >= 3 {
                    let rawValue = UInt16(report[1]) | (UInt16(report[2]) << 8)
                    let angle = Double(rawValue)

                    if angle >= 0 && angle <= 180 {
                        let now = CACurrentMediaTime()

                        // Maintain sliding history of angle samples over the last window
                        self.sampleHistory.append((timestamp: now, angle: angle))
                        let cutoff = now - self.historyWindowDuration
                        self.sampleHistory.removeAll { $0.timestamp < cutoff }

                        // Calculate angular velocity using linear regression slope (degrees / sec)
                        var calculatedVelocity = 0.0
                        let count = self.sampleHistory.count
                        if count >= 2 {
                            var sumT = 0.0
                            var sumA = 0.0
                            for sample in self.sampleHistory {
                                sumT += sample.timestamp
                                sumA += sample.angle
                            }
                            let meanT = sumT / Double(count)
                            let meanA = sumA / Double(count)

                            var numerator = 0.0
                            var denominator = 0.0
                            for sample in self.sampleHistory {
                                let dt = sample.timestamp - meanT
                                let da = sample.angle - meanA
                                numerator += dt * da
                                denominator += dt * dt
                            }

                            if denominator > 1e-6 {
                                calculatedVelocity = numerator / denominator
                                // Clamp to physical human bounds
                                calculatedVelocity = min(max(calculatedVelocity, -360.0), 360.0)
                                // Deadzone sensor noise (< 0.4 deg/sec)
                                if abs(calculatedVelocity) < 0.4 {
                                    calculatedVelocity = 0.0
                                }
                            }
                        }

                        // Store the pure hardware sensor angle, velocity, and timestamp
                        os_unfair_lock_lock(self.lock)
                        let prev = self._atomicAngle
                        self._atomicAngle = angle
                        self._atomicVelocity = calculatedVelocity
                        self._atomicTimestamp = now
                        os_unfair_lock_unlock(self.lock)

                        // Detect 90° threshold crossing immediately
                        let crossedThreshold = (prev >= 90.0 && angle < 90.0) || (prev < 90.0 && angle >= 90.0)
                        let isNearThreshold = (angle >= 85.0 && angle <= 112.0)
                        let isMoving = abs(calculatedVelocity) > 0.8
                        let shouldDispatchFast = crossedThreshold || isNearThreshold || isMoving

                        // Low latency dispatch in critical transition zones (~8ms), throttled when stationary (~32ms)
                        self.uiUpdateCounter += 1
                        let thresholdLimit = crossedThreshold ? 1 : (shouldDispatchFast ? 2 : 8)
                        if self.uiUpdateCounter >= thresholdLimit {
                            self.uiUpdateCounter = 0
                            DispatchQueue.main.async {
                                self.displayAngle = angle
                                self.displayVelocity = calculatedVelocity
                                self.onAngleChanged?(angle)
                            }
                        }
                    }
                }

                // Sleep 4ms after reading to prevent queue backlog
                usleep(4000)
            }
        }
    }
}
