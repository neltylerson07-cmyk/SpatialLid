import Cocoa
import SwiftUI
import Combine

@MainActor
final class FullscreenOverlayController: ObservableObject {
    private var window: KeyCatchingWindow?
    @Published private(set) var isShowing: Bool = false
    private var onDismissal: (() -> Void)?
    @Published var viewState = OverlayViewState()

    var keyboardReflectionBinding: Binding<Bool> {
        Binding(
            get: { self.viewState.isKeyboardReflectionEnabled },
            set: { [weak self] newValue in
                guard let self = self else { return }
                self.viewState.isKeyboardReflectionEnabled = newValue
                if self.viewState.showCalibrator {
                    self.viewState.requestRender()
                }
            }
        )
    }

    var isSettling: Bool {
        viewState.isSettling
    }

    func show(snapshot: CGImage, sensor: LidSensor, showCalibrator: Bool = false, onDismiss: (() -> Void)? = nil) {
        if window != nil {
            dismiss()
        }

        self.onDismissal = onDismiss
        guard let screen = NSScreen.main else { return }

        // Reset settle state when showing fresh overlay
        viewState.isSettling = false
        viewState.onSettleCompleted = nil
        viewState.showCalibrator = showCalibrator
        viewState.screenSize = screen.frame.size
        viewState.requestRender()

        // Must use screen.frame (covers physical display including Dock & Menu Bar)
        let overlayWindow = KeyCatchingWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        overlayWindow.setFrame(screen.frame, display: true)

        // Start fully transparent to eliminate any black flash while Metal textures compile
        overlayWindow.alphaValue = 0.0
        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false

        overlayWindow.onEscape = { [weak self] in
            self?.dismiss()
        }

        overlayWindow.onToggleHUD = { [weak self] in
            self?.viewState.showHUD.toggle()
        }

        overlayWindow.onToggleCalibrator = { [weak self] in
            guard let self = self else { return }
            guard self.viewState.isSettingsWindowAvailable else { return }
            if !self.viewState.showCalibrator && sensor.displayAngle >= 90.0 {
                return
            }
            self.viewState.showCalibrator.toggle()
            if self.viewState.showCalibrator {
                self.viewState.requestRender()
            }
        }

        overlayWindow.onArrowUp = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.previousSetting()
        }

        overlayWindow.onArrowDown = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.nextSetting()
        }

        overlayWindow.onArrowLeft = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.adjustSelectedSetting(by: -1)
        }

        overlayWindow.onArrowRight = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.adjustSelectedSetting(by: 1)
        }

        overlayWindow.onReset = { [weak self] in
            guard let self = self, self.viewState.showCalibrator else { return }
            self.viewState.resetToDefaults()
        }

        overlayWindow.onToggleKeyboard = { [weak self] in
            guard let self = self else { return }
            self.viewState.isKeyboardReflectionEnabled.toggle()
            if self.viewState.showCalibrator {
                self.viewState.requestRender()
            }
        }

        // Set to ScreenSaver level: sits higher than Dock, Menu Bar, and popups
        overlayWindow.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))

        // Collection behaviors
        overlayWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let hostView = NSHostingView(
            rootView: FullscreenPerspectiveContainer(
                snapshot: snapshot,
                sensor: sensor,
                state: viewState,
                onFirstFrame: { [weak overlayWindow] in
                    guard let window = overlayWindow else { return }
                    // Buttery smooth crossfade as soon as the first frame is rendered
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.12
                        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        window.animator().alphaValue = 1.0
                    } completionHandler: { [weak overlayWindow] in
                        overlayWindow?.backgroundColor = .black
                        overlayWindow?.isOpaque = true
                    }
                },
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )

        overlayWindow.contentView = hostView
        overlayWindow.makeKeyAndOrderFront(nil)
        self.window = overlayWindow
        self.isShowing = true
    }

    /// Triggers the quick tween back to normal fullscreen, then fades out to reveal the desktop.
    func unwarpAndDismiss(completion: (() -> Void)? = nil) {
        guard isShowing, !viewState.isSettling else { return }
        viewState.isSettling = true
        viewState.onSettleCompleted = { [weak self] in
            self?.fadeAndDismiss(completion: completion)
        }
    }

    /// Cancels settling in progress if user resumes moving the lid.
    func cancelSettling() {
        if viewState.isSettling {
            viewState.isSettling = false
            viewState.onSettleCompleted = nil
        }
    }

    /// Smoothly fades out the overlay window to reveal the live desktop underneath.
    func fadeAndDismiss(completion: (() -> Void)? = nil) {
        guard let activeWindow = window else { return }
        window = nil
        isShowing = false
        activeWindow.isOpaque = false
        activeWindow.backgroundColor = .clear

        let handler = self.onDismissal
        self.onDismissal = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            activeWindow.animator().alphaValue = 0.0
        }, completionHandler: {
            activeWindow.orderOut(nil)
            DispatchQueue.main.async {
                handler?()
                completion?()
            }
        })
    }

    /// Immediate dismissal (e.g. lid opened past 90° or ESC pressed)
    func dismiss(completion: (() -> Void)? = nil) {
        cancelSettling()
        guard let activeWindow = window else { return }
        window = nil
        isShowing = false
        activeWindow.isOpaque = false
        activeWindow.backgroundColor = .clear

        let handler = self.onDismissal
        self.onDismissal = nil

        // Smooth dissolve back to live desktop
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            activeWindow.animator().alphaValue = 0.0
        }, completionHandler: {
            activeWindow.orderOut(nil)
            DispatchQueue.main.async {
                handler?()
                completion?()
            }
        })
    }
}

