import MetalKit
import PlatoonCore

/// Presents the Amiga canvas with a choice of filters: sharp pixels, smooth, or CRT emulation.
final class MetalRenderer: NSObject, MTKViewDelegate {
    enum Filter: Int, CaseIterable { case sharp = 0, smooth = 1, crt = 2
        var title: String { ["Sharp Pixels", "Smooth", "CRT"][rawValue] } }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let texture: MTLTexture
    let sampler: MTLSamplerState
    var filter: Filter = .sharp
    var aspectCorrect = true      // PAL pixel aspect (4:3 for 320x256)
    var integerScale = false
    var showOverscan = false
    var scanlineStrength: Float = 0.35
    var curvature = true

    /// Source crop in canvas coordinates (hires x, lines).
    var crop: (x: Int, y: Int, w: Int, h: Int) {
        // standard PAL window: DIW $2c81 -> canvas lowres x = 0x21, y = 0x14 ; 320x256 lowres
        showOverscan ? (x: 16, y: 4, w: 720, h: 282) : (x: (0x81 - Chipset.canvasH0) * 2, y: 0x2c - Chipset.canvasV0, w: 640, h: 256)
    }

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Chipset.canvasWidth, height: Chipset.canvasHeight, mipmapped: false)
        td.usage = .shaderRead
        guard let tex = dev.makeTexture(descriptor: td) else { return nil }
        texture = tex
        let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = dev.makeSamplerState(descriptor: sd)!
        do {
            let lib = try dev.makeLibrary(source: MetalRenderer.shaderSource, options: nil)
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "vmain")
            pd.fragmentFunction = lib.makeFunction(name: "fmain")
            pd.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try dev.makeRenderPipelineState(descriptor: pd)
        } catch { NSLog("Metal setup failed: \(error)"); return nil }
        super.init()
    }

    func upload(_ chip: Chipset) {
        texture.replace(region: MTLRegionMake2D(0, 0, Chipset.canvasWidth, Chipset.canvasHeight), mipmapLevel: 0,
                        withBytes: chip.canvas, bytesPerRow: Chipset.canvasWidth * 4)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    struct Uniforms {
        var srcOrigin: SIMD2<Float>; var srcSize: SIMD2<Float>; var texSize: SIMD2<Float>
        var dstOrigin: SIMD2<Float>; var dstSize: SIMD2<Float>; var viewSize: SIMD2<Float>
        var mode: Int32; var scanline: Float; var curvature: Float; var pad: Float = 0
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let vs = view.drawableSize
        let c = crop
        // logical size in lowres pixels: w/2 x h ; PAL pixel aspect ~ 1.0 when shown 320x256 at 4:3 => width scale 1.0667
        let lw = Double(c.w) / 2, lh = Double(c.h)
        let par = aspectCorrect ? (4.0 / 3.0) / (320.0 / 256.0) : 1.0
        let contentW = lw * par, contentH = lh
        var scale = min(Double(vs.width) / contentW, Double(vs.height) / contentH)
        if integerScale && scale >= 1 { scale = floor(scale) }
        let dw = contentW * scale, dh = contentH * scale
        let dx = (Double(vs.width) - dw) / 2, dy = (Double(vs.height) - dh) / 2
        var u = Uniforms(srcOrigin: SIMD2(Float(c.x), Float(c.y)), srcSize: SIMD2(Float(c.w), Float(c.h)),
                         texSize: SIMD2(Float(Chipset.canvasWidth), Float(Chipset.canvasHeight)),
                         dstOrigin: SIMD2(Float(dx), Float(dy)), dstSize: SIMD2(Float(dw), Float(dh)),
                         viewSize: SIMD2(Float(vs.width), Float(vs.height)),
                         mode: Int32(filter.rawValue), scanline: scanlineStrength, curvature: curvature ? 1 : 0)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float2 srcOrigin; float2 srcSize; float2 texSize; float2 dstOrigin; float2 dstSize; float2 viewSize;
               int mode; float scanline; float curvature; float pad; };
    struct V { float4 pos [[position]]; float2 uv; };
    vertex V vmain(uint vid [[vertex_id]], constant U &u [[buffer(0)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 c = corners[vid];
        float2 px = u.dstOrigin + c * u.dstSize;
        V o; o.pos = float4(px.x / u.viewSize.x * 2 - 1, 1 - px.y / u.viewSize.y * 2, 0, 1); o.uv = c; return o;
    }
    // sharp bilinear: nearest-neighbour look without shimmering on non-integer scales
    float2 sharpUV(float2 texel, float2 scale) {
        float2 f = fract(texel), i = floor(texel);
        float2 region = 0.5 - 0.5 / scale;
        float2 off = clamp((f - region) / (1.0 - 2.0 * region), 0.0, 1.0);
        return i + off;
    }
    fragment float4 fmain(V in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        float2 uv = in.uv;
        if (u.mode == 2 && u.curvature > 0) {
            float2 cc = uv * 2 - 1; cc *= 1 + 0.04 * (cc.yx * cc.yx); uv = cc * 0.5 + 0.5;
            if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1) return float4(0,0,0,1);
        }
        // canvas is hires-wide: 2 texels per lowres pixel horizontally
        float2 lowSize = float2(u.srcSize.x * 0.5, u.srcSize.y);
        float2 lp = uv * lowSize;
        float2 scale = u.dstSize / lowSize;
        float4 col;
        if (u.mode == 1) {
            float2 tp = (u.srcOrigin + float2(lp.x * 2, lp.y)) / u.texSize; col = t.sample(s, tp);
        } else {
            float2 sp = sharpUV(lp, scale);
            float2 tp = (u.srcOrigin + float2(sp.x * 2, sp.y)) / u.texSize;
            col = t.sample(s, tp);
        }
        if (u.mode == 2) {
            // scanlines + slot mask + mild bloom
            float yl = fract(lp.y);
            float beam = mix(1.0 - u.scanline, 1.0, exp(-pow((yl - 0.5) * 3.0, 2.0)));
            float3 c = col.rgb;
            float lum = dot(c, float3(0.3, 0.59, 0.11));
            c *= mix(beam, 1.0, lum * 0.5);
            int mx = int(in.pos.x) % 3;
            float3 mask = mx == 0 ? float3(1.0, 0.82, 0.82) : (mx == 1 ? float3(0.82, 1.0, 0.82) : float3(0.82, 0.82, 1.0));
            c *= mask * 1.12;
            float2 vig = in.uv * (1 - in.uv); c *= pow(vig.x * vig.y * 16, 0.12);
            return float4(c, 1);
        }
        return float4(col.rgb, 1);
    }
    """
}
