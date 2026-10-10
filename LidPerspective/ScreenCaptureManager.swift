import Foundation
import Combine
import ScreenCaptureKit
import CoreGraphics
import Cocoa

struct MultiScreenSnapshots {
    var builtinSnapshot: CGImage?
    var builtinScreen: NSScreen?
    var externalSnapshots: [(screen: NSScreen, displayID: CGDirectDisplayID, image: CGImage)] = []

    var hasExternalSnapshots: Bool {
        !externalSnapshots.isEmpty
    }
}

@MainActor
final class ScreenCaptureManager: ObservableObject {
    @Published var latestSnapshot: CGImage?

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func isBuiltin(screen: NSScreen) -> Bool {
        guard let id = displayID(for: screen) else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// Captures snapshots across all connected displays (both built-in and external monitors).
    func captureAllScreens() async -> MultiScreenSnapshots {
        var result = MultiScreenSnapshots()

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let bundleID = Bundle.main.bundleIdentifier
            let excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }

            // Find built-in screen (laptop display), falling back to main or first screen
            let allScreens = NSScreen.screens
            let builtin = allScreens.first(where: { Self.isBuiltin(screen: $0) }) ?? NSScreen.main ?? allScreens.first
            result.builtinScreen = builtin

            // Separate external screens
            let externalScreens = allScreens.filter { $0 != builtin }

            // 1. Capture Built-in Display
            if let builtinScreen = builtin,
               let builtinID = Self.displayID(for: builtinScreen),
               let display = content.displays.first(where: { $0.displayID == builtinID }) ?? content.displays.first {
                let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                let scale = Int(builtinScreen.backingScaleFactor)
                config.width = display.width * scale
                config.height = display.height * scale
                config.showsCursor = false

                if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    result.builtinSnapshot = img
                    self.latestSnapshot = img
                    print("✓ Built-in screen captured (\(img.width)x\(img.height))")
                }
            }

            // 2. Capture External Displays concurrently
            for extScreen in externalScreens {
                guard let extID = Self.displayID(for: extScreen),
                      let display = content.displays.first(where: { $0.displayID == extID }) else { continue }

                let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                let scale = Int(extScreen.backingScaleFactor)
                config.width = display.width * scale
                config.height = display.height * scale
                config.showsCursor = false

                if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    result.externalSnapshots.append((screen: extScreen, displayID: extID, image: img))
                    print("✓ External screen captured (DisplayID: \(extID), \(img.width)x\(img.height))")
                }
            }

            return result
        } catch {
            print("Multi-screen capture failed: \(error.localizedDescription)")
            return result
        }
    }

    @discardableResult
    func captureCurrentScreen() async -> CGImage? {
        let snapshots = await captureAllScreens()
        return snapshots.builtinSnapshot
    }
}
