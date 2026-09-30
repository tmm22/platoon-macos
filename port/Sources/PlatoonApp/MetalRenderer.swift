import MetalKit
import PlatoonCore

/// Presents the Amiga canvas with a choice of filters: sharp pixels, smooth, CRT emulation (with presets, M20)
/// or the MMPX pixel-art upscaler (M19); plus the presentation extras of the [presentation] agent: ambient
/// backdrop (S14), screen shake (S13), night lift (S16), reduced flashing (S17), colour-vision modes and the HUD
/// magnifier (M21), and the compositing of L4 widescreen side columns. Shader source: Video/VideoShaders.swift.
///
/// With every presentation option at its default the image is the same as the original single-pass renderer
/// (the colour pass is skipped, the Classic CRT code is unchanged).
final class MetalRenderer: NSObject, MTKViewDelegate {
    enum Filter: Int, CaseIterable { case sharp = 0, smooth = 1, crt = 2, mmpx = 3
        var title: String { ["Sharp Pixels", "Smooth", "CRT", "Pixel-Art Upscaler (MMPX)"][rawValue] } }

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
    /// Debug: save the next presented frame to this PNG path.
    var capturePath: String?
    /// Debug: called (on a Metal completion thread) with the next presented frame's pixels (0xAARRGGBB, w x h).
    var captureHandler: ((_ pixels: [UInt32], _ width: Int, _ height: Int) -> Void)?
    /// Where the game image was drawn in the last frame, in drawable pixels (origin top-left). Overlays use it.
    /// (Without screen shake: overlays don't shake.)
    private(set) var lastContentRect = CGRect.zero

    /// Presentation settings (Preferences) and the per-frame effect state, set by VideoFX.
    var look = VideoLook()
    var fx = VideoFrameState()
    /// L4 side columns (the renderer composites them; a feature renders them). See Video/SideColumns.swift.
    var columns: SideColumnCompositor { SideColumnCompositor.shared }

    /// Source crop in canvas coordinates (hires x, lines).
    var crop: (x: Int, y: Int, w: Int, h: Int) {
        // Platoon's screens all lie in DIW h $71..$1b1 (the game window/HUD use DIWSTRT $xx71, the text screens
        // are narrower), vertically within the standard PAL lines $2c..$12b -> 320x256 lowres.
        showOverscan ? (x: 16, y: 4, w: 720, h: 282) : (x: (0x71 - Chipset.canvasH0) * 2, y: 0x2c - Chipset.canvasV0, w: 640, h: 256)
    }

    // extra pipelines and textures of the presentation passes
    private let colourPipeline: MTLRenderPipelineState
    private let mmpxPipeline: MTLRenderPipelineState
    private let glowPipeline: MTLRenderPipelineState
    private let backdropPipeline: MTLRenderPipelineState
    private let columnsPipeline: MTLRenderPipelineState
    private let tintPipeline: MTLRenderPipelineState
    private let nearest: MTLSamplerState
    private var colourTex: [MTLTexture] = []
    private var colourIndex = 0
    private var colourValid = false
    private let lutTex: MTLTexture
    private let refTex: MTLTexture          // S17: canvas of the last frame before a flash
    private var refValid = false
    private let mmpxTex: MTLTexture
    private var glowTex: [MTLTexture] = []
    private var glowIndex = 0
    private var glowValid = false
    private var pendingFrames = 1       // emulated frames uploaded since the passes last ran
    private var lastLook = VideoLook()
    private var lastFilter = Filter.sharp
    private var lastLutGeneration = -1
    static let glowSize = (w: 48, h: 36)