// MARK: - Tunable Parameters
enum TunableSetting: Int, CaseIterable, Identifiable {
    case keystone = 0
    case stretch = 1
    case lookahead = 2
    case keyboardReflection = 3
    case keyboardTilt = 4
    case keyboardReach = 5
    case keyboardBacklight = 6
    case keyboardOffset = 7
    case keyboardWidth = 8
    case keyboardDepthBlur = 9

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .keystone: return "Keystone Taper"
        case .stretch: return "Stretch Balance"
        case .lookahead: return "Lookahead Delay"
        case .keyboardReflection: return "Keyboard Reflection"
        case .keyboardTilt: return "Reflection Tilt"
        case .keyboardReach: return "Reflection Reach"
        case .keyboardBacklight: return "Key Backlight Glow"
        case .keyboardOffset: return "Bottom Offset"
        case .keyboardWidth: return "Keyboard Width"
        case .keyboardDepthBlur: return "Optical Depth Blur"
        }
    }
}

@MainActor
final class OverlayViewState: ObservableObject {
    @Published var showHUD: Bool = false
    @Published var showCalibrator: Bool = false
    // Window Focus / State tracking for Calibrator activation guard
    @Published var isSettingsWindowOpen: Bool = false
    @Published var isSettingsWindowFocused: Bool = false
    weak var settingsWindow: NSWindow? = nil {
        didSet {
            guard let window = settingsWindow else { return }
            isSettingsWindowOpen = true
            isSettingsWindowFocused = true
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.isSettingsWindowOpen = false
                    self?.isSettingsWindowFocused = false
                    self?.settingsWindow = nil
                }
            }
        }
    }
    @Published var keystoneStrength: Float = 0.18
    @Published var stretchBalance: Float = 0.56
    @Published var lookaheadTime: Double = 0.22
    @Published var isKeyboardReflectionEnabled: Bool = true
    @Published var keyboardReflection: Float = 0.44
    @Published var keyboardTilt: Float = 0.40
    @Published var keyboardReach: Float = 0.38
    @Published var keyboardBacklight: Float = 1.50
    @Published var keyboardOffset: Float = -0.01
    @Published var keyboardWidth: Float = 0.88
    @Published var keyboardDepthBlur: Float = 0.30

    // Calibrator State
    @Published var selectedSettingIndex: Int = 0
    @Published var menuImage: CGImage? = nil
    var screenSize: CGSize = CGSize(width: 1920, height: 1080)

    var isSettingsWindowAvailable: Bool {
        if isSettingsWindowOpen || isSettingsWindowFocused {
            return true
        }
        if let window = settingsWindow {
            return window.isVisible || window.windowNumber > 0
        }
        return NSApp.windows.contains { window in
            let title = window.title
            let id = window.identifier?.rawValue ?? ""
            return (title.contains("Settings") || id.contains("settings")) && (window.isVisible || window.windowNumber > 0)
        }
    }

    // Settle animation state
    @Published var isSettling: Bool = false
    var onSettleCompleted: (() -> Void)?

    func nextSetting() {
        let count = TunableSetting.allCases.count
        selectedSettingIndex = (selectedSettingIndex + 1) % count
        requestRender()
    }

    func previousSetting() {
        let count = TunableSetting.allCases.count
        selectedSettingIndex = (selectedSettingIndex - 1 + count) % count
        requestRender()
    }

    func adjustSelectedSetting(by direction: Int) {
        guard let setting = TunableSetting(rawValue: selectedSettingIndex) else { return }
        let step = Float(direction)
        switch setting {
        case .keystone:
            keystoneStrength = min(max(keystoneStrength + step * 0.01, 0.0), 1.0)
        case .stretch:
            stretchBalance = min(max(stretchBalance + step * 0.01, 0.01), 1.5)
        case .lookahead:
            lookaheadTime = min(max(lookaheadTime + Double(direction) * 0.02, 0.0), 0.5)
        case .keyboardReflection:
            if direction > 0 && !isKeyboardReflectionEnabled {
                isKeyboardReflectionEnabled = true
            } else if direction < 0 && keyboardReflection <= 0.04 {
                isKeyboardReflectionEnabled = false
            } else {
                keyboardReflection = min(max(keyboardReflection + step * 0.02, 0.0), 1.0)
            }
        case .keyboardTilt:
            keyboardTilt = min(max(keyboardTilt + step * 0.05, 0.15), 2.0)
        case .keyboardReach:
            keyboardReach = min(max(keyboardReach + step * 0.02, 0.12), 0.65)
        case .keyboardBacklight:
            keyboardBacklight = min(max(keyboardBacklight + step * 0.05, 0.0), 2.5)
        case .keyboardOffset:
            keyboardOffset = min(max(keyboardOffset + step * 0.01, -0.10), 0.20)
        case .keyboardWidth:
            keyboardWidth = min(max(keyboardWidth + step * 0.02, 0.60), 1.00)
        case .keyboardDepthBlur:
            keyboardDepthBlur = min(max(keyboardDepthBlur + step * 0.05, 0.0), 3.0)
        }
        requestRender()
    }

    func resetToDefaults() {
        keystoneStrength = 0.18
        stretchBalance = 0.56
        lookaheadTime = 0.22
        isKeyboardReflectionEnabled = true
        keyboardReflection = 0.44
        keyboardTilt = 0.40
        keyboardReach = 0.38
        keyboardBacklight = 1.50
        keyboardOffset = -0.01
        keyboardWidth = 0.88
        keyboardDepthBlur = 0.30
        requestRender()
    }

    private var appearanceSubscription: AnyCancellable?

    init() {
        if let app = NSApp {
            appearanceSubscription = app.publisher(for: \.effectiveAppearance)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.requestRender()
                }
        }
    }

    func requestRender() {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let view = WarpedSettingsCardContainer(state: self, isDarkMode: isDarkMode)
            .environment(\.colorScheme, isDarkMode ? .dark : .light)
            .frame(width: screenSize.width, height: screenSize.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        renderer.isOpaque = false
        renderer.proposedSize = ProposedViewSize(width: screenSize.width, height: screenSize.height)
        if let cgImage = renderer.cgImage {
            self.menuImage = cgImage
        }
    }
}

