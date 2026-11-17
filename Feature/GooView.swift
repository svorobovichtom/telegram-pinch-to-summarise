import UIKit
import Metal
import MetalKit
import TelegramShell

/// One rounded rect for `GooView`. Same layout as `GooShape` in Goo.metal (48 bytes).
struct GooShape {
    var rect: SIMD4<Float>
    var radius: Float
    var shrink: Float
    var group: UInt32
    var pad: Float = 0
    var color: SIMD4<Float>

    /// `color`: a solid fill; `nil` is the service material.
    init(_ rect: CGRect, radius: CGFloat, shrink: CGFloat = 0, group: Int, color: SIMD4<Float>? = nil) {
        self.rect = SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.maxX), Float(rect.maxY))
        self.radius = Float(radius)
        self.shrink = Float(shrink)
        self.group = UInt32(group)
        self.color = color ?? .zero
    }
}

private struct GooUniforms {
    var size: SIMD2<Float>
    var scale: Float
    var count: UInt32
    var groupK: Float
    var gooK: Float
    var dim: SIMD4<Float>
    var flat: SIMD4<Float>
    var hasTexture: UInt32
}

/// Draws the timeline's liquid shapes (bubbles on their way into a day, date pills, day circles) on the GPU
/// (Goo.metal). Full screen, in the timeline's coordinates; redrawn whenever `render()` moves anything.
@MainActor
final class GooView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var gradient: MTLTexture?
    private var placeholder: MTLTexture
    private var dim = SIMD4<Float>(0, 0, 0, 0)
    private var flat = SIMD4<Float>(0, 0, 0, 1)

    override init(frame: CGRect) {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let library = device.makeDefaultLibrary()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "gooVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "gooFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
        let placeholderDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        placeholder = device.makeTexture(descriptor: placeholderDescriptor)!
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.presentsWithTransaction = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? 3
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if let pending {
            self.pending = nil
            present(pending.shapes, groupK: pending.groupK, gooK: pending.gooK)
        }
    }

    /// The service material, as Shell's DateHeaderView draws it (ChatMessageDateHeader.swift): the saturated
    /// wallpaper gradient (or Night's flat 0x1f1f1f) under the service dim.
    func setMaterial(_ theme: Theme, gradient image: UIImage?) {
        dim = Self.vector(theme.serviceDim)
        flat = Self.vector(UIColor(rgb: 0x1f1f1f))
        gradient = nil
        if theme.wallpaper.intensity >= 0, let cgImage = image?.cgImage {
            gradient = try? MTKTextureLoader(device: device).newTexture(cgImage: cgImage, options: [.SRGB: false])
        }
    }

    /// Call whenever anything moved. Drawn once per display frame, with the rest of the frame's changes (a pinch
    /// can deliver several updates per frame, and each draw takes a drawable).
    func draw(_ shapes: [GooShape], groupK: CGFloat, gooK: CGFloat) {
        isHidden = shapes.isEmpty
        pending = (shapes, groupK, gooK)
        setNeedsLayout()
    }

    /// Compiles the pipeline and allocates the drawables ahead of the first zoom (about 30 ms otherwise).
    func warmUp() {
        present([GooShape(CGRect(x: -100, y: -100, width: 10, height: 10), radius: 5, group: 0)], groupK: 0, gooK: 0)
    }

    private var pending: (shapes: [GooShape], groupK: CGFloat, gooK: CGFloat)?

    private func present(_ shapes: [GooShape], groupK: CGFloat, gooK: CGFloat) {
        guard !shapes.isEmpty, bounds.width > 0, let drawable = metalLayer.nextDrawable(),
              let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = GooUniforms(
            size: SIMD2(Float(bounds.width), Float(bounds.height)), scale: Float(metalLayer.contentsScale),
            count: UInt32(shapes.count), groupK: Float(groupK), gooK: Float(gooK), dim: dim, flat: flat,
            hasTexture: gradient == nil ? 0 : 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GooUniforms>.stride, index: 0)
        let buffer = shapes.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }
        encoder.setFragmentBuffer(buffer, offset: 0, index: 1)
        encoder.setFragmentTexture(gradient ?? placeholder, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilScheduled()
        drawable.present()
    }

    static func vector(_ color: UIColor) -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), Float(a))
    }
}
