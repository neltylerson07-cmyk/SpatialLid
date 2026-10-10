import Foundation
import Combine
import ScreenCaptureKit
import CoreGraphics
import Cocoa
import Metal
import MetalKit
import MetalPerformanceShaders

struct PreparedDisplayTexture: @unchecked Sendable {
    let texture: MTLTexture
    let blurredTexture: MTLTexture
}

struct MultiScreenSnapshots {
    var builtinSnapshot: CGImage?
    var builtinScreen: NSScreen?
    var builtinTextures: PreparedDisplayTexture?
    var externalSnapshots: [(screen: NSScreen, displayID: CGDirectDisplayID, image: CGImage, textures: PreparedDisplayTexture?)] = []

    var hasExternalSnapshots: Bool {
        !externalSnapshots.isEmpty
    }
}

@MainActor
final class ScreenCaptureManager: ObservableObject {
    @Published var latestSnapshot: CGImage?

    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private lazy var metalQueue: MTLCommandQueue? = metalDevice?.makeCommandQueue()

    private var inFlightCaptureTask: Task<MultiScreenSnapshots, Never>?
    private var warmSnapshots: MultiScreenSnapshots?
    private var lastCaptureTimestamp: CFTimeInterval = 0.0

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static func isBuiltin(screen: NSScreen) -> Bool {
        guard let id = displayID(for: screen) else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }

    /// Prepares Metal texture and GPU-blurred texture asynchronously on any thread.
    nonisolated static func prepareTextures(
        from image: CGImage,
        device: (any MTLDevice)?,
        queue: (any MTLCommandQueue)?
    ) -> PreparedDisplayTexture? {
        guard let device = device, let queue = queue else { return nil }

        let loader = MTKTextureLoader(device: device)
        guard let sourceTexture = try? loader.newTexture(cgImage: image, options: [
            .SRGB: false,
            .generateMipmaps: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue | MTLTextureUsage.shaderWrite.rawValue)
        ]) else {
            return nil
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: sourceTexture.pixelFormat,
            width: sourceTexture.width,
            height: sourceTexture.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]

        guard let target = device.makeTexture(descriptor: desc),
              let commandBuffer = queue.makeCommandBuffer() else {
            return nil
        }

        let blurFilter = MPSImageGaussianBlur(device: device, sigma: 40)
        blurFilter.edgeMode = .clamp
        blurFilter.encode(commandBuffer: commandBuffer, sourceTexture: sourceTexture, destinationTexture: target)
        commandBuffer.commit()