// MARK: - Key-Catching Window
private class KeyCatchingWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onToggleHUD: (() -> Void)?
    var onToggleCalibrator: (() -> Void)?
    var onToggleKeyboard: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onReset: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // ESC
            onEscape?()
        case 126: // Up Arrow
            onArrowUp?()
        case 125: // Down Arrow
            onArrowDown?()
        case 123: // Left Arrow
            onArrowLeft?()
        case 124: // Right Arrow
            onArrowRight?()
        case 8: // 'C' key
            onToggleCalibrator?()
        case 40: // 'K' key
            onToggleKeyboard?()
        case 15: // 'R' key
            onReset?()
        default:
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "c" {
                onToggleCalibrator?()
            } else if char == "k" {
                onToggleKeyboard?()
            } else if char == "h" {
                onToggleHUD?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

// MARK: - Fullscreen Perspective Container
private struct FullscreenPerspectiveContainer: View {
    let snapshot: CGImage
    @ObservedObject var sensor: LidSensor
    @ObservedObject var state: OverlayViewState
    var onFirstFrame: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Fullscreen Metal Canvas
            PerspectiveMetalView(
                snapshot: snapshot,
                calibratorImage: state.menuImage,
                showCalibrator: state.showCalibrator,
                sensor: sensor,
                fallbackAngle: sensor.currentAngle,
                lookahead: state.lookaheadTime,
                keystoneStrength: state.keystoneStrength,
                stretchBalance: state.stretchBalance,
                keyboardReflection: state.isKeyboardReflectionEnabled ? state.keyboardReflection : 0.0,
                keyboardTilt: state.keyboardTilt,
                keyboardReach: state.keyboardReach,
                keyboardBacklight: state.keyboardBacklight,
                keyboardOffset: state.keyboardOffset,
                keyboardWidth: state.keyboardWidth,
                keyboardDepthBlur: state.keyboardDepthBlur,
                isSettling: state.isSettling,
                onSettleCompleted: {
                    state.onSettleCompleted?()
                },
                onFirstFrame: onFirstFrame
            )
            .ignoresSafeArea()

            // Traditional Floating Tweaker Panel (Optional fallback via 'H' key)
            if state.showHUD {
                floatingHudPanel
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: state.showHUD)
        .onAppear {
            state.requestRender()
        }
    }

    private var floatingHudPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Perspective Tuner (Side HUD)")
                    .font(.headline)
                Spacer()
                Button("Close") { state.showHUD = false }
                    .font(.caption)
                    .buttonStyle(.borderless)
            }
            Divider()
            Text("Press [H] to toggle this panel, or press [C] when lid is tilted to show the perspective calibrator.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 280)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

// MARK: - Warped Settings Card (Rendered directly into Metal Texture)
private struct WarpedSettingsCardContainer: View {
    @ObservedObject var state: OverlayViewState
    var isDarkMode: Bool

    var body: some View {
        ZStack {
            // Transparent backdrop for entire screen canvas
            Color.clear

            // 8 Calibration Squares around the screen perimeter
            calibrationSquares

            // Centered Native Apple Settings Card
            VStack(spacing: 14) {
                // Header: macOS Settings / Inspector style
                HStack(spacing: 12) {
                    // App / Tool icon in Apple squircle
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.accentColor.opacity(isDarkMode ? 0.25 : 0.15))
                            .frame(width: 34, height: 34)

                        Image(systemName: "slider.horizontal.2.square")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Perspective Calibrator")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)

                        Text("Tune the shader based on your distance and preference")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.secondary)
                    }

                    Spacer()

                    // Native status pill
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)

                        Text("Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(isDarkMode ? 0.08 : 0.05))
                    )
                }
                .padding(.bottom, 2)

                Divider()

                // Parameter rows
                VStack(spacing: 3) {
                    ForEach(TunableSetting.allCases) { setting in
                        SettingRow(
                            setting: setting,
                            isSelected: state.selectedSettingIndex == setting.rawValue,
                            valueText: formattedValue(for: setting),
                            progress: progress(for: setting),
                            isDarkMode: isDarkMode
                        )
                    }
                }

                Divider()

                // Native Apple Keyboard Shortcut Keycaps Footer
                HStack(spacing: 12) {
                    KeycapHint(keys: ["↑", "↓"], label: "Select", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["←", "→"], label: "Adjust", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["K"], label: "Keyboard", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["R"], label: "Reset", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["C"], label: "Toggle", isDarkMode: isDarkMode)
                    Spacer()
                    KeycapHint(keys: ["ESC"], label: "Exit", isDarkMode: isDarkMode)
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
            .padding(18)
            .frame(width: 540)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isDarkMode ? Color(red: 0.13, green: 0.13, blue: 0.14).opacity(0.92) : Color(red: 0.97, green: 0.97, blue: 0.98).opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        isDarkMode ? Color.white.opacity(0.14) : Color.black.opacity(0.12),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(isDarkMode ? 0.40 : 0.16),
                radius: 20,
                x: 0,
                y: 8
            )
        }
    }

    private var calibrationSquares: some View {
        let padding: CGFloat = 28
        let squareSize: CGFloat = 46

        return ZStack {
            // Subtle alignment border guide connecting corners and edges
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    Color.accentColor.opacity(isDarkMode ? 0.20 : 0.15),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 6])
                )
                .padding(padding + squareSize / 2 - 6)

            // 1. Top-Leading (Corner)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "TL")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(padding)

            // 2. Top-Center (Edge)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "TC")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, padding)

            // 3. Top-Trailing (Corner)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "TR")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(padding)

            // 4. Center-Leading (Edge)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "CL")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, padding)

            // 5. Center-Trailing (Edge)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "CR")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, padding)

            // 6. Bottom-Leading (Corner)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "BL")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(padding)

            // 7. Bottom-Center (Edge)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "BC")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, padding)

            // 8. Bottom-Trailing (Corner)
            CalibrationSquare(isDarkMode: isDarkMode, size: squareSize, label: "BR")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(padding)
        }
    }

    private func formattedValue(for setting: TunableSetting) -> String {
        switch setting {
        case .keystone: return String(format: "%.2f", state.keystoneStrength)
        case .stretch: return String(format: "%.2f", state.stretchBalance)
        case .lookahead: return String(format: "%.2fs", state.lookaheadTime)
        case .keyboardReflection:
            return state.isKeyboardReflectionEnabled ? String(format: "%.2f", state.keyboardReflection) : "Off"
        case .keyboardTilt: return String(format: "%.2f", state.keyboardTilt)
        case .keyboardReach: return String(format: "%.2f", state.keyboardReach)
        case .keyboardBacklight: return String(format: "%.2f", state.keyboardBacklight)
        case .keyboardOffset: return String(format: "%+.2f", state.keyboardOffset)
        case .keyboardWidth: return String(format: "%.2f", state.keyboardWidth)
        case .keyboardDepthBlur: return String(format: "%.2f", state.keyboardDepthBlur)
        }
    }

    private func progress(for setting: TunableSetting) -> Double {
        switch setting {
        case .keystone: return Double(state.keystoneStrength / 1.0)
        case .stretch: return Double((state.stretchBalance - 0.01) / 1.49)
        case .lookahead: return Double(state.lookaheadTime / 0.5)
        case .keyboardReflection:
            return state.isKeyboardReflectionEnabled ? Double(state.keyboardReflection / 1.0) : 0.0
        case .keyboardTilt: return Double((state.keyboardTilt - 0.15) / 1.85)
        case .keyboardReach: return Double((state.keyboardReach - 0.12) / 0.53)
        case .keyboardBacklight: return Double(state.keyboardBacklight / 2.5)
        case .keyboardOffset: return Double((state.keyboardOffset + 0.10) / 0.30)
        case .keyboardWidth: return Double((state.keyboardWidth - 0.60) / 0.40)
        case .keyboardDepthBlur: return Double(state.keyboardDepthBlur / 3.0)
        }
    }
}

