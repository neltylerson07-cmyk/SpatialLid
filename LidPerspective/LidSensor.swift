import Foundation
import IOKit
import IOKit.hid
import os
import Combine

final class LidSensor: ObservableObject {
    // Thread-safe angle read directly by Metal without touching SwiftUI
    private var _atomicAngle: Double = 90.0
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    var latestAngle: Double {
        os_unfair_lock_lock(lock)
        let val = _atomicAngle
        os_unfair_lock_unlock(lock)
        return val
    }

    // Published for UI text label and automatic angle tracking
    @Published var displayAngle: Double = 90.0

    var currentAngle: Double {
        displayAngle
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
                        // Store the pure hardware sensor angle directly
                        os_unfair_lock_lock(self.lock)
                        let prev = self._atomicAngle
                        self._atomicAngle = angle
                        os_unfair_lock_unlock(self.lock)

                        // Detect 90° threshold crossing immediately
                        let crossedThreshold = (prev >= 90.0 && angle < 90.0) || (prev < 90.0 && angle >= 90.0)

                        // Update UI label at ~12 Hz to prevent main thread overhead,
                        // or immediately when crossing 90° threshold
                        self.uiUpdateCounter += 1
                        if crossedThreshold || self.uiUpdateCounter >= 10 {
                            self.uiUpdateCounter = 0
                            DispatchQueue.main.async {
                                self.displayAngle = angle
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