    init?(view: MTKView) {
        guard let dev = view.device ?? MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        device = dev; queue = q
        view.device = dev
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        func tex(_ w: Int, _ h: Int, target: Bool) -> MTLTexture? {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            td.usage = target ? [.shaderRead, .renderTarget] : .shaderRead
            if target { td.storageMode = .private }
            return dev.makeTexture(descriptor: td)
        }
        guard let tx = tex(Chipset.canvasWidth, Chipset.canvasHeight, target: false),
              let c0 = tex(Chipset.canvasWidth, Chipset.canvasHeight, target: true),
              let c1 = tex(Chipset.canvasWidth, Chipset.canvasHeight, target: true),
              let lut = tex(64, 64, target: false),
              let ref = tex(Chipset.canvasWidth, Chipset.canvasHeight, target: false),
              let mm = tex(Chipset.canvasWidth, Chipset.canvasHeight * 2, target: true),
              let g0 = tex(MetalRenderer.glowSize.w, MetalRenderer.glowSize.h, target: true),
              let g1 = tex(MetalRenderer.glowSize.w, MetalRenderer.glowSize.h, target: true) else { return nil }
        texture = tx; colourTex = [c0, c1]; lutTex = lut; refTex = ref; mmpxTex = mm; glowTex = [g0, g1]
        let sd = MTLSamplerDescriptor(); sd.minFilter = .linear; sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = dev.makeSamplerState(descriptor: sd)!
        let nd = MTLSamplerDescriptor(); nd.minFilter = .nearest; nd.magFilter = .nearest
        nd.sAddressMode = .clampToEdge; nd.tAddressMode = .clampToEdge
        nearest = dev.makeSamplerState(descriptor: nd)!
        do {
            let lib = try dev.makeLibrary(source: VideoShaders.source, options: nil)
            func make(_ v: String, _ f: String, blend: Bool = false) throws -> MTLRenderPipelineState {
                let pd = MTLRenderPipelineDescriptor()
                pd.vertexFunction = lib.makeFunction(name: v)
                pd.fragmentFunction = lib.makeFunction(name: f)
                pd.colorAttachments[0].pixelFormat = .bgra8Unorm
                if blend {
                    let a = pd.colorAttachments[0]!
                    a.isBlendingEnabled = true
                    a.sourceRGBBlendFactor = .sourceAlpha; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try dev.makeRenderPipelineState(descriptor: pd)
            }
            pipeline = try make("vmain", "fmain")
            colourPipeline = try make("vfull", "fcolour")
            mmpxPipeline = try make("vfull", "fmmpx")
            glowPipeline = try make("vfull", "fglow")
            backdropPipeline = try make("vfull", "fbackdrop")
            columnsPipeline = try make("vcol", "fcolumns", blend: true)
            tintPipeline = try make("vfull", "ftint", blend: true)
        } catch { NSLog("Metal setup failed: \(error)"); return nil }
        super.init()
        uploadLUT(VideoFX.identityLUT)
    }

    func upload(_ chip: Chipset) {
        texture.replace(region: MTLRegionMake2D(0, 0, Chipset.canvasWidth, Chipset.canvasHeight), mipmapLevel: 0,
                        withBytes: chip.canvas, bytesPerRow: Chipset.canvasWidth * 4)
        if fx.refUpdate {
            refTex.replace(region: MTLRegionMake2D(0, 0, Chipset.canvasWidth, Chipset.canvasHeight), mipmapLevel: 0,
                           withBytes: chip.canvas, bytesPerRow: Chipset.canvasWidth * 4)
            refValid = true
        }
        pendingFrames += max(1, fx.framesSinceUpload)
        fx.framesSinceUpload = 0
    }

    private func uploadLUT(_ lut: [UInt32]) {
        lut.withUnsafeBytes { lutTex.replace(region: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 64 * 4) }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    struct Uniforms {
        var srcOrigin: SIMD2<Float>; var srcSize: SIMD2<Float>; var texSize: SIMD2<Float>
        var dstOrigin: SIMD2<Float>; var dstSize: SIMD2<Float>; var viewSize: SIMD2<Float>
        var grid: SIMD2<Float>
        var mode: Int32; var scanline: Float; var curvature: Float; var flags: Int32
        var crtClassic: Int32 = 1; var maskType: Int32 = 0; var maskStrength: Float = 0; var bloom: Float = 0
        var sharpness: Float = 1; var triads: Float = 0; var pad0: Float = 0; var pad1: Float = 0
    }
    struct ColourUniforms {
        var useLut: Int32; var splitY: Int32; var night: Float; var cvd: Int32
        var cvdStrength: Float; var bleed: Float; var colour1084: Int32; var decay: Float
        var hasPrev: Int32; var nightAll: Int32; var usePal: Int32 = 0; var pad1: Float = 0
    }
    struct GlowUniforms { var srcOrigin: SIMD2<Float>; var srcSize: SIMD2<Float>; var texSize: SIMD2<Float>; var blend: Float; var hasPrev: Int32 }
    struct BackdropUniforms { var gameOrigin: SIMD2<Float>; var gameSize: SIMD2<Float>; var viewSize: SIMD2<Float>; var brightness: Float; var zoom: Float
        // border fill (mode 1): the game image rect (shaken) and its canvas source, the inner x range to leave alone
        var imgOrigin = SIMD2<Float>(0, 0); var imgSize = SIMD2<Float>(0, 0); var srcOrigin = SIMD2<Float>(0, 0); var srcSize = SIMD2<Float>(0, 0)
        var innerX = SIMD2<Float>(0, 0); var mode: Int32 = 0; var pad: Float = 0 }
    struct ColumnUniforms { var dstOrigin: SIMD2<Float>; var dstSize: SIMD2<Float>; var viewSize: SIMD2<Float>; var texSize: SIMD2<Float>
        var fog: Float; var side: Int32; var alpha: Float; var pad: Float = 0 }
    struct TintUniforms { var viewSize: SIMD2<Float>; var amount: Float; var pad: Float = 0 }

    // MARK: layout

    /// Where everything goes in a drawable of size `vs` (drawable pixels, origin top-left).
    struct Layout {
        /// The game image (unshaken).
        var game: CGRect
        /// Drawable pixels per lowres pixel (x includes the PAL aspect).
        var scaleX: Double, scaleY: Double
        /// M21 HUD magnifier strip, if enabled.
        var magnifier: CGRect?
    }

    /// Lines of the HUD shown by the magnifier (canvas lines from the split line).
    static let hudLines = 56

    func layout(drawableSize vs: CGSize) -> Layout {
        let c = crop
        // logical size in lowres pixels: w/2 x h ; PAL pixel aspect ~ 1.0 when shown 320x256 at 4:3 => width scale 1.0667
        let lw = Double(c.w) / 2, lh = Double(c.h)
        let par = aspectCorrect ? (4.0 / 3.0) / (320.0 / 256.0) : 1.0
        let side = Double(columns.reservedWidth)                    // L4: lowres px reserved beside the crop
        let contentW = (lw + 2 * side) * par, contentH = lh
        let mag = look.hudMagnifier ? Double(max(1, look.hudMagnification)) : 0
        let hud = Double(MetalRenderer.hudLines)
        let needW = max(contentW, mag > 0 ? lw * par * mag : 0)
        let needH = contentH + hud * mag
        var scale = min(Double(vs.width) / needW, Double(vs.height) / needH)
        if integerScale && scale >= 1 { scale = floor(scale) }
        let gw = lw * par * scale, gh = lh * scale
        let totalH = needH * scale
        let dy = (Double(vs.height) - totalH) / 2
        let game = CGRect(x: (Double(vs.width) - gw) / 2, y: dy, width: gw, height: gh)
        var strip: CGRect?
        if mag > 0 {
            let sw = lw * par * scale * mag, sh = hud * scale * mag
            strip = CGRect(x: (Double(vs.width) - sw) / 2, y: dy + gh, width: sw, height: sh)
        }
        return Layout(game: game, scaleX: par * scale, scaleY: scale, magnifier: strip)
    }

    /// The rect (drawable pixels, origin top-left) the game image occupies for a drawable of size `vs`.
    func contentRect(drawableSize vs: CGSize) -> CGRect { layout(drawableSize: vs).game }

    // MARK: drawing

    private var colourPassNeeded: Bool {
        fx.flashLUT != nil || fx.night > 0 || look.colourVision != .off
            || (filter == .crt && look.crtPreset != .classic && (look.crt.bleed > 0 || look.crt.colour1084 || look.crt.persistence > 0))
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let vs = view.drawableSize
        // M20: optional colour management (untagged = the Amiga values go to the display as they are)
        if let layer = view.layer as? CAMetalLayer, look.srgbTag != (layer.colorspace != nil) {
            layer.colorspace = look.srgbTag ? CGColorSpace(name: CGColorSpace.sRGB) : nil
        }
        guard let lay = encode(cb, rpd, drawableSize: vs) else { return }
        lastContentRect = lay.game
        cb.present(drawable)
        if capturePath != nil || captureHandler != nil {
            let path = capturePath, handler = captureHandler
            capturePath = nil; captureHandler = nil
            let tex = drawable.texture
            cb.addCompletedHandler { _ in
                let w = tex.width, h = tex.height
                var buf = [UInt32](repeating: 0, count: w * h)
                tex.getBytes(&buf, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                if let path {
                    let png = ImageIO.png(width: w, height: h) { x, y in let p = buf[y * w + x]; return p } // BGRA little-endian -> 0xAARRGGBB
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                handler?(buf, w, h)
            }
        }
        cb.commit()
    }

    /// Renders the current canvas / settings into an offscreen image of `width` x `height` drawable pixels and
    /// returns its pixels (0xAARRGGBB, row-major). Synchronous; for tests (Video/VideoSelfTest.swift) and tools.
    /// `frames` = emulated frames to account for since the previous render (persistence / glow history).
    func renderOffscreen(width: Int, height: Int, frames: Int = 1) -> [UInt32]? {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .managed
        guard let target = device.makeTexture(descriptor: td), let cb = queue.makeCommandBuffer() else { return nil }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        pendingFrames += max(0, frames - 1)
        guard encode(cb, rpd, drawableSize: CGSize(width: width, height: height)) != nil else { return nil }
        if let blit = cb.makeBlitCommandEncoder() { blit.synchronize(resource: target); blit.endEncoding() }
        cb.commit()
        cb.waitUntilCompleted()
        var buf = [UInt32](repeating: 0, count: width * height)
        target.getBytes(&buf, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return buf
    }

    /// Uploads a canvas-sized image (Chipset.canvasWidth x canvasHeight, 0xAARRGGBB) instead of the chipset's
    /// canvas (tests / tools).
    func upload(pixels: UnsafePointer<UInt32>) {
        texture.replace(region: MTLRegionMake2D(0, 0, Chipset.canvasWidth, Chipset.canvasHeight), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: Chipset.canvasWidth * 4)
        if fx.refUpdate {
            refTex.replace(region: MTLRegionMake2D(0, 0, Chipset.canvasWidth, Chipset.canvasHeight), mipmapLevel: 0,
                           withBytes: pixels, bytesPerRow: Chipset.canvasWidth * 4)
            refValid = true
        }
        pendingFrames += 1
    }

    /// Encodes all passes of one displayed frame into `cb`; the final pass renders into `rpd`.
    private func encode(_ cb: MTLCommandBuffer, _ rpd: MTLRenderPassDescriptor, drawableSize vs: CGSize) -> Layout? {
        let c = crop
        let lay = layout(drawableSize: vs)
        let r = lay.game

        // settings changes invalidate the history textures
        let settingsChanged = look != lastLook || filter != lastFilter
        if settingsChanged { colourValid = false; glowValid = false; lastLook = look; lastFilter = filter }
        let newFrame = pendingFrames > 0 || settingsChanged
        let frames = pendingFrames
        pendingFrames = 0

        // ---- colour pass
        var source = texture
        if colourPassNeeded {
            if let lut = fx.flashLUT, fx.flashLUTGeneration != lastLutGeneration { uploadLUT(lut); lastLutGeneration = fx.flashLUTGeneration }
            if newFrame || !colourValid {
                let prev = colourTex[colourIndex]
                colourIndex ^= 1
                let dst = colourTex[colourIndex]
                let crt = filter == .crt && look.crtPreset != .classic
                let persistence = crt ? look.crt.persistence : 0
                var u = ColourUniforms(useLut: fx.flashLUT != nil ? 1 : 0, splitY: Int32(fx.splitCanvasY), night: fx.night,
                                       cvd: Int32(look.colourVision.rawValue), cvdStrength: look.colourVisionStrength,
                                       bleed: crt ? look.crt.bleed : 0, colour1084: crt && look.crt.colour1084 ? 1 : 0,
                                       decay: persistence > 0 ? powf(persistence, Float(max(1, frames))) : 0,
                                       hasPrev: colourValid ? 1 : 0, nightAll: 0)
                var pals = [UInt32](repeating: 0, count: 48)
                if let p = fx.flashPalettes, p.count == 48, fx.flashLUT != nil, refValid {
                    for i in 0..<48 { pals[i] = UInt32(p[i]) }
                    u.usePal = 1
                }
                offscreen(cb, dst) { enc in
                    enc.setRenderPipelineState(colourPipeline)
                    enc.setFragmentBytes(&u, length: MemoryLayout<ColourUniforms>.stride, index: 0)
                    pals.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
                    enc.setFragmentTexture(texture, index: 0)
                    enc.setFragmentTexture(lutTex, index: 1)
                    enc.setFragmentTexture(prev, index: 2)
                    enc.setFragmentTexture(refTex, index: 3)
                }
                colourValid = true
            }
            source = colourTex[colourIndex]
        } else {
            colourValid = false
        }

        // ---- MMPX
        var srcTex = source
        var srcOrigin = SIMD2(Float(c.x), Float(c.y)), srcSize = SIMD2(Float(c.w), Float(c.h))
        var grid = SIMD2(Float(c.w) / 2, Float(c.h))     // sampling grid: lowres pixels (2 x 1 canvas texels each)
        var mode = filter.rawValue
        if filter == .mmpx {
            if newFrame || colourPassNeeded {
                var u = SIMD2<Int32>(Int32(Chipset.canvasWidth / 2), Int32(Chipset.canvasHeight))
                offscreen(cb, mmpxTex) { enc in
                    enc.setRenderPipelineState(mmpxPipeline)
                    enc.setFragmentBytes(&u, length: MemoryLayout<SIMD2<Int32>>.stride, index: 0)
                    enc.setFragmentTexture(source, index: 0)
                }
            }
            srcTex = mmpxTex
            srcOrigin = SIMD2(Float(c.x), Float(c.y * 2)); srcSize = SIMD2(Float(c.w), Float(c.h * 2))
            grid = srcSize                                // MMPX output: sample its own (2x lowres) texels sharply
            mode = 3
        }

        // ---- ambient backdrop blur (S14)
        let backdrop = look.backdrop == 1
        if backdrop && (newFrame || !glowValid) {
            let prev = glowTex[glowIndex]
            glowIndex ^= 1
            // every game screen has a black 16-px border inside the $71 crop (the windows start at DIW h $81):
            // the glow is taken from inside it, so the picture's edges extend into the bars
            let bx = min(32, c.w / 4)
            var u = GlowUniforms(srcOrigin: SIMD2(Float(c.x + bx), Float(c.y)), srcSize: SIMD2(Float(c.w - 2 * bx), Float(c.h)),
                                 texSize: SIMD2(Float(Chipset.canvasWidth), Float(Chipset.canvasHeight)),
                                 blend: glowValid ? 1 - powf(0.82, Float(max(1, frames))) : 1, hasPrev: glowValid ? 1 : 0)
            offscreen(cb, glowTex[glowIndex]) { enc in
                enc.setRenderPipelineState(glowPipeline)
                enc.setFragmentBytes(&u, length: MemoryLayout<GlowUniforms>.stride, index: 0)
                enc.setFragmentTexture(source, index: 0)
                enc.setFragmentTexture(prev, index: 1)
                enc.setFragmentSamplerState(sampler, index: 0)
            }
            glowValid = true
        } else if !backdrop { glowValid = false }

        // ---- the drawable
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        let viewSize = SIMD2(Float(vs.width), Float(vs.height))
        let inner = r.insetBy(dx: Double(min(32, c.w / 4)) / 2 * lay.scaleX, dy: 0)
        var backdropU = BackdropUniforms(gameOrigin: SIMD2(Float(inner.minX), Float(inner.minY)), gameSize: SIMD2(Float(inner.width), Float(inner.height)),
                                         viewSize: viewSize, brightness: look.backdropBrightness, zoom: 1.12)
        if backdrop {
            var u = backdropU
            enc.setRenderPipelineState(backdropPipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<BackdropUniforms>.stride, index: 0)
            enc.setFragmentTexture(glowTex[glowIndex], index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // S13: shake offset in whole lowres pixels
        let sx = Double(fx.shake.x) * lay.scaleX, sy = Double(fx.shake.y) * lay.scaleY
        let crt = filter == .crt
        let p = look.crt
        let classic = !crt || look.crtPreset == .classic
        let triads = Float(max(1, floor(lay.scaleX / 3)))
        func mainUniforms(src: SIMD2<Float>, size: SIMD2<Float>, grid g: SIMD2<Float>, dst: CGRect, flags: Int32, curvature cv: Bool) -> Uniforms {
            Uniforms(srcOrigin: src, srcSize: size, texSize: SIMD2(Float(srcTex.width), Float(srcTex.height)),
                     dstOrigin: SIMD2(Float(dst.minX), Float(dst.minY)), dstSize: SIMD2(Float(dst.width), Float(dst.height)),
                     viewSize: viewSize, grid: g, mode: Int32(mode), scanline: classic ? scanlineStrength : p.scanline,
                     curvature: cv ? 1 : 0, flags: flags,
                     crtClassic: classic ? 1 : 0, maskType: Int32(p.mask.rawValue),
                     maskStrength: lay.scaleX / Double(triads) >= 2.5 ? p.maskStrength : 0,
                     bloom: p.bloom, sharpness: p.sharpness, triads: triads)
        }
        var u = mainUniforms(src: srcOrigin, size: srcSize, grid: grid, dst: r.offsetBy(dx: sx, dy: sy), flags: 1, curvature: curvature)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(srcTex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // S14: the glow also fills the black border columns inside the crop (every screen has 16 px of border
        // colour beside its window), so it reaches the picture's edge; only where the border is black
        if backdrop && filter != .crt {
            let g = r.offsetBy(dx: sx, dy: sy)
            backdropU.imgOrigin = SIMD2(Float(g.minX), Float(g.minY)); backdropU.imgSize = SIMD2(Float(g.width), Float(g.height))
            backdropU.srcOrigin = SIMD2(Float(c.x), Float(c.y)); backdropU.srcSize = SIMD2(Float(c.w), Float(c.h))
            backdropU.innerX = SIMD2(Float(inner.minX + sx), Float(inner.maxX + sx)); backdropU.mode = 1
            enc.setRenderPipelineState(backdropPipeline)
            enc.setFragmentBytes(&backdropU, length: MemoryLayout<BackdropUniforms>.stride, index: 0)
            enc.setFragmentTexture(glowTex[glowIndex], index: 0)
            enc.setFragmentTexture(source, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // L4 side columns, blended over the crop's black border beside the game window and the area outside it
        drawColumns(enc, lay, viewSize, shake: CGPoint(x: sx, y: sy))
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(srcTex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)

        // M21 HUD magnifier: the HUD lines again, magnified, below the game image
        if let strip = lay.magnifier, fx.hudActive {
            let hudY = max(c.y, min(fx.splitCanvasY, c.y + c.h - MetalRenderer.hudLines))
            let yScale: Float = filter == .mmpx ? 2 : 1
            var m = mainUniforms(src: SIMD2(srcOrigin.x, Float(hudY) * yScale), size: SIMD2(srcSize.x, Float(MetalRenderer.hudLines) * yScale),
                                 grid: SIMD2(grid.x, Float(MetalRenderer.hudLines) * yScale), dst: strip, flags: 0, curvature: false)
            enc.setVertexBytes(&m, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&m, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // S13 hit edge tint
        if fx.tint > 0.004 {
            var t = TintUniforms(viewSize: viewSize, amount: fx.tint)
            enc.setRenderPipelineState(tintPipeline)
            enc.setFragmentBytes(&t, length: MemoryLayout<TintUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        enc.endEncoding()
        return lay
    }

    /// Runs one full-target fragment pass into `target`.
    private func offscreen(_ cb: MTLCommandBuffer, _ target: MTLTexture, _ setup: (MTLRenderCommandEncoder) -> Void) {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = target
        d.colorAttachments[0].loadAction = .dontCare
        d.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: d) else { return }
        setup(enc)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    private func drawColumns(_ enc: MTLRenderCommandEncoder, _ lay: Layout, _ viewSize: SIMD2<Float>, shake: CGPoint) {
        let c = crop
        columns.geometry = .init(gameMinX: Double(lay.game.minX), drawableWidth: Double(viewSize.x), scaleX: lay.scaleX, cropLeftLow: Double(c.x) / 2)
        guard let frame = columns.current, let tex = columns.texture(device: device) else { return }
        let leftLow = Double(c.x) / 2                                   // canvas lowres x of the crop's left edge
        let g = lay.game.offsetBy(dx: shake.x, dy: shake.y)
        func rect(lowX: Double, width: Double) -> CGRect {
            CGRect(x: g.minX + (lowX - leftLow) * lay.scaleX, y: g.minY + Double(frame.firstLine - c.y) * lay.scaleY,
                   width: width * lay.scaleX, height: Double(frame.lines) * lay.scaleY)
        }
        enc.setRenderPipelineState(columnsPipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        for side in 0..<2 {
            let w = Double(side == 0 ? frame.width : frame.rightWidth ?? frame.width)
            if w <= 0 { continue }
            let x = side == 0 ? Double(frame.leftEdge) - w : Double(frame.rightEdge)
            let dst = rect(lowX: x, width: w)
            var u = ColumnUniforms(dstOrigin: SIMD2(Float(dst.minX), Float(dst.minY)), dstSize: SIMD2(Float(dst.width), Float(dst.height)),
                                   viewSize: viewSize, texSize: SIMD2(Float(w), Float(frame.lines)),
                                   fog: frame.fog, side: Int32(side), alpha: frame.alpha)
            enc.setVertexBytes(&u, length: MemoryLayout<ColumnUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<ColumnUniforms>.stride, index: 0)
            enc.setFragmentTexture(tex[side], index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }
}
