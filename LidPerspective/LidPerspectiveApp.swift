import SwiftUI

@main
struct LidPerspectiveApp: App {
    @StateObject private var sensor: LidSensor
    @StateObject private var captureManager: ScreenCaptureManager
    @StateObject private var bootstrap: AppBootstrap
    @StateObject private var overlayController: FullscreenOverlayController
    @StateObject private var autoManager: AutoPerspectiveManager

    init() {
        let sensorInstance = LidSensor()
        let captureInstance = ScreenCaptureManager()
        let overlayInstance = FullscreenOverlayController()
        let bootstrapInstance = AppBootstrap()
        let autoInstance = AutoPerspectiveManager(
            sensor: sensorInstance,
            captureManager: captureInstance,
            overlayController: overlayInstance
        )

        _sensor = StateObject(wrappedValue: sensorInstance)
        _captureManager = StateObject(wrappedValue: captureInstance)
        _overlayController = StateObject(wrappedValue: overlayInstance)
        _bootstrap = StateObject(wrappedValue: bootstrapInstance)
        _autoManager = StateObject(wrappedValue: autoInstance)
    }

    var body: some Scene {
        // Background Menu Bar Extra (Persistent agent in macOS menu bar)
        MenuBarExtra("LidPerspective", systemImage: "laptopcomputer.and.arrow.down") {
            MenuBarMenuView(
                sensor: sensor,
                autoManager: autoManager,
                overlayController: overlayController,
                bootstrap: bootstrap
            )
        }

        // Auxiliary Settings Window (Openable from Menu Bar or on launch)
        WindowGroup("LidPerspective Settings", id: "settings") {
            ContentView(
                sensor: sensor,
                captureManager: captureManager,
                bootstrap: bootstrap,
                overlayController: overlayController,
                autoManager: autoManager
            )
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Menu Bar View (Agent Interface)
struct MenuBarMenuView: View {
    @ObservedObject var sensor: LidSensor
    @ObservedObject var autoManager: AutoPerspectiveManager
    @ObservedObject var overlayController: FullscreenOverlayController
    @ObservedObject var bootstrap: AppBootstrap
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LidPerspective Agent")
                .font(.headline)

            Text(String(format: "Hinge Angle: %.1f° (%.1f°/s)", sensor.displayAngle, sensor.currentVelocity))
                .font(.caption)

            Text("Status: \(autoManager.statusDescription)")
                .font(.caption2)

            Divider()

            Button {
                autoManager.triggerPerspective(pinSettings: true)
            } label: {
                Label("Open 45° Calibrator & Warped Menu", systemImage: "slider.horizontal.2.square.badge.arrow.down")
            }
            .disabled(autoManager.isCapturing || overlayController.isShowing)

            Button {
                autoManager.triggerPerspective(pinSettings: false)
            } label: {
                Label("Enter Perspective Mode (Manual)", systemImage: "play.fill")
            }
            .disabled(autoManager.isCapturing || overlayController.isShowing)

            Divider()

            Toggle("Automatic Perspective (<90°)", isOn: $autoManager.isAutoModeEnabled)
            Toggle("Auto-Settle Below 90°", isOn: $autoManager.isAutoSettleEnabled)

            Divider()

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            } label: {
                Label("Open Settings & Diagnostics Window...", systemImage: "gearshape")
            }

            Divider()

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit LidPerspective", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

// MARK: - Main Settings & Diagnostics Window
struct ContentView: View {
    @ObservedObject var sensor: LidSensor
    @ObservedObject var captureManager: ScreenCaptureManager
    @ObservedObject var bootstrap: AppBootstrap
    @ObservedObject var overlayController: FullscreenOverlayController
    @ObservedObject var autoManager: AutoPerspectiveManager

    @State private var isRunningDiagnostics: Bool = false
    @State private var diagnosticMessage: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            // Header with status indicator
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("LidPerspective")
                        .font(.title2.bold())
                    Text("Background Agent & 45° Holographic Overlay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Armed status badge
                Circle()
                    .fill(statusIndicatorColor)
                    .frame(width: 12, height: 12)
            }

            Divider()

            // Sensor Readings Box
            VStack(spacing: 10) {
                HStack {
                    Text("Lid Hinge Angle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f°", sensor.displayAngle))
                        .font(.system(.title3, design: .monospaced).bold())
                }

                HStack {
                    Text("Angular Velocity")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.1f°/s", sensor.currentVelocity))
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Text("Sensor Status")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(sensor.isAvailable ? "Connected (IOHID)" : "Simulation Mode")
                        .font(.caption.bold())
                        .foregroundStyle(sensor.isAvailable ? .green : .orange)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.4))
            .cornerRadius(10)

            // Automation Settings
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable Automatic Perspective", isOn: $autoManager.isAutoModeEnabled)
                    .font(.body.weight(.medium))

                Text("Automatically takes a screenshot and engages perspective view when the lid passes below 90°.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto-Return to Usable Desktop", isOn: $autoManager.isAutoSettleEnabled)
                    .font(.body.weight(.medium))

                Text("When the lid is paused below 90° for >1 second, smoothly unwarps and fades out back to the interactive desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(.quaternary.opacity(0.4))
            .cornerRadius(10)

            // Automation Status
            HStack {
                Text("Automation Status:")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(autoManager.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 4)

            // Primary Actions: 45° Calibrator & Manual Mode
            VStack(spacing: 10) {
                Button {
                    autoManager.triggerPerspective(pinSettings: true)
                } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.2.square.badge.arrow.down")
                        Text("Launch 45° Holographic Calibrator")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(autoManager.isCapturing || overlayController.isShowing)

                Button {
                    autoManager.triggerPerspective(pinSettings: false)
                } label: {
                    HStack {
                        if autoManager.isCapturing {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text("Capturing Screen...")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Enter Perspective Mode (Manual)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(autoManager.isCapturing || overlayController.isShowing)
            }

            // Secondary actions
            HStack(spacing: 12) {
                Button {
                    runDiagnostics()
                } label: {
                    HStack {
                        if isRunningDiagnostics {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "stethoscope")
                        }
                        Text("Run Diagnostics")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isRunningDiagnostics)

                if let message = diagnosticMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Instructions footer
            VStack(alignment: .leading, spacing: 4) {
                Label("Closing lid (<90°) captures screen and warps in real time", systemImage: "sparkles")
                Label("Tilt screen to 45° to reveal the holographic warped settings menu", systemImage: "slider.horizontal.2.square.badge.arrow.down")
                Label("Stopping movement (<90°) unwarps and returns to usable desktop after 1s", systemImage: "arrow.triangle.2.circlepath")
                Label("Open lid past 90° or press ESC to exit", systemImage: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 440)
    }

    private var statusIndicatorColor: Color {
        if !autoManager.isAutoModeEnabled {
            return .gray
        } else if overlayController.isShowing {
            return .blue
        } else if autoManager.isCapturing {
            return .orange
        } else if autoManager.isArmed {
            return .green
        } else {
            return .yellow
        }
    }

    private func runDiagnostics() {
        isRunningDiagnostics = true
        diagnosticMessage = nil
        Task {
            await bootstrap.runDiagnostics()
            diagnosticMessage = "Diagnostics logged to console"
            isRunningDiagnostics = false
        }
    }
}