        return PreparedDisplayTexture(texture: sourceTexture, blurredTexture: target)
    }

    /// Synchronous zero-latency snapshot getter for instant presentation.
    func getImmediateSnapshots() -> MultiScreenSnapshots? {
        guard let warm = warmSnapshots, warm.builtinSnapshot != nil else { return nil }
        return warm
    }

    /// Checks if the cached snapshot is recently taken (within last 1.8 seconds).
    var isFresh: Bool {
        guard warmSnapshots?.builtinSnapshot != nil else { return false }
        return (CACurrentMediaTime() - lastCaptureTimestamp) < 1.8
    }

    /// Starts a proactive background capture so snapshots are immediately available when the lid reaches 90°.
    func precapture(force: Bool = false) {
        if !force && (inFlightCaptureTask != nil || isFresh) {
            return
        }
        if inFlightCaptureTask != nil {
            return
        }
        inFlightCaptureTask = Task { [weak self] in
            guard let self = self else { return MultiScreenSnapshots() }
            let snaps = await self.performCaptureAllScreens()
            if snaps.builtinSnapshot != nil {
                self.warmSnapshots = snaps
                self.lastCaptureTimestamp = CACurrentMediaTime()
            }
            self.inFlightCaptureTask = nil
            return snaps
        }
    }

    /// Refreshes snapshots in the background and returns the new result if successful.
    func refreshSnapshots() async -> MultiScreenSnapshots? {
        if let inFlight = inFlightCaptureTask {
            let snaps = await inFlight.value
            return snaps.builtinSnapshot != nil ? snaps : nil
        }
        let snaps = await performCaptureAllScreens()
        if snaps.builtinSnapshot != nil {
            self.warmSnapshots = snaps
            self.lastCaptureTimestamp = CACurrentMediaTime()
            return snaps
        }
        return nil
    }

    /// Discards in-flight capture task.
    func cancelPrecapture() {
        inFlightCaptureTask?.cancel()
        inFlightCaptureTask = nil
    }

    /// Captures snapshots across all connected displays (uses warm snapshot if available, or awaits in-flight).
    func captureAllScreens() async -> MultiScreenSnapshots {
        if let warm = warmSnapshots, warm.builtinSnapshot != nil && isFresh {
            return warm
        }
        if let inFlight = inFlightCaptureTask {
            let snaps = await inFlight.value
            self.inFlightCaptureTask = nil
            if snaps.builtinSnapshot != nil {
                self.warmSnapshots = snaps
                self.lastCaptureTimestamp = CACurrentMediaTime()
                return snaps
            }
        }
        let snaps = await performCaptureAllScreens()
        if snaps.builtinSnapshot != nil {
            self.warmSnapshots = snaps
            self.lastCaptureTimestamp = CACurrentMediaTime()
        }
        return snaps
    }

    /// Internal capture worker executing concurrent multi-display queries and background texture preparation.
    private func performCaptureAllScreens() async -> MultiScreenSnapshots {
        var result = MultiScreenSnapshots()

        do {
            // Excluding desktop windows dramatically reduces WindowServer query overhead
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let bundleID = Bundle.main.bundleIdentifier
            let excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }

            let allScreens = NSScreen.screens
            let builtin = allScreens.first(where: { Self.isBuiltin(screen: $0) }) ?? NSScreen.main ?? allScreens.first
            result.builtinScreen = builtin
            let externalScreens = allScreens.filter { $0 != builtin }

            let device = self.metalDevice
            let queue = self.metalQueue

            enum CaptureTaskResult: Sendable {
                case builtin(image: CGImage?, textures: PreparedDisplayTexture?)
                case external(displayID: CGDirectDisplayID, image: CGImage, textures: PreparedDisplayTexture?)
            }

            // Capture all screens concurrently
            let capturedItems: [CaptureTaskResult] = await withTaskGroup(of: CaptureTaskResult?.self) { group in
                // 1. Builtin display
                if let builtinScreen = builtin,
                   let builtinID = Self.displayID(for: builtinScreen),
                   let display = content.displays.first(where: { $0.displayID == builtinID }) ?? content.displays.first {
                    let scale = Int(builtinScreen.backingScaleFactor)
                    group.addTask {
                        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                        let config = SCStreamConfiguration()
                        config.width = display.width * scale
                        config.height = display.height * scale
                        config.showsCursor = false

                        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                            let textures = Self.prepareTextures(from: img, device: device, queue: queue)
                            return .builtin(image: img, textures: textures)
                        }
                        return nil
                    }
                }

                // 2. External displays
                for extScreen in externalScreens {
                    guard let extID = Self.displayID(for: extScreen),
                          let display = content.displays.first(where: { $0.displayID == extID }) else { continue }

                    let scale = Int(extScreen.backingScaleFactor)
                    group.addTask {
                        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                        let config = SCStreamConfiguration()
                        config.width = display.width * scale
                        config.height = display.height * scale
                        config.showsCursor = false

                        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                            let textures = Self.prepareTextures(from: img, device: device, queue: queue)
                            return .external(displayID: extID, image: img, textures: textures)
                        }
                        return nil
                    }
                }

                var items = [CaptureTaskResult]()
                for await item in group {
                    if let valid = item {
                        items.append(valid)
                    }
                }
                return items
            }

            for item in capturedItems {
                switch item {
                case .builtin(let img, let textures):
                    if let img = img {
                        result.builtinSnapshot = img
                        result.builtinTextures = textures
                        self.latestSnapshot = img
                    }
                case .external(let displayID, let img, let textures):
                    if let extScreen = externalScreens.first(where: { Self.displayID(for: $0) == displayID }) {
                        result.externalSnapshots.append((screen: extScreen, displayID: displayID, image: img, textures: textures))
                    }
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
