import SwiftUI
import MetalKit
import simd
import MetalPerformanceShaders

struct PerspectiveMetalView: NSViewRepresentable {
    var snapshot: CGImage?
    var sensor: LidSensor? = nil
    var fallbackAngle: Double = 90.0
    var lookahead: Double = 0.18
    var keystoneStrength: Float
    var stretchBalance: Float
    var keyboardReflection: Float = 0.44
    var keyboardTilt: Float = 0.40
    var keyboardReach: Float = 0.38
    var keyboardBacklight: Float = 1.50
    var keyboardOffset: Float = -0.01
    var keyboardWidth: Float = 0.88
    var keyboardDepthBlur: Float = 0.30
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

        if isSettling && !context.coordinator.isSettling {
            context.coordinator.startSettling()
        } else if !isSettling && context.coordinator.isSettling {
            context.coordinator.cancelSettling()
        }

        context.coordinator.updateParameters(
            snapshot: snapshot,
            targetAngle: fallbackAngle,
            keystone: keystoneStrength,
            balance: stretchBalance,
            keyboardReflection: keyboardReflection,
            keyboardTilt: keyboardTilt,
            keyboardReach: keyboardReach,
            keyboardBacklight: keyboardBacklight,
            keyboardOffset: keyboardOffset,
            keyboardWidth: keyboardWidth,
            keyboardDepthBlur: keyboardDepthBlur
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var onFirstFrame: (() -> Void)?
        var sensor: LidSensor?
        var lookahead: Double = 0.18
        private var hasFiredFirstFrame = false

        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var blurredTexture: MTLTexture?
        private var textureSampler: MTLSamplerState?

        // Track last loaded snapshot to prevent re-uploading every frame
        private var lastLoadedSnapshotID: CGImage?

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
        }

        override init() {
            super.init()
            guard let device = MTLCreateSystemDefaultDevice() else { return }
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            buildPipeline(device: device)
            buildSampler(device: device)
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
            targetAngle: Double,
            keystone: Float,
            balance: Float,
            keyboardReflection: Float,
            keyboardTilt: Float,
            keyboardReach: Float,
            keyboardBacklight: Float,
            keyboardOffset: Float,
            keyboardWidth: Float,
            keyboardDepthBlur: Float
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
                keyboardDepthBlur: self.keyboardDepthBlur
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PerspectiveUniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentTexture(blurredTexture, index: 1)
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
