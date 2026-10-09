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
    @Published var isArmed: Bool = false
    @Published var isCapturing: Bool = false
    @Published var statusDescription: String = "Initializing..."

    let sensor: LidSensor
    let captureManager: ScreenCaptureManager
    let overlayController: FullscreenOverlayController

    let closeThreshold: Double = 90.0
    let rearmThreshold: Double = 92.0 // Hysteresis to prevent jitter near 90°

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
            self.statusDescription = "Open lid past 90° to arm automatic mode"
        }

        sensor.onAngleChanged = { [weak self] angle in
            self?.handleAngleUpdate(angle)
        }
    }

    func handleAngleUpdate(_ angle: Double) {
        guard isAutoModeEnabled else {
            statusDescription = "Automatic mode disabled"
            return
        }

        // If overlay is currently displayed
        if overlayController.isShowing {
            if angle >= rearmThreshold {
                // Lid opened past 90° -> automatically dismiss overlay and re-arm
                overlayController.dismiss()
                isArmed = true
                statusDescription = "Armed — Close lid (<90°) to activate"
            } else {
                statusDescription = String(format: "Perspective active (%.1f°)", angle)
            }
            return
        }

        // Avoid capturing if a capture is already in progress
        guard !isCapturing else { return }

        // If overlay is not showing
        if angle >= rearmThreshold {
            if !isArmed {
                isArmed = true
            }
            statusDescription = "Armed — Close lid (<90°) to activate"
        } else if angle < closeThreshold {
            if isArmed {
                isArmed = false
                triggerPerspective()
            }
        }
    }

    func triggerPerspective() {
        guard !isCapturing && !overlayController.isShowing else { return }
        isCapturing = true
        statusDescription = "Lid closing detected (<90°) — Capturing screen..."

        Task { [weak self] in
            guard let self = self else { return }
            if let snapshot = await self.captureManager.captureCurrentScreen() {
                self.overlayController.show(snapshot: snapshot, sensor: self.sensor) { [weak self] in
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
        if sensor.displayAngle < closeThreshold {
            isArmed = false
            statusDescription = "Exited — Open lid past 90° to re-arm"
        } else {
            isArmed = true
            statusDescription = "Armed — Close lid (<90°) to activate"
        }
    }

    private func handleAutoModeToggled() {
        if !isAutoModeEnabled {
            statusDescription = "Automatic mode disabled"
        } else {
            if sensor.displayAngle >= closeThreshold {
                isArmed = true
                statusDescription = "Armed — Close lid (<90°) to activate"
            } else {
                isArmed = false
                statusDescription = "Open lid past 90° to arm automatic mode"
            }
        }
    }
}