private struct SettingRow: View {
    let setting: TunableSetting
    let isSelected: Bool
    let valueText: String
    let progress: Double
    let isDarkMode: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Selection chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 10)

            // Parameter name
            Text(setting.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                .frame(width: 160, alignment: .leading)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(isDarkMode ? 0.12 : 0.08))
                        .frame(height: 5)

                    Capsule()
                        .fill(
                            isSelected ?
                            Color.accentColor :
                            Color.primary.opacity(isDarkMode ? 0.35 : 0.25)
                        )
                        .frame(width: max(0, min(geo.size.width * CGFloat(progress), geo.size.width)), height: 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)

            // Value readout (monospaced digits for alignment, Apple system font)
            Text(valueText)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(isDarkMode ? 0.20 : 0.12) : Color.clear)
        )
    }
}

// MARK: - Native Apple Keycap Hint
private struct KeycapHint: View {
    let keys: [String]
    let label: String
    let isDarkMode: Bool

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isDarkMode ? Color.white.opacity(0.12) : Color.black.opacity(0.08))
                        )
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(Color.secondary)
        }
    }
}
// MARK: - Calibration Square
private struct CalibrationSquare: View {
    let isDarkMode: Bool
    var size: CGFloat = 46
    var label: String? = nil

    var body: some View {
        ZStack {
            // Background plate
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDarkMode ? Color(red: 0.13, green: 0.13, blue: 0.14).opacity(0.88) : Color(red: 0.97, green: 0.97, blue: 0.98).opacity(0.92))

            // Outer border
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isDarkMode ? Color.white.opacity(0.25) : Color.black.opacity(0.20), lineWidth: 1)

            // Concentric inner calibration square
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(Color.accentColor.opacity(0.75), lineWidth: 1)
                .frame(width: size * 0.44, height: size * 0.44)

            // Precision crosshair lines
            Rectangle()
                .fill(Color.accentColor.opacity(0.60))
                .frame(width: size * 0.72, height: 1)

            Rectangle()
                .fill(Color.accentColor.opacity(0.60))
                .frame(width: 1, height: size * 0.72)

            // Center fiducial pin
            Circle()
                .fill(Color.accentColor)
                .frame(width: 4, height: 4)

            // Subtle label badge
            if let label = label {
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color.black.opacity(isDarkMode ? 0.35 : 0.12), radius: 8, x: 0, y: 3)
    }
}

