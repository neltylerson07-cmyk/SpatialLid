import Cocoa
import SwiftUI
import Combine

@MainActor
final class FullscreenOverlayController: ObservableObject {
    private var window: KeyCatchingWindow?
    @Published private(set) var isShowing: Bool = false
    private var onDismissal: (() -> Void)?
    private let viewState = OverlayViewState()

    var isSettling: Bool {
        viewState.isSettling
    }

    func show(snapshot: CGImage, sensor: LidSensor, onDismiss: (() -> Void)? = nil) {
        if window != nil {
            dismiss()
        }

        self.onDismissal = onDismiss
        guard let screen = NSScreen.main else { return }

        // Reset settle state when showing fresh overlay
        viewState.isSettling = false
        viewState.onSettleCompleted = nil

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
            }
        })
    }
}

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

    // Settle animation state
    @Published var isSettling: Bool = false
    var onSettleCompleted: (() -> Void)?
}

private class KeyCatchingWindow: NSWindow {
    var onEscape: (() -> Void)?
    var onToggleHUD: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            if let onEscape = onEscape {
                onEscape()
            } else {
                self.orderOut(nil)
            }
        } else if event.charactersIgnoringModifiers?.lowercased() == "h" {
            onToggleHUD?()
        } else {
            super.keyDown(with: event)
        }
    }
}

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
                isSettling: state.isSettling,
                onSettleCompleted: {
                    state.onSettleCompleted?()
                },
                onFirstFrame: onFirstFrame
            )
            .ignoresSafeArea()

            // HUD Controls (toggleable via H key or button, hidden by default for pure immersion)
            if state.showHUD {
                // Top-right controls: HUD Toggle & ESC Button
                HStack(spacing: 8) {
                    Button(action: { state.showHUD.toggle() }) {
                        Text("Hide HUD (H)")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)

                    Button(action: onDismiss) {
                        Text("ESC to Exit")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))

                // Live Tweaker Panel (Floating HUD)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Perspective Tuner")
                            .font(.headline)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.1f°", sensor.currentAngle))
                                .font(.system(.subheadline, design: .monospaced))
                                .bold()
                                .foregroundStyle(.tint)
                            Text(String(format: "%+.0f°/s", sensor.displayVelocity))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // SECTION 1: PERSPECTIVE WARP
                    Text("PERSPECTIVE WARP")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)

                    // Keystone Strength Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Keystone Taper:")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", state.keystoneStrength))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.keystoneStrength, in: 0.0...1.0, step: 0.01)
                    }

                    // Stretch / Aspect Balance Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Stretch Balance:")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", state.stretchBalance))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.stretchBalance, in: 0.01...1.5, step: 0.01)
                    }

                    // Lookahead / Extrapolation Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Lookahead (Delay):")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2fs", state.lookaheadTime))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.lookaheadTime, in: 0.0...0.5, step: 0.02)
                    }

                    Divider()

                    // SECTION 2: KEYBOARD REFLECTION
                    Text("KEYBOARD REFLECTION")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)

                    // Reflection Opacity Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Reflection Opacity:")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", state.keyboardReflection))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.keyboardReflection, in: 0.0...1.0, step: 0.01)
                    }

                    // Bottom Edge Offset / Shift Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Bottom Edge Offset:")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%+.2f", state.keyboardOffset))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.keyboardOffset, in: -0.10...0.20, step: 0.01)
                    }

                    // Keyboard Width Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Keyboard Width:")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", state.keyboardWidth))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.keyboardWidth, in: 0.60...1.00, step: 0.02)
                    }

                    // Reflection Tilt / Angle Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Reflection Angle / Tilt:")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", state.keyboardTilt))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.keyboardTilt, in: 0.15...2.0, step: 0.05)
                    }

                    // Vertical Reach / Height Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Vertical Reach (Height):")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", state.keyboardReach))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.keyboardReach, in: 0.12...0.60, step: 0.02)
                    }

                    // Depth Blur (DoF) Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Depth Blur (DoF):")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", state.keyboardDepthBlur))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.keyboardDepthBlur, in: 0.0...2.5, step: 0.05)
                    }

                    // Backlight Luminescence Slider
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Key Backlight Glow:")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", state.keyboardBacklight))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.keyboardBacklight, in: 0.0...2.5, step: 0.05)
                    }

                    Divider()

                    // Quick Actions
                    HStack {
                        Button("Reset") {
                            state.keystoneStrength = 0.18
                            state.stretchBalance = 0.56
                            state.lookaheadTime = 0.18
                            state.keyboardReflection = 0.44
                            state.keyboardTilt = 0.40
                            state.keyboardReach = 0.38
                            state.keyboardBacklight = 1.50
                            state.keyboardOffset = -0.01
                            state.keyboardWidth = 0.88
                            state.keyboardDepthBlur = 0.30
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Log Values") {
                            print("""
                            -------------------------------
                            TUNED PARAMETERS:
                            keystoneStrength   = \(String(format: "%.2ff", state.keystoneStrength))
                            stretchBalance     = \(String(format: "%.2ff", state.stretchBalance))
                            lookaheadTime      = \(String(format: "%.2fs", state.lookaheadTime))
                            keyboardReflection = \(String(format: "%.2ff", state.keyboardReflection))
                            keyboardTilt       = \(String(format: "%.2ff", state.keyboardTilt))
                            keyboardReach      = \(String(format: "%.2ff", state.keyboardReach))
                            keyboardBacklight  = \(String(format: "%.2ff", state.keyboardBacklight))
                            keyboardOffset     = \(String(format: "%.2ff", state.keyboardOffset))
                            keyboardWidth      = \(String(format: "%.2ff", state.keyboardWidth))
                            keyboardDepthBlur  = \(String(format: "%.2ff", state.keyboardDepthBlur))
                            -------------------------------
                            """)
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(14)
                .frame(width: 300)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 20)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: state.showHUD)
    }
}
