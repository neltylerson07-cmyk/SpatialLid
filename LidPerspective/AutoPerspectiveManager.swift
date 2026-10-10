import Foundation
import SwiftUI
import Combine

@MainActor
final class AutoPerspectiveManager: ObservableObject {
    @Published var isAutoModeEnabled: Bool = true {
        didSet {
            handleAutoModeToggled()
        }
    }
    @Published var isAutoSettleEnabled: Bool = true
    @Published var isArmed: Bool = false
    @Published var isCapturing: Bool = false
    @Published var statusDescription: String = "Initializing..."

    let sensor: LidSensor
    let captureManager: ScreenCaptureManager
    let overlayController: FullscreenOverlayController

    let closeThreshold: Double = 90.0
    let rearmThreshold: Double = 92.0 // Hysteresis to prevent jitter near 90°
    let minUsableAngle: Double = 10.0 // Below 10° screen is closing shut

    // Settle tracking
    private var dwellTimerTask: Task<Void, Never>?
    private var dwellReferenceAngle: Double = 90.0
    private var lastSettledAngle: Double?

    init(
        sensor: LidSensor,
        captureManager: ScreenCaptureManager,
        overlayController: FullscreenOverlayController
    ) {
        self.sensor = sensor
        self.captureManager = captureManager
        self.overlayController = overlayController

        let initialAngle = sensor.displayAngle
        if initialAngle >= closeThreshold {
            self.isArmed = true
            self.statusDescription = "Armed — Close lid (<90°) to activate"
        } else {
            self.isArmed = false
            self.lastSettledAngle = initialAngle >= minUsableAngle ? initialAngle : nil
            self.statusDescription = "Open lid past 90° to arm automatic mode"
        }

        sensor.onAngleChanged = { [weak self] angle in
            self?.handleAngleUpdate(angle)
        }
    }

    func handleAngleUpdate(_ angle: Double) {
        guard isAutoModeEnabled else {
            dwellTimerTask?.cancel()
            dwellTimerTask = nil
            statusDescription = "Automatic mode disabled"
            return
        }

        // If overlay is currently displayed
        if overlayController.isShowing {
            if angle >= rearmThreshold {
                // Lid opened past 90° -> cancel settle, dismiss overlay and re-arm
                dwellTimerTask?.cancel()
                dwellTimerTask = nil
                overlayController.cancelSettling()
                overlayController.dismiss()
                isArmed = true
                lastSettledAngle = nil
                statusDescription = "Armed — Close lid (<90°) to activate"
                return
            }

            if angle < minUsableAngle {
                // Lid closing shut (<10°)
                dwellTimerTask?.cancel()
                dwellTimerTask = nil
                overlayController.cancelSettling()
                statusDescription = "Lid closing"
                return
            }

            // Overlay active between minUsableAngle and closeThreshold
            if isAutoSettleEnabled {
                let velocity = abs(sensor.latestVelocity)
                let angleDelta = abs(angle - dwellReferenceAngle)

                // Moving if velocity exceeds deadzone or angle shifted by > 0.8°
                if velocity > 2.0 || angleDelta > 0.8 {
                    dwellReferenceAngle = angle

                    // If user resumes moving while it was unwarping, cancel unwarp and resume perspective
                    if overlayController.isSettling {
                        overlayController.cancelSettling()
                    }

                    // Restart 1.0-second dwell timer
                    scheduleDwellTimer()
                    statusDescription = String(format: "Perspective active (%.1f°)", angle)
                } else if !overlayController.isSettling {
                    // Holding steady: schedule if not already scheduled
                    if dwellTimerTask == nil {
                        scheduleDwellTimer()
                    }
                    statusDescription = String(format: "Perspective active (%.1f°)", angle)
                }
            } else {
                statusDescription = String(format: "Perspective active (%.1f°)", angle)
            }
            return
        }

        // Overlay is not showing. Avoid capturing if already capturing.
        guard !isCapturing else { return }

        if angle >= rearmThreshold {
            if !isArmed {
                isArmed = true
            }
            lastSettledAngle = nil
            statusDescription = "Armed — Close lid (<90°) to activate"
        } else if angle < closeThreshold && angle >= minUsableAngle {
            if isArmed {
                isArmed = false
                lastSettledAngle = nil
                triggerPerspective()
            } else if let settledAngle = lastSettledAngle {
                // Screen was settled at a low angle. Check if user adjusts the lid again!
                let velocity = abs(sensor.latestVelocity)
                let angleDelta = abs(angle - settledAngle)
                if velocity > 2.2 || angleDelta > 1.5 {
                    // Lid adjustment detected! Reactivate perspective mode
                    lastSettledAngle = nil
                    triggerPerspective()
                }
            }
        }
    }

