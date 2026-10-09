

import Cocoa
import SwiftUI

@MainActor
final class FullscreenOverlayController {
    private var window: NSWindow?

    func show(snapshot: CGImage, sensor: LidSensor) {
        guard let screen = NSScreen.main else { return }

        // 1. MUST use screen.frame (covers physical display including Dock & Menu Bar),
        // not screen.visibleFrame (which cuts off the Dock and Menu Bar).
        let overlayWindow = KeyCatchingWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        // 2. Set to ScreenSaver level: sits higher than the Dock, Menu Bar, and popups
        overlayWindow.level = NSWindow.Level(Int(CGWindowLevelForKey(.screenSaverWindow)))

        // 3. Collection behaviors:
        // - canJoinAllSpaces: visible on every virtual desktop
        // - fullScreenAuxiliary: allows it to display over native Fullscreen apps
        // - stationary: does not move during Mission Control / Exposé gestures
        // - ignoresCycle: skipped by Cmd+Tab window cycling
        overlayWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        overlayWindow.isOpaque = true
        overlayWindow.backgroundColor = .black
        overlayWindow.hasShadow = false

        let hostView = NSHostingView(
            rootView: FullscreenPerspectiveContainer(
                snapshot: snapshot,
                sensor: sensor,
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )
        )

        overlayWindow.contentView = hostView
        overlayWindow.makeKeyAndOrderFront(nil)
        self.window = overlayWindow
    }

    func dismiss() {
        window?.orderOut(nil)
        window = nil
    }
}

private class KeyCatchingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC key
            self.orderOut(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

private struct FullscreenPerspectiveContainer: View {
    let snapshot: CGImage
    @ObservedObject var sensor: LidSensor
    let onDismiss: () -> Void

    // Live tunable parameters
    @State private var keystoneStrength: Float = 0.28
    @State private var stretchBalance: Float = 0.46
    @State private var showHUD: Bool = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Fullscreen Metal Canvas
            PerspectiveMetalView(
                snapshot: snapshot,
                lidAngle: sensor.currentAngle,
                keystoneStrength: keystoneStrength,
                stretchBalance: stretchBalance
            )
            .ignoresSafeArea()

            // Top-right controls: HUD Toggle & ESC Button
            HStack(spacing: 8) {
                Button(action: { showHUD.toggle() }) {
                    Text(showHUD ? "Hide HUD (H)" : "Tune Parameters")
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

            // Live Tweaker Panel (Floating HUD)
            if showHUD {
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
                            Text(String(format: "%.2f", keystoneStrength))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $keystoneStrength, in: 0.0...1.0, step: 0.01)
                    }

                    // Stretch / Aspect Balance Slider
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Stretch Balance:")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.2f", stretchBalance))
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $stretchBalance, in: 0.01...1.5, step: 0.01)
                    }

                    Divider()

                    // Quick Actions
                    HStack {
                        Button("Reset") {
                            keystoneStrength = 0.22
                            stretchBalance = 0.56
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Log Values to Console") {
                            print("""
                            -------------------------------
                            TUNED PARAMETERS:
                            keystoneStrength = \(String(format: "%.2ff", keystoneStrength))
                            stretchBalance   = \(String(format: "%.2ff", stretchBalance))
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
            }
        }
    }
}
