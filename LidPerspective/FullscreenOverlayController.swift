import Cocoa
import SwiftUI
import Combine

@MainActor
final class FullscreenOverlayController: ObservableObject {
    private var window: KeyCatchingWindow?
    @Published private(set) var isShowing: Bool = false
    private var onDismissal: (() -> Void)?
    let viewState = OverlayViewState()

    var isSettling: Bool {
        viewState.isSettling
    }

    func show(snapshot: CGImage, sensor: LidSensor, pinSettingsMenu: Bool = false, onDismiss: (() -> Void)? = nil) {
        if window != nil {
            dismiss()
        }

        self.onDismissal = onDismiss
        guard let screen = NSScreen.main else { return }

        // Reset settle state when showing fresh overlay
        viewState.isSettling = false
        viewState.onSettleCompleted = nil
        viewState.isMenuPinned = pinSettingsMenu
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

        overlayWindow.onArrowUp = { [weak self] in
            self?.viewState.previousSetting()
        }

        overlayWindow.onArrowDown = { [weak self] in
            self?.viewState.nextSetting()
        }

        overlayWindow.onArrowLeft = { [weak self] in
            self?.viewState.adjustSelectedSetting(by: -1)
        }

        overlayWindow.onArrowRight = { [weak self] in
            self?.viewState.adjustSelectedSetting(by: 1)
        }

        overlayWindow.onReset = { [weak self] in
            self?.viewState.resetToDefaults()
        }

        overlayWindow.onTogglePin = { [weak self] in
            self?.viewState.isMenuPinned.toggle()
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
    func dismiss() {
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
    @Published var keystoneStrength: Float = 0.18
    @Published var stretchBalance: Float = 0.56
    @Published var lookaheadTime: Double = 0.18
    @Published var keyboardReflection: Float = 0.44
    @Published var keyboardTilt: Float = 0.40
    @Published var keyboardReach: Float = 0.38
    @Published var keyboardBacklight: Float = 1.50
    @Published var keyboardOffset: Float = -0.01
    @Published var keyboardWidth: Float = 0.88
    @Published var keyboardDepthBlur: Float = 0.30

    // 45° Holographic Menu State
    @Published var selectedSettingIndex: Int = 0
    @Published var isMenuPinned: Bool = false
    @Published var menuAlpha: Float = 0.0
    @Published var menuImage: CGImage? = nil
    var screenSize: CGSize = CGSize(width: 1920, height: 1080)

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
            keyboardReflection = min(max(keyboardReflection + step * 0.02, 0.0), 1.0)
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
        lookaheadTime = 0.18
        keyboardReflection = 0.44
        keyboardTilt = 0.40
        keyboardReach = 0.38
        keyboardBacklight = 1.50
        keyboardOffset = -0.01
        keyboardWidth = 0.88
        keyboardDepthBlur = 0.30
        requestRender()
    }

    func requestRender() {
        let view = WarpedSettingsCardContainer(state: self)
            .frame(width: screenSize.width, height: screenSize.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        if let cgImage = renderer.cgImage {
            self.menuImage = cgImage
        }
    }
}

// MARK: - Key-Catching Window
private class KeyCatchingWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onToggleHUD: (() -> Void)?
    var onArrowUp: (() -> Void)?
    var onArrowDown: (() -> Void)?
    var onArrowLeft: (() -> Void)?
    var onArrowRight: (() -> Void)?
    var onReset: (() -> Void)?
    var onTogglePin: (() -> Void)?

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
        case 1: // 'S' key
            onTogglePin?()
        case 15: // 'R' key
            onReset?()
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "h" {
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
            // Fullscreen Metal Canvas with Warped Menu layer
            PerspectiveMetalView(
                snapshot: snapshot,
                sensor: sensor,
                fallbackAngle: sensor.currentAngle,
                lookahead: state.lookaheadTime,
                keystoneStrength: state.keystoneStrength,
                stretchBalance: state.stretchBalance,
                keyboardReflection: state.keyboardReflection,
                keyboardTilt: state.keyboardTilt,
                keyboardReach: state.keyboardReach,
                keyboardBacklight: state.keyboardBacklight,
                keyboardOffset: state.keyboardOffset,
                keyboardWidth: state.keyboardWidth,
                keyboardDepthBlur: state.keyboardDepthBlur,
                menuImage: state.menuImage,
                menuAlpha: state.menuAlpha,
                isSettling: state.isSettling,
                onSettleCompleted: {
                    state.onSettleCompleted?()
                },
                onFirstFrame: onFirstFrame
            )
            .ignoresSafeArea()

            // 45° Alignment / Navigation Guidance Banner (always visible at top)
            VStack {
                HStack(spacing: 12) {
                    Circle()
                        .fill(angleAlignmentColor)
                        .frame(width: 10, height: 10)

                    Text(guideBannerText)
                        .font(.system(.subheadline, design: .rounded).bold())
                        .foregroundStyle(.primary)

                    Spacer()

                    HStack(spacing: 8) {
                        Text(String(format: "%.1f°", sensor.displayAngle))
                            .font(.system(.subheadline, design: .monospaced).bold())
                            .foregroundStyle(.cyan)

                        Text("[S] Pin")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(state.isMenuPinned ? Color.cyan.opacity(0.3) : Color.primary.opacity(0.1))
                            .cornerRadius(5)

                        Text("[ESC] Exit")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(5)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                .padding(.top, 18)

                Spacer()
            }
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .top).combined(with: .opacity))

            // Traditional Floating Tweaker Panel (Optional fallback via 'H' key)
            if state.showHUD {
                floatingHudPanel
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: state.showHUD)
        .onAppear {
            updateMenuAlpha(for: sensor.currentAngle)
            state.requestRender()
        }
        .onChange(of: sensor.displayAngle) { newAngle in
            updateMenuAlpha(for: newAngle)
        }
    }

    private func updateMenuAlpha(for angle: Double) {
        if state.isMenuPinned {
            state.menuAlpha = 1.0
        } else {
            let diff = abs(angle - 45.0)
            if diff <= 4.0 {
                state.menuAlpha = 1.0
            } else if diff <= 8.0 {
                state.menuAlpha = Float(max(0.0, 1.0 - ((diff - 4.0) / 4.0)))
            } else {
                state.menuAlpha = 0.0
            }
        }
    }

    private var isAtTargetAngle: Bool {
        abs(sensor.displayAngle - 45.0) <= 4.0
    }

    private var angleAlignmentColor: Color {
        if state.isMenuPinned {
            return .cyan
        } else if isAtTargetAngle {
            return .green
        } else if abs(sensor.displayAngle - 45.0) <= 8.0 {
            return .orange
        } else {
            return .yellow
        }
    }

    private var guideBannerText: String {
        if state.isMenuPinned {
            return "📌 Holographic Settings Pinned • [↑/↓] Select • [←/→] Adjust • [R] Reset"
        } else if isAtTargetAngle {
            return "✨ 45° Target Locked — Warped Settings Active • [↑/↓] Select • [←/→] Adjust"
        } else if sensor.displayAngle > 45.0 {
            return String(format: "📐 Tilt screen forward to 45° for Warped Settings (Current: %.1f°)", sensor.displayAngle)
        } else {
            return String(format: "📐 Open screen backward to 45° for Warped Settings (Current: %.1f°)", sensor.displayAngle)
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
            Text("Press [H] to toggle this panel, or tilt to 45° for the holographic warped overlay.")
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

    var body: some View {
        ZStack {
            // Transparent backdrop for entire screen canvas
            Color.clear

            // Centered Holographic Settings Card
            VStack(spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.2.square.badge.arrow.down")
                        .font(.system(size: 28))
                        .foregroundStyle(.cyan)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("PERSPECTIVE CALIBRATOR")
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundStyle(.white)

                        Text("45° Holographic Warped Overlay • Direct Surface Projection")
                            .font(.system(size: 11, weight: .semibold, design: .default))
                            .foregroundStyle(.cyan.opacity(0.85))
                    }

                    Spacer()

                    if state.isMenuPinned {
                        Text("PINNED [S]")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.cyan.opacity(0.25))
                            .foregroundStyle(.cyan)
                            .cornerRadius(6)
                    }
                }
                .padding(.bottom, 4)

                Divider()
                    .background(Color.cyan.opacity(0.3))

                // Parameter rows
                VStack(spacing: 8) {
                    ForEach(TunableSetting.allCases) { setting in
                        SettingRow(
                            setting: setting,
                            isSelected: state.selectedSettingIndex == setting.rawValue,
                            valueText: formattedValue(for: setting),
                            progress: progress(for: setting)
                        )
                    }
                }

                Divider()
                    .background(Color.cyan.opacity(0.3))

                // Keyboard controls hint footer
                HStack {
                    Text("[↑/↓] Select Parameter")
                    Spacer()
                    Text("[←/→] Adjust Value")
                    Spacer()
                    Text("[R] Reset")
                    Spacer()
                    Text("[S] Pin/Unpin")
                    Spacer()
                    Text("[ESC] Exit")
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 4)
            }
            .padding(24)
            .frame(width: 680)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.04, green: 0.05, blue: 0.08).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.9), Color.blue.opacity(0.5), Color.purple.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2
                    )
            )
            .shadow(color: Color.cyan.opacity(0.35), radius: 24, x: 0, y: 8)
        }
    }

    private func formattedValue(for setting: TunableSetting) -> String {
        switch setting {
        case .keystone: return String(format: "%.2f", state.keystoneStrength)
        case .stretch: return String(format: "%.2f", state.stretchBalance)
        case .lookahead: return String(format: "%.2fs", state.lookaheadTime)
        case .keyboardReflection: return String(format: "%.2f", state.keyboardReflection)
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
        case .keyboardReflection: return Double(state.keyboardReflection / 1.0)
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

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Text(isSelected ? "▶" : " ")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(isSelected ? Color.cyan : Color.clear)
                .frame(width: 14)

            // Parameter name
            Text(setting.title)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.85))
                .frame(width: 170, alignment: .leading)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 6)

                    Capsule()
                        .fill(
                            isSelected ?
                            LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .leading, endPoint: .trailing) :
                            LinearGradient(colors: [Color.white.opacity(0.5), Color.white.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: max(0, min(geo.size.width * CGFloat(progress), geo.size.width)), height: 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)

            // Value readout
            Text(valueText)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(isSelected ? Color.cyan : .white.opacity(0.9))
                .frame(width: 65, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.cyan.opacity(0.16) : Color.clear)
        )
    }
}
