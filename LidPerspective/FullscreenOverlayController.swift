import Cocoa
import SwiftUI
import Combine

@MainActor
final class FullscreenOverlayController: ObservableObject {
    private var window: KeyCatchingWindow?
    @Published private(set) var isShowing: Bool = false
    private var onDismissal: (() -> Void)?
    private let viewState = OverlayViewState()

    func show(snapshot: CGImage, sensor: LidSensor, onDismiss: (() -> Void)? = nil) {
        if window != nil {
            dismiss()
        }

        self.onDismissal = onDismiss
        guard let screen = NSScreen.main else { return }

        // Must use screen.frame (covers physical display including Dock & Menu Bar)
        let overlayWindow = KeyCatchingWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

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
        )

        overlayWindow.contentView = hostView
        overlayWindow.makeKeyAndOrderFront(nil)
        self.window = overlayWindow
        self.isShowing = true
    }

    func dismiss() {
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
    @Published var keystoneStrength: Float = 0.22
    @Published var stretchBalance: Float = 0.56
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
                lidAngle: sensor.currentAngle,
                keystoneStrength: state.keystoneStrength,
                stretchBalance: state.stretchBalance,
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
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Perspective Tuner")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "%.1f°", sensor.currentAngle))
                            .font(.system(.subheadline, design: .monospaced))
                            .bold()
                            .foregroundStyle(.tint)
                    }

                    Divider()

                    // Keystone Strength Slider
                    VStack(alignment: .leading, spacing: 4) {
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
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Stretch Balance:")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", state.stretchBalance))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $state.stretchBalance, in: 0.01...1.5, step: 0.01)
                    }

                    Divider()

                    // Quick Actions
                    HStack {
                        Button("Reset") {
                            state.keystoneStrength = 0.22
                            state.stretchBalance = 0.56
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Log Values to Console") {
                            print("""
                            -------------------------------
                            TUNED PARAMETERS:
                            keystoneStrength = \(String(format: "%.2ff", state.keystoneStrength))
                            stretchBalance   = \(String(format: "%.2ff", state.stretchBalance))
                            -------------------------------
                            """)
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .frame(width: 290)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(radius: 20)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.showHUD)
    }
}
