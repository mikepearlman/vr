import AVFoundation
import MetalKit
import UIKit

private final class RetainedVideoFrame: @unchecked Sendable {
    let texture: CVMetalTexture
    init(_ texture: CVMetalTexture) { self.texture = texture }
}

struct ViewUniforms {
    var camera: SIMD4<Float>
    var mode: SIMD4<Float>
    var transformX: SIMD4<Float>
    var transformY: SIMD4<Float>
}

@MainActor
final class VideoRenderer: NSObject, MTKViewDelegate {
    let metalView: MTKView
    var output: AVPlayerItemVideoOutput?
    var viewState = ViewState() { didSet { needsDraw = true } }
    var sourceSize = CGSize(width: 1, height: 1)
    var sourceTransform = CGAffineTransform.identity
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private var frameTexture: CVMetalTexture?
    private var displayLink: CADisplayLink?
    private var needsDraw = true
    private(set) var decodedFrames = 0
    private(set) var renderedFrames = 0
    var onMetrics: ((Int, Int, ProcessInfo.ThermalState) -> Void)?
    private var lastReport = CACurrentMediaTime()

    override init() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            fatalError("This device cannot create the Metal video renderer.")
        }
        self.queue = queue
        metalView = MTKView(frame: .zero, device: device)
        metalView.colorPixelFormat = .rgba16Float
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.framebufferOnly = true
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.isOpaque = true
        metalView.backgroundColor = .black
        // AVFoundation produces linear BT.2020 half-float pixels. Keep that space through presentation.
        (metalView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        (metalView.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "project180")
        descriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        metalView.delegate = self
    }
    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let maximum = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    func reset() {
        output = nil
        frameTexture = nil
        decodedFrames = 0
        renderedFrames = 0
        CVMetalTextureCacheFlush(cache!, 0)
        needsDraw = true
    }
    @objc private func tick(_ link: CADisplayLink) {
        if let output {
            let time = output.itemTime(forHostTime: link.targetTimestamp)
            if output.hasNewPixelBuffer(forItemTime: time),
               let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil), let cache {
                var cvTexture: CVMetalTexture?
                let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
                    .rgba16Float, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &cvTexture)
                if status == kCVReturnSuccess {
                    frameTexture = cvTexture
                    decodedFrames += 1
                    needsDraw = true
                }
            }
        }
        if needsDraw { metalView.draw() }
        if link.timestamp - lastReport >= 5 {
            onMetrics?(decodedFrames, renderedFrames, ProcessInfo.processInfo.thermalState)
            lastReport = link.timestamp
        }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewState.constrain(aspect: Float(size.width / max(1, size.height)))
    }
    func draw(in view: MTKView) {
        guard let cvTexture = frameTexture, let texture = CVMetalTextureGetTexture(cvTexture),
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        let rect = CGRect(origin: .zero, size: sourceSize).applying(sourceTransform)
        let inverse = sourceTransform.inverted()
        let w = max(1, sourceSize.width), h = max(1, sourceSize.height)
        var uniforms = ViewUniforms(
            camera: SIMD4(viewState.yaw, viewState.pitch, tan(viewState.fieldOfView * .pi / 360), aspect),
            mode: SIMD4(viewState.rightEye ? 1 : 0, viewState.fisheye ? 1 : 0, 0, 0),
            transformX: SIMD4(Float(inverse.a * rect.width / w), Float(inverse.c * rect.height / w), Float((inverse.a * rect.minX + inverse.c * rect.minY + inverse.tx) / w), 0),
            transformY: SIMD4(Float(inverse.b * rect.width / h), Float(inverse.d * rect.height / h), Float((inverse.b * rect.minX + inverse.d * rect.minY + inverse.ty) / h), 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // Retain the pixel buffer's texture until the GPU finishes reading it.
        let retainedFrame = RetainedVideoFrame(cvTexture)
        command.addCompletedHandler { _ in _ = retainedFrame.texture }
        command.present(drawable)
        command.commit()
        renderedFrames += 1
        needsDraw = false
    }
}
