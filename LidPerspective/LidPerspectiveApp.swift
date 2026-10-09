import SwiftUI

@main
struct LidPerspectiveApp: App {
    @StateObject private var sensor = LidSensor()
    @StateObject private var captureManager = ScreenCaptureManager()
    @StateObject private var bootstrap = AppBootstrap()
    private let overlayController = FullscreenOverlayController()

    var body: some Scene {
        WindowGroup {
            ContentView(
                sensor: sensor,
                captureManager: captureManager,
                bootstrap: bootstrap,
                overlayController: overlayController
            )
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @ObservedObject var sensor: LidSensor
    @ObservedObject var captureManager: ScreenCaptureManager
    @ObservedObject var bootstrap: AppBootstrap
    let overlayController: FullscreenOverlayController

    @State private var isCapturing = false
    @State private var isRunningDiagnostics = false
    @State private var diagnosticMessage: String?

    var body: some View {
        VStack(spacing: 20) {
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
                    Text("Flat (180°)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.quaternary.opacity(0.5))
            .cornerRadius(10)

            // Primary action button
            Button {
                launchPerspectiveOverlay()
            } label: {
                HStack {
                    if isCapturing {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                        Text("Capturing Screen...")
                    } else {
                        Image(systemName: "play.fill")
                        Text("Enter Perspective Mode")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCapturing)

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
                Label("Press ESC while in overlay to exit", systemImage: "info.circle")
                Label("Toggle 'Tune Parameters' (H) to adjust keystone and stretch", systemImage: "slider.horizontal.3")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 380)
    }

    private func launchPerspectiveOverlay() {
        isCapturing = true
        Task {
            await captureManager.captureCurrentScreen()
            if let snapshot = captureManager.latestSnapshot {
                overlayController.show(snapshot: snapshot, sensor: sensor)
            }
            isCapturing = false
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