    private func scheduleDwellTimer() {
        dwellTimerTask?.cancel()
        dwellTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1.0 second
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            self.handleDwellTimeout()
        }
    }

    private func handleDwellTimeout() {
        guard overlayController.isShowing, !overlayController.isSettling else { return }
        guard !overlayController.viewState.showCalibrator else { return }
        let currentAngle = sensor.displayAngle
        guard currentAngle >= minUsableAngle && currentAngle < closeThreshold else { return }

        statusDescription = String(format: "Lid settled at %.1f° — Returning to screen...", currentAngle)
        let settledAngle = currentAngle

        overlayController.unwarpAndDismiss { [weak self] in
            guard let self = self else { return }
            self.lastSettledAngle = settledAngle
            self.statusDescription = String(format: "Screen ready (%.1f°) — Adjust lid to reactivate", settledAngle)
        }
    }

    func triggerPerspective(showCalibrator: Bool = false) {
        guard !isCapturing && !overlayController.isShowing else {
            if overlayController.isShowing && showCalibrator {
                overlayController.viewState.showCalibrator = true
                overlayController.viewState.requestRender()
            }
            return
        }
        isCapturing = true
        dwellTimerTask?.cancel()
        dwellTimerTask = nil
        dwellReferenceAngle = sensor.displayAngle
        statusDescription = "Lid closing detected (<90°) — Capturing screen..."

        Task { [weak self] in
            guard let self = self else { return }
            if let snapshot = await self.captureManager.captureCurrentScreen() {
                self.dwellReferenceAngle = self.sensor.displayAngle
                if self.isAutoSettleEnabled && !showCalibrator {
                    self.scheduleDwellTimer()
                }
                self.overlayController.show(snapshot: snapshot, sensor: self.sensor, showCalibrator: showCalibrator) { [weak self] in
                    self?.handleOverlayDismissed()
                }
                self.statusDescription = "Perspective active"
            } else {
                self.statusDescription = "Screen capture failed"
            }
            self.isCapturing = false
        }
    }

    private func handleOverlayDismissed() {
        dwellTimerTask?.cancel()
        dwellTimerTask = nil
        if sensor.displayAngle < closeThreshold && sensor.displayAngle >= minUsableAngle {
            isArmed = false
            if lastSettledAngle == nil {
                lastSettledAngle = sensor.displayAngle
            }
            statusDescription = String(format: "Screen ready (%.1f°) — Adjust lid to reactivate", sensor.displayAngle)
        } else if sensor.displayAngle >= closeThreshold {
            isArmed = true
            lastSettledAngle = nil
            statusDescription = "Armed — Close lid (<90°) to activate"
        } else {
            isArmed = false
            lastSettledAngle = nil
            statusDescription = "Exited — Open lid past 90° to re-arm"
        }
    }

    private func handleAutoModeToggled() {
        dwellTimerTask?.cancel()
        dwellTimerTask = nil
        if !isAutoModeEnabled {
            statusDescription = "Automatic mode disabled"
        } else {
            if sensor.displayAngle >= closeThreshold {
                isArmed = true
                statusDescription = "Armed — Close lid (<90°) to activate"
            } else {
                isArmed = false
                lastSettledAngle = sensor.displayAngle >= minUsableAngle ? sensor.displayAngle : nil
                statusDescription = "Open lid past 90° to arm automatic mode"
            }
        }
    }
}
