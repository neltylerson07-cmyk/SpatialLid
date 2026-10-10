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
            Toggle("Perspective Clock (Auto-Settle Off)", isOn: $autoManager.isClockModeEnabled)
                .disabled(autoManager.isAutoSettleEnabled)

            if autoManager.isClockModeEnabled {
                Menu("Clock Position") {
                    Section("Top") {
                        ForEach([ClockPosition.topLeading, .top, .topTrailing]) { pos in
                            Button {
                                overlayController.viewState.clockPosition = pos
                            } label: {
                                if overlayController.viewState.clockPosition == pos {
                                    Label(pos.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(pos.rawValue)
                                }
                            }
                        }
                    }
                    Section("Center") {
                        ForEach([ClockPosition.leading, .center, .trailing]) { pos in
                            Button {
                                overlayController.viewState.clockPosition = pos
                            } label: {
                                if overlayController.viewState.clockPosition == pos {
                                    Label(pos.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(pos.rawValue)
                                }
                            }
                        }
                    }
                    Section("Bottom") {
                        ForEach([ClockPosition.bottomLeading, .bottom, .bottomTrailing]) { pos in
                            Button {
                                overlayController.viewState.clockPosition = pos
                            } label: {
                                if overlayController.viewState.clockPosition == pos {
                                    Label(pos.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(pos.rawValue)
                                }
                            }
                        }
                    }
                }
                .disabled(autoManager.isAutoSettleEnabled)

                Menu("Clock Size") {
                    ForEach(ClockSize.allCases) { size in
                        Button {
                            overlayController.viewState.clockSize = size
                        } label: {
                            if overlayController.viewState.clockSize == size {
                                Label(size.rawValue, systemImage: "checkmark")
                            } else {
                                Text(size.rawValue)
                            }
                        }
                    }
                }
                .disabled(autoManager.isAutoSettleEnabled)

                Toggle("StandBy Calendar & Clock Style", isOn: overlayController.standByStyleBinding)
                    .disabled(autoManager.isAutoSettleEnabled)
            }

            Toggle("External Monitor Ambient Effect", isOn: $autoManager.isExternalDisplayEnabled)
            Toggle("Frosted Glass Effect", isOn: overlayController.frostedGlassBinding)
            Toggle("Simulated Keyboard Reflection", isOn: overlayController.keyboardReflectionBinding)

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
            VStack(spacing: 12) {
                Toggle(isOn: $autoManager.isAutoModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Automatic Perspective")
                            .font(.body.weight(.medium))
                        Text("Automatically takes a screenshot and engages perspective view when the lid passes below 90°.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Return to Usable Desktop")
                                .font(.body.weight(.medium))
                            Text(autoManager.isAutoSettleEnabled && autoManager.autoSettleDelay > 0
                                ? "When the lid is paused below 90° for >\(autoManager.formattedDelay), smoothly unwarps and fades out back to the interactive desktop."
                                : "Auto-return disabled. Perspective view remains active until lid is opened past 90° or ESC is pressed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(autoManager.isAutoSettleEnabled && autoManager.autoSettleDelay > 0
                            ? String(format: "%.1f s", autoManager.autoSettleDelay)
                            : "Off")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(autoManager.isAutoSettleEnabled && autoManager.autoSettleDelay > 0 ? .primary : .secondary)
                    }

                    Slider(
                        value: Binding(
                            get: {
                                autoManager.isAutoSettleEnabled ? autoManager.autoSettleDelay : 0.0
                            },
                            set: { newValue in
                                let currentVal = autoManager.isAutoSettleEnabled ? autoManager.autoSettleDelay : 0.0
                                let stepVal = (newValue * 2.0).rounded() / 2.0
                                if abs(currentVal - stepVal) > 0.05 {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                }
                                if stepVal <= 0 {
                                    autoManager.autoSettleDelay = 0
                                    autoManager.isAutoSettleEnabled = false
                                } else {
                                    autoManager.autoSettleDelay = min(3.0, stepVal)
                                    autoManager.isAutoSettleEnabled = true
                                }
                            }
                        ),
                        in: 0...3,
                        step: 0.5,
                        label: {
                            Text("Auto-Return Delay")
                        },
                        minimumValueLabel: {
                            Text("Off (0s)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        },
                        maximumValueLabel: {
                            Text("3s")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        },
                        tick: { val in
                            SliderTick(val) {
                                if val == 0 {
                                    Text("Off")
                                } else if val == 1.0 {
                                    Text("1s")
                                } else if val == 2.0 {
                                    Text("2s")
                                } else if val == 3.0 {
                                    Text("3s")
                                }
                            }
                        }
                    )
                    .sensoryFeedback(.levelChange, trigger: autoManager.autoSettleDelay)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                // Perspective Clock Mode (Engaged when Auto-Return is Off)
                Toggle(isOn: $autoManager.isClockModeEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Perspective Clock Mode")
                                .font(.body.weight(.medium))
                            if autoManager.isAutoSettleEnabled {
                                Text("(Active when Auto-Return is Off)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text("When Auto-Return is off, dims the desktop and projects a 3D perspective digital clock after 3 seconds of the lid remaining stationary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(autoManager.isAutoSettleEnabled)

                if autoManager.isClockModeEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Position")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: overlayController.clockPositionBinding) {
                                Section("Top") {
                                    Text("Top Left").tag(ClockPosition.topLeading)
                                    Text("Top").tag(ClockPosition.top)
                                    Text("Top Right").tag(ClockPosition.topTrailing)
                                }
                                Section("Center") {
                                    Text("Center Left").tag(ClockPosition.leading)
                                    Text("Center").tag(ClockPosition.center)
                                    Text("Center Right").tag(ClockPosition.trailing)
                                }
                                Section("Bottom") {
                                    Text("Bottom Left").tag(ClockPosition.bottomLeading)
                                    Text("Bottom").tag(ClockPosition.bottom)
                                    Text("Bottom Right").tag(ClockPosition.bottomTrailing)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 150)
                        }

                        HStack {
                            Text("Size")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: overlayController.clockSizeBinding) {
                                ForEach(ClockSize.allCases) { size in
                                    Text(size.rawValue).tag(size)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 230)
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("StandBy Calendar & Clock Style")
                                    .font(.subheadline.weight(.medium))
                                Text("Replaces the single digital clock with the Apple StandBy dual layout: day/month and monthly calendar on the left, and a squircle analog clock on the right.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: overlayController.standByStyleBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.vertical, 4)
                    .disabled(autoManager.isAutoSettleEnabled)
                }

                Divider()

                Toggle(isOn: overlayController.frostedGlassBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Frosted Glass Effect")
                            .font(.body.weight(.medium))
                        Text("Simulates an acid-etched frosted glass pane with a visible tactile grain pattern, micro-facet refraction, and Fresnel sheen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                Toggle(isOn: overlayController.keyboardReflectionBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Simulated Keyboard Reflection")
                            .font(.body.weight(.medium))
                        Text("Simulates specular laptop keyboard reflection on the screen glass between 45° and 90°.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                Toggle(isOn: $autoManager.isExternalDisplayEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("External Display Ambient Animation")
                            .font(.body.weight(.medium))
                        Text("Simultaneously zooms out, progressively blurs, and darkens connected external displays (no perspective distortion). Always auto-settles so your main/external workspace remains usable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toggleStyle(.switch)
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
                Label("When lid is tilted, press 'C' for Calibrator, 'T' for Clock, 'F' for Frosted, or 'K' for Keyboard", systemImage: "slider.horizontal.2.square.badge.arrow.down")
                Label("Use [↑/↓] and [←/→] to navigate and tune perspective parameters", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                if autoManager.isAutoSettleEnabled && autoManager.autoSettleDelay > 0 {
                    Label("Stopping movement (<90°) unwarps and returns to desktop after \(autoManager.formattedDelay)", systemImage: "arrow.triangle.2.circlepath")
                } else if autoManager.isClockModeEnabled {
                    Label("Stopping movement (<90°) dims desktop and shows perspective clock after 3s", systemImage: "clock")
                } else {
                    Label("Stopping movement (<90°) keeps perspective active (auto-return off)", systemImage: "arrow.triangle.2.circlepath")
                }
                Label("External displays always auto-settle to keep your workspace usable", systemImage: "display.2")
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
        .onKeyPress(KeyEquivalent("f")) {
            if handleKeyPress("f") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("F")) {
            if handleKeyPress("f") { return .handled }
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
        .onKeyPress(KeyEquivalent("t")) {
            if handleKeyPress("t") { return .handled }
            return .ignored
        }
        .onKeyPress(KeyEquivalent("T")) {
            if handleKeyPress("t") { return .handled }
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
            } else if char == "t" {
                if overlayController.isShowing {
                    if overlayController.viewState.isClockActive {
                        overlayController.deactivateClockMode()
                    } else {
                        overlayController.viewState.currentLidAngle = sensor.displayAngle
                        overlayController.activateClockMode()
                    }
                    return nil
                }
            } else if char == "f" {
                overlayController.viewState.isFrostedGlassEnabled.toggle()
                if overlayController.viewState.showCalibrator {
                    overlayController.viewState.requestRender()
                }
                return nil
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
        } else if key.lowercased() == "t" {
            if overlayController.isShowing {
                if overlayController.viewState.isClockActive {
                    overlayController.deactivateClockMode()
                } else {
                    overlayController.viewState.currentLidAngle = sensor.displayAngle
                    overlayController.activateClockMode()
                }
                return true
            }
        } else if key.lowercased() == "f" {
            overlayController.viewState.isFrostedGlassEnabled.toggle()
            if overlayController.viewState.showCalibrator {
                overlayController.viewState.requestRender()
            }
            return true
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

