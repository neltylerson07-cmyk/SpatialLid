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

            Toggle("Automatic Perspective (<90°)", isOn: $autoManager.isAutoModeEnabled)
            Toggle("Auto-Settle Below 90°", isOn: $autoManager.isAutoSettleEnabled)
            Toggle("Simulated Keyboard Reflection", isOn: overlayController.keyboardReflectionBinding)

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
    @State private var keyMonitor: Any? = nil

    var body: some View {
        VStack(spacing: 20) {
            // Header with status indicator
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("GlassBook")
                        .font(.title2.bold())
                    Text("Simulates a glass door effect when the lid is tilted below 90 degrees")
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
                        .font(.title3.weight(.bold).monospacedDigit())
                }

                HStack {
                    Text("Angular Velocity")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.1f°/s", sensor.currentVelocity))
                        .font(.body.monospacedDigit())
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

                Toggle("Simulated Keyboard Reflection", isOn: overlayController.keyboardReflectionBinding)
                    .font(.body.weight(.medium))

                Text("Simulates specular laptop keyboard reflection on the screen glass between 45° and 90°.")
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
                Label("When lid is tilted, press 'C' for Calibrator or 'K' to toggle Keyboard", systemImage: "slider.horizontal.2.square.badge.arrow.down")
                Label("Use [↑/↓] and [←/→] to navigate and tune perspective parameters", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                Label("Stopping movement (<90°) unwarps and returns to desktop after 1s", systemImage: "arrow.triangle.2.circlepath")
                Label("Open lid past 90° or press ESC to exit", systemImage: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 440)
        .background(WindowAccessor { window in
            window.title = "LidPerspective Settings"
            window.identifier = NSUserInterfaceItemIdentifier("settings")
            overlayController.viewState.settingsWindow = window
            overlayController.viewState.isSettingsWindowOpen = true
            overlayController.viewState.isSettingsWindowFocused = true
        })
        .onAppear {
            overlayController.viewState.isSettingsWindowOpen = true
            setupKeyMonitor()
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow,
               window == overlayController.viewState.settingsWindow || window.title.contains("Settings") || window.identifier?.rawValue == "settings" {
                overlayController.viewState.isSettingsWindowFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow,
               window == overlayController.viewState.settingsWindow || window.title.contains("Settings") || window.identifier?.rawValue == "settings" {
                overlayController.viewState.isSettingsWindowFocused = false
            }
        }
        .onKeyPress(KeyEquivalent("c")) {
            if handleKeyPress("c") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("C")) {
            if handleKeyPress("c") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("k")) {
            if handleKeyPress("k") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("K")) {
            if handleKeyPress("k") { return .handled }
            return .ignored
        }
    }

    private func setupKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "c" {
                if sensor.displayAngle < 90.0 {
                    if overlayController.isShowing {
                        overlayController.viewState.showCalibrator.toggle()
                        if overlayController.viewState.showCalibrator {
                            overlayController.viewState.requestRender()
                        }
                    } else {
                        autoManager.triggerPerspective(showCalibrator: true)
                    }
                    return nil
                }
            } else if char == "k" {
                overlayController.viewState.isKeyboardReflectionEnabled.toggle()
                if overlayController.viewState.showCalibrator {
                    overlayController.viewState.requestRender()
                }
                return nil
            }
            return event
        }
    }

    private func handleKeyPress(_ key: String) -> Bool {
        if key.lowercased() == "c" {
            if sensor.displayAngle < 90.0 {
                if overlayController.isShowing {
                    overlayController.viewState.showCalibrator.toggle()
                    if overlayController.viewState.showCalibrator {
                        overlayController.viewState.requestRender()
                    }
                } else {
                    autoManager.triggerPerspective(showCalibrator: true)
                }
                return true
            }
        } else if key.lowercased() == "k" {
            overlayController.viewState.isKeyboardReflectionEnabled.toggle()
            if overlayController.viewState.showCalibrator {
                overlayController.viewState.requestRender()
            }
            return true
        }
        return false
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

// MARK: - Window Accessor Helper
private struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                callback(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                callback(window)
            }
        }
    }
}

