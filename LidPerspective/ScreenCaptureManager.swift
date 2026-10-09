import Foundation
import Combine
import ScreenCaptureKit
import CoreGraphics
import Cocoa

@MainActor
final class ScreenCaptureManager: ObservableObject {
    @Published var latestSnapshot: CGImage?

    @discardableResult
    func captureCurrentScreen() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mainDisplayID = (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
                print("No display detected for capture")
                return nil
            }

            // Exclude this application's own windows so the captured snapshot reflects user desktop content
            let bundleID = Bundle.main.bundleIdentifier
            let excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }
            let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            
            // Capture at exact native Retina resolution
            let scale = Int(NSScreen.main?.backingScaleFactor ?? 2.0)
            config.width = display.width * scale
            config.height = display.height * scale
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            self.latestSnapshot = image
            print("✓ Screen captured (\(image.width)x\(image.height))")
            return image
        } catch {
            print("Screen capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}
