import SwiftUI
import MetalKit
import simd
import MetalPerformanceShaders

struct PerspectiveMetalView: NSViewRepresentable {
    var snapshot: CGImage?
    var calibratorImage: CGImage? = nil
    var showCalibrator: Bool = false
    var clockImage: CGImage? = nil
    var isClockActive: Bool = false
    var sensor: LidSensor? = nil
    var fallbackAngle: Double = 90.0
    var lookahead: Double = 0.22
    var keystoneStrength: Float
    var stretchBalance: Float
    var lowAngleCompensation: Float = 1.00
    var keyboardReflection: Float = 0.44
    var keyboardTilt: Float = 0.40
    var keyboardReach: Float = 0.38
    var keyboardBacklight: Float = 1.50
    var keyboardOffset: Float = -0.01
    var keyboardWidth: Float = 0.88
    var keyboardDepthBlur: Float = 0.30
    var frostedGlass: Float = 0.10
    var blurIntensity: Float = 1.00
    var shadowIntensity: Float = 1.00
    var isSettling: Bool = false
    var onSettleCompleted: (() -> Void)? = nil
    var onFirstFrame: (() -> Void)? = nil

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        
        // Assign display/snapshot color space to prevent sRGB gamut compression
        if let colorSpace = snapshot?.colorSpace ?? NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) {
            mtkView.colorspace = colorSpace
        }
        
        // Match the display's native refresh rate (up to 120Hz ProMotion)
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Keep color space in sync if the window moves across displays or receives a new snapshot
        if let colorSpace = snapshot?.colorSpace ?? nsView.window?.screen?.colorSpace?.cgColorSpace ?? NSScreen.main?.colorSpace?.cgColorSpace {
            if nsView.colorspace != colorSpace {
                nsView.colorspace = colorSpace
            }
        }

        context.coordinator.onFirstFrame = onFirstFrame
        context.coordinator.sensor = sensor
        context.coordinator.lookahead = lookahead
        context.coordinator.onSettleCompleted = onSettleCompleted
        context.coordinator.showCalibrator = showCalibrator
        context.coordinator.isClockActive = isClockActive

        if isSettling && !context.coordinator.isSettling {
            context.coordinator.startSettling()
        } else if !isSettling && context.coordinator.isSettling {
            context.coordinator.cancelSettling()
        }

        context.coordinator.updateParameters(
            snapshot: snapshot,
            calibratorImage: calibratorImage,
            clockImage: clockImage,
            targetAngle: fallbackAngle,
            keystone: keystoneStrength,
            balance: stretchBalance,
            keyboardReflection: keyboardReflection,
            keyboardTilt: keyboardTilt,
            keyboardReach: keyboardReach,
            keyboardBacklight: keyboardBacklight,
            keyboardOffset: keyboardOffset,
            keyboardWidth: keyboardWidth,
            keyboardDepthBlur: keyboardDepthBlur,
            frostedGlass: frostedGlass,
            blurIntensity: blurIntensity,
            shadowIntensity: shadowIntensity,
            lowAngleCompensation: lowAngleCompensation
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var onFirstFrame: (() -> Void)?
        var sensor: LidSensor?
        var lookahead: Double = 0.22
        private var hasFiredFirstFrame = false

        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var blurredTexture: MTLTexture?
        private var calibratorTexture: MTLTexture?
        private var defaultCalibratorTexture: MTLTexture?
        private var textureSampler: MTLSamplerState?

        // Track last loaded snapshot to prevent re-uploading every frame
        private var lastLoadedSnapshotID: CGImage?
        private var lastLoadedCalibratorID: CGImage?
        private var lastLoadedClockID: CGImage?
        var showCalibrator: Bool = false
        var isClockActive: Bool = false
        private var clockProgress: Float = 0.0
        private var lastFrameTime: CFTimeInterval = 0.0
        private var clockTexture: MTLTexture?
        private var defaultClockTexture: MTLTexture?

        // Smooth interpolation state
        private var targetAngle: Double = 90.0
        private var smoothedAngle: Double = 90.0
        private var keystoneStrength: Float = 0.18
        private var stretchBalance: Float = 0.56
        private var keyboardReflection: Float = 0.44
        private var keyboardTilt: Float = 0.40
        private var keyboardReach: Float = 0.38
        private var keyboardBacklight: Float = 1.50
        private var keyboardOffset: Float = -0.01
        private var keyboardWidth: Float = 0.88
        private var keyboardDepthBlur: Float = 0.30
        private var frostedGlass: Float = 0.10
        private var blurIntensity: Float = 1.00
        private var shadowIntensity: Float = 1.00
        private var lowAngleCompensation: Float = 1.00

        // Tween / Settle to full screen
        private(set) var isSettling: Bool = false
        private var settleStartTime: CFTimeInterval = 0.0
        private let settleDuration: CFTimeInterval = 0.32 // Quick 320ms tween to full screen
        private var frozenAngle: Double = 90.0
        var onSettleCompleted: (() -> Void)?

        struct PerspectiveUniforms {
            var angle: Float
            var aspect: Float
            var keystoneStrength: Float
            var stretchBalance: Float
            var settleProgress: Float = 0.0
            var keyboardReflection: Float = 0.48
            var keyboardTilt: Float = 0.35
            var keyboardReach: Float = 0.38
            var keyboardBacklight: Float = 1.50
            var keyboardOffset: Float = -0.02
            var keyboardWidth: Float = 0.88
            var keyboardDepthBlur: Float = 0.30
            var showCalibrator: Float = 0.0
            var frostedGlass: Float = 0.65
            var blurIntensity: Float = 1.00
            var shadowIntensity: Float = 1.00
            var lowAngleCompensation: Float = 1.00
            var clockProgress: Float = 0.0
            var showClock: Float = 0.0
            var pad0: Float = 0.0
        }

        override init() {
            super.init()
            guard let device = MTLCreateSystemDefaultDevice() else { return }
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            buildPipeline(device: device)
            buildSampler(device: device)
            buildDefaultCalibratorTexture(device: device)
            buildDefaultClockTexture(device: device)
        }

        private func buildDefaultClockTexture(device: MTLDevice) {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 1,
                height: 1,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            if let dummy = device.makeTexture(descriptor: desc) {
                var zero: UInt32 = 0
                dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
                self.defaultClockTexture = dummy
            }
        }

        private func buildDefaultCalibratorTexture(device: MTLDevice) {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: 1,
                height: 1,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            if let dummy = device.makeTexture(descriptor: desc) {
                var zero: UInt32 = 0
                dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
                self.defaultCalibratorTexture = dummy
            }
        }

        func startSettling() {
            guard !isSettling else { return }
            isSettling = true
            settleStartTime = CACurrentMediaTime()
            frozenAngle = smoothedAngle
        }

        func cancelSettling() {
            isSettling = false
        }

        private func buildPipeline(device: MTLDevice) {
            guard let library = device.makeDefaultLibrary(),
                  let vertexFunc = library.makeFunction(name: "vertex_main"),
                  let fragmentFunc = library.makeFunction(name: "fragment_main") else { return }

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunc
            desc.fragmentFunction = fragmentFunc
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }

        private func buildSampler(device: MTLDevice) {
            let desc = MTLSamplerDescriptor()
            desc.minFilter = .linear
            desc.magFilter = .linear
            // Clamp to edge avoids black borders when UVs touch 0.0 or 1.0
            desc.sAddressMode = .clampToEdge
            desc.tAddressMode = .clampToEdge
            textureSampler = device.makeSamplerState(descriptor: desc)
        }
        
        func updateParameters(
            snapshot: CGImage?,
            calibratorImage: CGImage?,
            clockImage: CGImage? = nil,
            targetAngle: Double,
            keystone: Float,
            balance: Float,
            keyboardReflection: Float,
            keyboardTilt: Float,
            keyboardReach: Float,
            keyboardBacklight: Float,
            keyboardOffset: Float,
            keyboardWidth: Float,
            keyboardDepthBlur: Float,
            frostedGlass: Float,
            blurIntensity: Float,
            shadowIntensity: Float,
            lowAngleCompensation: Float
        ) {
            self.targetAngle = targetAngle
            self.keystoneStrength = keystone
            self.stretchBalance = balance
            self.keyboardReflection = keyboardReflection
            self.keyboardTilt = keyboardTilt
            self.keyboardReach = keyboardReach
            self.keyboardBacklight = keyboardBacklight
            self.keyboardOffset = keyboardOffset
            self.keyboardWidth = keyboardWidth
            self.keyboardDepthBlur = keyboardDepthBlur
            self.frostedGlass = frostedGlass
            self.blurIntensity = blurIntensity
            self.shadowIntensity = shadowIntensity
            self.lowAngleCompensation = lowAngleCompensation

            if let snapshot = snapshot, snapshot !== lastLoadedSnapshotID, let device = self.device {
                self.lastLoadedSnapshotID = snapshot
                let loader = MTKTextureLoader(device: device)
                let loadedTexture = try? loader.newTexture(cgImage: snapshot, options: [
                    .SRGB: false,
                    .generateMipmaps: false,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue | MTLTextureUsage.shaderWrite.rawValue)
                ])
                self.texture = loadedTexture

                // Pre-blur the snapshot once using Metal Performance Shaders
                if let sourceTexture = loadedTexture {
                    self.blurredTexture = makeBlurredTexture(from: sourceTexture, device: device, sigma: 40)
                }
            }

            if let calibImage = calibratorImage, calibImage !== lastLoadedCalibratorID, let device = self.device {
                self.lastLoadedCalibratorID = calibImage
                self.calibratorTexture = makeTexture(from: calibImage, device: device)
            }

            if let clkImage = clockImage, clkImage !== lastLoadedClockID, let device = self.device {
                self.lastLoadedClockID = clkImage
                self.clockTexture = makeTexture(from: clkImage, device: device)
            }
        }

        private func makeTexture(from cgImage: CGImage, device: MTLDevice) -> MTLTexture? {
            let width = cgImage.width
            let height = cgImage.height
            guard width > 0, height > 0 else { return nil }

            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: desc) else { return nil }

            if let data = cgImage.dataProvider?.data,
               let ptr = CFDataGetBytePtr(data),
               cgImage.bitsPerPixel == 32 {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: ptr,
                    bytesPerRow: cgImage.bytesPerRow
                )
                return texture
            }

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            var rawData = [UInt8](repeating: 0, count: width * height * 4)
            let bytesPerRow = width * 4

            guard let context = CGContext(
                data: &rawData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return nil
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: rawData,
                bytesPerRow: bytesPerRow
            )
            return texture
        }

        private func makeBlurredTexture(from source: MTLTexture, device: MTLDevice, sigma: Float) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat,
                width: source.width,
                height: source.height,
                mipmapped: false
            )
            desc.usage = [.shaderRead, .shaderWrite]

            guard let target = device.makeTexture(descriptor: desc),
                  let queue = self.commandQueue,
                  let commandBuffer = queue.makeCommandBuffer() else {
                return nil
            }

            let blurFilter = MPSImageGaussianBlur(device: device, sigma: sigma)
            blurFilter.edgeMode = .clamp
            blurFilter.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: target)
            commandBuffer.commit()

            return target
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipelineState = pipelineState,
                  let drawable = view.currentDrawable,
                  let renderPass = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue?.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass),
                  let texture = texture,
                  let blurredTexture = blurredTexture else { return }

            var settleFactor: Float = 0.0
            if isSettling {
                let now = CACurrentMediaTime()
                let elapsed = now - settleStartTime
                let t = min(max(Float(elapsed / settleDuration), 0.0), 1.0)
                // Smooth cubic ease-out: 1 - (1 - t)^3
                settleFactor = 1.0 - pow(1.0 - t, 3.0)

                if t >= 1.0 {
                    isSettling = false
                    settleFactor = 1.0
                    DispatchQueue.main.async { [weak self] in
                        self?.onSettleCompleted?()
                    }
                }
            }

            let targetAngle: Double
            if isSettling {
                targetAngle = frozenAngle
            } else if let sensor = self.sensor {
                targetAngle = sensor.extrapolatedAngle(lookahead: self.lookahead)
            } else {
                targetAngle = self.targetAngle
            }

            if isSettling {
                self.smoothedAngle = frozenAngle
            } else {
                let smoothingFactor = 0.25
                self.smoothedAngle += (targetAngle - self.smoothedAngle) * smoothingFactor
            }
            
            // Clock transition progress animation
            let now = CACurrentMediaTime()
            let dt = lastFrameTime > 0 ? Float(min(now - lastFrameTime, 0.1)) : 0.016
            lastFrameTime = now

            if isClockActive {
                if clockProgress < 1.0 {
                    clockProgress = min(clockProgress + dt / 0.45, 1.0)
                }
            } else {
                if clockProgress > 0.0 {
                    clockProgress = max(clockProgress - dt / 0.25, 0.0)
                }
            }

            let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
            let angleRadians = Float(smoothedAngle * (.pi / 180.0))

            var uniforms = PerspectiveUniforms(
                angle: angleRadians,
                aspect: aspect,
                keystoneStrength: self.keystoneStrength,
                stretchBalance: self.stretchBalance,
                settleProgress: settleFactor,
                keyboardReflection: self.keyboardReflection,
                keyboardTilt: self.keyboardTilt,
                keyboardReach: self.keyboardReach,
                keyboardBacklight: self.keyboardBacklight,
                keyboardOffset: self.keyboardOffset,
                keyboardWidth: self.keyboardWidth,
                keyboardDepthBlur: self.keyboardDepthBlur,
                showCalibrator: (self.showCalibrator && self.calibratorTexture != nil) ? 1.0 : 0.0,
                frostedGlass: self.frostedGlass,
                blurIntensity: self.blurIntensity,
                shadowIntensity: self.shadowIntensity,
                lowAngleCompensation: self.lowAngleCompensation,
                clockProgress: self.clockProgress,
                showClock: (self.clockTexture != nil && self.clockProgress > 0.001) ? 1.0 : 0.0,
                pad0: 0.0
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PerspectiveUniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(blurredTexture, index: 1)
            let calibTex = (self.showCalibrator ? self.calibratorTexture : nil) ?? self.defaultCalibratorTexture
            encoder.setFragmentTexture(calibTex, index: 2)
            let clkTex = (self.clockProgress > 0.001 ? self.clockTexture : nil) ?? self.defaultClockTexture
            encoder.setFragmentTexture(clkTex, index: 3)
            encoder.setFragmentSamplerState(textureSampler, index: 0)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()

            if !hasFiredFirstFrame {
                hasFiredFirstFrame = true
                DispatchQueue.main.async { [weak self] in
                    self?.onFirstFrame?()
                }
            }
        }
    }
}
