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
        WindowGroup {
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

struct ContentView: View {
    @ObservedObject var sensor: LidSensor
    @ObservedObject var captureManager: ScreenCaptureManager
    @ObservedObject var bootstrap: AppBootstrap
    @ObservedObject var overlayController: FullscreenOverlayController
    @ObservedObject var autoManager: AutoPerspectiveManager

    @State private var isRunningDiagnostics = false
    @State private var diagnosticMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)

                Text("Lid Perspective")
                    .font(.title2)
                    .bold()

                Text("Real-time perspective warping driven by MacBook lid angle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            // Sensor readout card
            VStack(spacing: 8) {
                HStack {
                    Label("Lid Angle", systemImage: "angle")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.1f°", sensor.displayAngle))
                        .font(.system(.title3, design: .monospaced))
                        .bold()
                        .foregroundStyle(.tint)
                }

                ProgressView(value: min(max(sensor.displayAngle, 0), 180), total: 180)
                    .tint(.blue)

                HStack {
                    Text("Closed (0°)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("90°")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Flat (180°)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5))
            .cornerRadius(10)

            // Automatic Detection card
            VStack(spacing: 10) {
                HStack {
                    Label("Automatic Perspective", systemImage: "bolt.badge.automatic.fill")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: $autoManager.isAutoModeEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 8, height: 8)

                    Text(autoManager.statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if autoManager.isArmed && autoManager.isAutoModeEnabled {
                        Text("< 90° trigger")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .cornerRadius(4)
                    }
                }
            }
            .padding()
            .background(.quaternary.opacity(0.4))
            .cornerRadius(10)

            // Manual trigger action button
            Button {
                autoManager.triggerPerspective()
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
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(autoManager.isCapturing || overlayController.isShowing)

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
                Label("Closing lid (<90°) automatically captures screen and warps", systemImage: "sparkles")
                Label("Open lid past 90° or press ESC to exit", systemImage: "info.circle")
                Label("Toggle 'Tune Parameters' (H) in overlay to adjust keystone", systemImage: "slider.horizontal.3")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 400)
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
