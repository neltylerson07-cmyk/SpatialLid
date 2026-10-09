import Foundation
import Combine
import ScreenCaptureKit
import CoreGraphics

@MainActor
final class ScreenCaptureManager: ObservableObject {
    @Published var latestSnapshot: CGImage?

    func captureCurrentScreen() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                print("No display detected for capture")
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            
            // Capture at native Retina resolution
            config.width = display.width * 2
            config.height = display.height * 2
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            self.latestSnapshot = image
            print("✓ Screen captured (\(image.width)x\(image.height))")
        } catch {
            print("Screen capture failed: \(error.localizedDescription)")
        }
    }
}
