import SwiftUI
import MetalKit
import simd
import MetalPerformanceShaders

struct PerspectiveMetalView: NSViewRepresentable {
    var snapshot: CGImage?
    var lidAngle: Double
    var keystoneStrength: Float
    var stretchBalance: Float
    var onFirstFrame: (() -> Void)? = nil

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        
        // Match the display's native refresh rate (up to 120Hz ProMotion)
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.onFirstFrame = onFirstFrame
        context.coordinator.updateParameters(
            snapshot: snapshot,
            targetAngle: lidAngle,
            keystone: keystoneStrength,
            balance: stretchBalance
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var onFirstFrame: (() -> Void)?
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
        private var keystoneStrength: Float = 0.28
        private var stretchBalance: Float = 0.46

        struct PerspectiveUniforms {
            var angle: Float
            var aspect: Float
            var keystoneStrength: Float
            var stretchBalance: Float
        }

        override init() {
            super.init()
            guard let device = MTLCreateSystemDefaultDevice() else { return }
            self.device = device
            self.commandQueue = device.makeCommandQueue()

            buildPipeline(device: device)
            buildSampler(device: device)
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
        
        func updateParameters(snapshot: CGImage?, targetAngle: Double, keystone: Float, balance: Float) {
            self.targetAngle = targetAngle
            self.keystoneStrength = keystone
            self.stretchBalance = balance

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

            let smoothingFactor = 0.35
            self.smoothedAngle += (targetAngle - self.smoothedAngle) * smoothingFactor
            
            let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
            let angleRadians = Float(smoothedAngle * (.pi / 180.0))

            var uniforms = PerspectiveUniforms(
                angle: angleRadians,
                aspect: aspect,
                keystoneStrength: self.keystoneStrength,
                stretchBalance: self.stretchBalance
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
