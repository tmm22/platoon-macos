// OWNER: [presentation]. Metal shader source of the renderer (compiled at launch with makeLibrary(source:)).
//
// Passes (MetalRenderer.draw):
//   fcolour   canvas -> colour texture (768x290): S17 flash-limiter LUT, S16 night lift, M21 colour vision,
//             M20 composite bleed / 1084 colour / phosphor persistence. Skipped when nothing is enabled.
//   fmmpx     source -> 2x texture (768x580): M19 MMPX pixel-art magnification (McGuire & Gagiu 2021).
//   fglow     source crop -> small blurred texture (S14 ambient backdrop), temporally smoothed.
//   fbackdrop drawable: the ambient backdrop behind the game image.
//   fmain     drawable: the game image (sharp / smooth / CRT / MMPX), also the HUD magnifier strip (M21).
//   fcolumns  drawable, blended: L4 widescreen side columns.
//   ftint     drawable, blended: S13 hit edge tint.
//
// Struct layouts must match the Swift structs in MetalRenderer.swift (only float/int scalars and float2).

enum VideoShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // ---------------------------------------------------------------- shared
    struct V { float4 pos [[position]]; float2 uv; };
    vertex V vfull(uint vid [[vertex_id]]) {
        float2 c[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        V o; o.pos = float4(c[vid].x * 2 - 1, 1 - c[vid].y * 2, 0, 1); o.uv = c[vid]; return o;
    }
    struct QU { float2 dstOrigin; float2 dstSize; float2 viewSize; };
    vertex V vquad(uint vid [[vertex_id]], constant QU &u [[buffer(0)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 c = corners[vid];
        float2 px = u.dstOrigin + c * u.dstSize;
        V o; o.pos = float4(px.x / u.viewSize.x * 2 - 1, 1 - px.y / u.viewSize.y * 2, 0, 1); o.uv = c; return o;
    }
    static float3 toLinear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
    static float3 toSRGB(float3 c) { c = saturate(c); return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }

    // ---------------------------------------------------------------- colour pass
    struct CU {
        int useLut; int splitY; float night; int cvd;
        float cvdStrength; float bleed; int colour1084; float decay;
        int hasPrev; int nightAll; int usePal; float pad1;
    };
    static float4 lutc(float4 c, texture2d<float> lut) {
        uint3 n = uint3(round(saturate(c.rgb) * 15.0));
        uint idx = (n.r << 8) | (n.g << 4) | n.b;
        return float4(lut.read(uint2(idx & 63, idx >> 6)).rgb, 1);
    }
    static float3 cvdSim(float3 l, int kind) {
        // Machado, Oliveira & Fernandes 2009, severity 1.0 (linear RGB)
        float3x3 m;
        if (kind == 2)      m = float3x3(float3(0.152286, 0.114503, -0.003882), float3(1.052583, 0.786281, -0.048116), float3(-0.204868, 0.099216, 1.051998));
        else if (kind == 3) m = float3x3(float3(1.255528, -0.078411, 0.004733), float3(-0.076749, 0.930809, 0.691367), float3(-0.178779, 0.147602, 0.303900));
        else                m = float3x3(float3(0.367322, 0.280085, -0.011820), float3(0.860646, 0.672501, 0.042940), float3(-0.227968, 0.047413, 0.968881));
        return m * l;
    }
    static float3 cvdApply(float3 c, int mode, float k) {
        if (mode == 0) return c;
        float3 l = toLinear(c);
        if (mode == 7) { float y = dot(l, float3(0.2126, 0.7152, 0.0722)); return toSRGB(mix(l, float3(y), k)); }
        int kind = mode <= 3 ? mode : mode - 3;   // 1 deutan 2 protan 3 tritan
        float3 s = cvdSim(l, kind);
        if (mode >= 4) return toSRGB(mix(l, s, k));
        // daltonise: move the error the viewer can't see into channels they can
        float3 e = l - s;
        float3 d;
        if (kind == 3) d = float3(e.r * 0.0 + e.b * 0.7, e.g + e.b * 0.7, 0.0);
        else           d = float3(0.0, e.r * 0.7 + e.g, e.r * 0.7 + e.b);
        return toSRGB(l + d * k);
    }
    static uint c12(float4 c) { uint3 n = uint3(round(saturate(c.rgb) * 15.0)); return (n.r << 8) | (n.g << 4) | n.b; }
    static float4 rgb12(uint v) { return float4(float((v >> 8) & 15), float((v >> 4) & 15), float(v & 15), 15.0) / 15.0; }
    // pals: [0..15] reference palette (of `ref`), [16..31] current top palette, [32..47] limited palette
    static float4 fetchColour(texture2d<float> t, texture2d<float> lut, texture2d<float> ref, constant uint *pals,
                              constant CU &u, int2 p) {
        int2 q = clamp(p, int2(0), int2(t.get_width() - 1, t.get_height() - 1));
        float4 c = t.read(uint2(q));
        bool top = q.y < u.splitY;
        if (u.useLut != 0 && top) {
            bool done = false;
            if (u.usePal != 0) {
                // S17: the pixel's palette index from the reference frame; used when the pixel still shows that
                // index's current colour (the picture didn't change there since)
                uint rc = c12(ref.read(uint2(q))), cc = c12(c);
                for (int i = 0; i < 16; i++) {
                    if (pals[i] == rc) {
                        if (pals[16 + i] == cc) { c = rgb12(pals[32 + i]); done = true; }
                        break;
                    }
                }
            }
            if (!done) c = lutc(c, lut);
        }
        if (u.night > 0 && (top || u.nightAll != 0)) c.rgb = pow(c.rgb, float3(1.0 / (1.0 + 1.6 * u.night)));
        c.rgb = cvdApply(c.rgb, u.cvd, u.cvdStrength);
        return c;
    }
    fragment float4 fcolour(V in [[stage_in]], constant CU &u [[buffer(0)]], constant uint *pals [[buffer(1)]],
                            texture2d<float> t [[texture(0)]], texture2d<float> lut [[texture(1)]],
                            texture2d<float> prev [[texture(2)]], texture2d<float> ref [[texture(3)]]) {
        int2 p = int2(in.pos.xy);
        float4 c = fetchColour(t, lut, ref, pals, u, p);
        if (u.bleed > 0) {
            // composite: chroma (YIQ I/Q) smeared over a few lowres pixels, luma slightly soft
            const float3x3 toYIQ = float3x3(float3(0.299, 0.596, 0.211), float3(0.587, -0.274, -0.523), float3(0.114, -0.322, 0.312));
            const float3x3 toRGB = float3x3(float3(1.0, 1.0, 1.0), float3(0.956, -0.272, -1.106), float3(0.621, -0.647, 1.703));
            float3 yiq = float3(0), wsum = float3(0);
            float sc = max(0.35, 2.2 * u.bleed), sy = 0.25 + 0.5 * u.bleed;
            for (int k = -4; k <= 4; k++) {
                float3 s = toYIQ * fetchColour(t, lut, ref, pals, u, p + int2(2 * k, 0)).rgb;
                float wc = exp(-float(k * k) / (2.0 * sc * sc)), wy = exp(-float(k * k) / (2.0 * sy * sy));
                float3 w = float3(wy, wc, wc);
                yiq += s * w; wsum += w;
            }
            c.rgb = saturate(toRGB * (yiq / wsum));
        }
        if (u.colour1084 != 0) {
            // 1084S/PAL look: a little more gamma than sRGB, warmer whites, slightly richer colours
            float3 g = pow(c.rgb, float3(1.12));
            float y = dot(g, float3(0.299, 0.587, 0.114));
            c.rgb = saturate(mix(float3(y), g, 1.08) * float3(1.0, 0.985, 0.94));
        }
        if (u.hasPrev != 0 && u.decay > 0) c.rgb = max(c.rgb, prev.read(uint2(p)).rgb * u.decay);
        return float4(c.rgb, 1);
    }

    // ---------------------------------------------------------------- MMPX (M19)
    // splitY: first canvas line of the HUD kept sharp (M19 option), or the texture height = none. Rows above it
    // never look at the HUD rows (the game window's last line isn't smoothed against the status bar).
    struct MU { int2 lowSize; int splitY; int pad; };
    static uint pk(float4 c) { uint3 v = uint3(round(saturate(c.rgb) * 255.0)); return (v.r << 16) | (v.g << 8) | v.b; }
    static uint SRCP(texture2d<float> t, int2 sz, int x, int y) {
        x = clamp(x, 0, sz.x - 1); y = clamp(y, 0, sz.y - 1);
        return pk(t.read(uint2(x * 2, y)));
    }
    static uint luma(uint c) { return ((c >> 16) & 255) + ((c >> 8) & 255) + (c & 255) + 1; }
    static bool all2(uint b, uint a0, uint a1) { return b == a0 && b == a1; }
    static bool all3(uint b, uint a0, uint a1, uint a2) { return b == a0 && b == a1 && b == a2; }
    static bool all4(uint b, uint a0, uint a1, uint a2, uint a3) { return b == a0 && b == a1 && b == a2 && b == a3; }
    static bool any3(uint b, uint a0, uint a1, uint a2) { return b == a0 || b == a1 || b == a2; }
    static bool none2(uint b, uint a0, uint a1) { return b != a0 && b != a1; }
    static bool none4(uint b, uint a0, uint a1, uint a2, uint a3) { return b != a0 && b != a1 && b != a2 && b != a3; }
    fragment float4 fmmpx(V in [[stage_in]], constant MU &u [[buffer(0)]], texture2d<float> t [[texture(0)]]) {
        int2 o = int2(in.pos.xy);
        int sx = o.x >> 1, sy = o.y >> 1;
        if (sy >= u.splitY) { uint e = SRCP(t, u.lowSize, sx, sy); return float4(float((e >> 16) & 255), float((e >> 8) & 255), float(e & 255), 255.0) / 255.0; }
        int2 lim = int2(u.lowSize.x, min(u.lowSize.y, u.splitY));
        #define S(dx, dy) SRCP(t, lim, sx + (dx), sy + (dy))
        uint A = S(-1,-1), B = S(0,-1), C = S(1,-1), D = S(-1,0), E = S(0,0), F = S(1,0), G = S(-1,1), H = S(0,1), I = S(1,1);
        uint J = E, K = E, L = E, M = E;
        if (((A ^ E) | (B ^ E) | (C ^ E) | (D ^ E) | (F ^ E) | (G ^ E) | (H ^ E) | (I ^ E)) != 0) {
            uint P = S(0,-2), Sb = S(0,2), Q = S(-2,0), R = S(2,0);
            uint Bl = luma(B), Dl = luma(D), El = luma(E), Fl = luma(F), Hl = luma(H);
            // 1:1 slope rules
            if ((D == B && D != H && D != F) && (El >= Dl || E == A) && any3(E, A, C, G) && ((El < Dl) || A != D || E != P || E != Q)) J = D;
            if ((B == F && B != D && B != H) && (El >= Bl || E == C) && any3(E, A, C, I) && ((El < Bl) || C != B || E != P || E != R)) K = B;
            if ((H == D && H != F && H != B) && (El >= Hl || E == G) && any3(E, A, G, I) && ((El < Hl) || G != H || E != Sb || E != Q)) L = H;
            if ((F == H && F != B && F != D) && (El >= Fl || E == I) && any3(E, C, G, I) && ((El < Fl) || I != H || E != R || E != Sb)) M = F;
            // intersection rules
            if ((E != F && all4(E, C, I, D, Q) && all2(F, B, H)) && (F != S(3,0))) { K = F; M = F; }
            if ((E != D && all4(E, A, G, F, R) && all2(D, B, H)) && (D != S(-3,0))) { J = D; L = D; }
            if ((E != H && all4(E, G, I, B, P) && all2(H, D, F)) && (H != S(0,3))) { L = H; M = H; }
            if ((E != B && all4(E, A, C, H, Sb) && all2(B, D, F)) && (B != S(0,-3))) { J = B; K = B; }
            // 2:1 slope rules
            if (Bl < El && all4(E, G, H, I, Sb) && none4(E, A, D, C, F)) { J = B; K = B; }
            if (Hl < El && all4(E, A, B, C, P) && none4(E, D, G, I, F)) { L = H; M = H; }
            if (Fl < El && all4(E, A, D, G, Q) && none4(E, B, C, I, H)) { K = F; M = F; }
            if (Dl < El && all4(E, C, F, I, R) && none4(E, B, A, G, H)) { J = D; L = D; }
            // 3:1 slope rules
            if (H != B) {
                if (H != A && H != E && H != C) {
                    if (all3(H, G, F, R) && none2(H, D, S(2,-1))) L = M;
                    if (all3(H, I, D, Q) && none2(H, F, S(-2,-1))) M = L;
                }
                if (B != I && B != G && B != E) {
                    if (all3(B, A, F, R) && none2(B, D, S(2,1))) J = K;
                    if (all3(B, C, D, Q) && none2(B, F, S(-2,1))) K = J;
                }
            }
            if (F != D) {
                if (D != I && D != E && D != C) {
                    if (all3(D, A, H, Sb) && none2(D, B, S(1,2))) J = L;
                    if (all3(D, G, B, P) && none2(D, H, S(1,-2))) L = J;
                }
                if (F != E && F != A && F != G) {
                    if (all3(F, C, H, Sb) && none2(F, B, S(-1,2))) K = M;
                    if (all3(F, I, B, P) && none2(F, H, S(-1,-2))) M = K;
                }
            }
        }
        #undef S
        int q = (o.x & 1) | ((o.y & 1) << 1);
        uint r = q == 0 ? J : q == 1 ? K : q == 2 ? L : M;
        return float4(float((r >> 16) & 255), float((r >> 8) & 255), float(r & 255), 255.0) / 255.0;
    }

    // ---------------------------------------------------------------- ambient backdrop (S14)
    struct GU { float2 srcOrigin; float2 srcSize; float2 texSize; float blend; int hasPrev; };
    fragment float4 fglow(V in [[stage_in]], constant GU &u [[buffer(0)]], texture2d<float> t [[texture(0)]],
                          texture2d<float> prev [[texture(1)]], sampler s [[sampler(0)]]) {
        float2 gs = float2(prev.get_width(), prev.get_height());
        float2 cell = u.srcSize / gs;
        float2 base = u.srcOrigin + floor(in.pos.xy) * cell;
        float3 acc = float3(0);
        for (int j = 0; j < 4; j++) for (int i = 0; i < 4; i++) {
            float2 p = base + (float2(i, j) + 0.5) * cell / 4.0;
            acc += t.sample(s, p / u.texSize).rgb;
        }
        acc /= 16.0;
        if (u.hasPrev != 0) acc = mix(prev.read(uint2(in.pos.xy)).rgb, acc, u.blend);
        return float4(acc, 1);
    }
    struct BU { float2 gameOrigin; float2 gameSize; float2 viewSize; float brightness; float zoom;
                float2 imgOrigin; float2 imgSize; float2 srcOrigin; float2 srcSize; float2 innerX; int mode; float pad; };
    fragment float4 fbackdrop(V in [[stage_in]], constant BU &u [[buffer(0)]], texture2d<float> g [[texture(0)]],
                              texture2d<float> src [[texture(1)]], sampler s [[sampler(0)]]) {
        float2 p = in.uv * u.viewSize;
        if (u.mode == 1) {
            // border fill: only the side border columns of the game image, only where the picture is black
            float2 q = (p - u.imgOrigin) / u.imgSize;
            if (q.x < 0 || q.x > 1 || q.y < 0 || q.y > 1 || (p.x >= u.innerX.x && p.x <= u.innerX.y)) discard_fragment();
            float2 sp = u.srcOrigin + q * u.srcSize;
            float3 pc = src.read(uint2(clamp(sp, float2(0), float2(src.get_width() - 1, src.get_height() - 1)))).rgb;
            if (max(pc.r, max(pc.g, pc.b)) > 0.5 / 255.0) discard_fragment();
        }
        float2 c = u.gameOrigin + u.gameSize * 0.5;
        float2 uv = (p - c) / (u.gameSize * u.zoom) + 0.5;
        float2 gs = float2(g.get_width(), g.get_height());
        float2 uvc = clamp(uv, 0.5 / gs, 1.0 - 0.5 / gs);
        // soft 13-tap blur on the small texture (hides the bilinear diamonds)
        float2 r = 1.6 / gs;
        float3 acc = g.sample(s, uvc).rgb * 0.2;
        const float2 o[12] = { float2(1,0), float2(-1,0), float2(0,1), float2(0,-1), float2(0.7,0.7), float2(-0.7,0.7),
                               float2(0.7,-0.7), float2(-0.7,-0.7), float2(2,0), float2(-2,0), float2(0,2), float2(0,-2) };
        for (int k = 0; k < 12; k++) acc += g.sample(s, clamp(uvc + o[k] * r, 0.5 / gs, 1.0 - 0.5 / gs)).rgb * (k < 8 ? 0.075 : 0.05);
        // fade out with the distance from the game image
        float2 d2 = max(max(-uv, uv - 1.0), 0.0);
        float d = length(d2 * float2(u.gameSize.x / u.gameSize.y, 1.0));
        float fade = exp(-d * 1.5);
        float3 col = acc * u.brightness * (0.35 + 0.65 * fade);
        // tiny ordered noise against banding
        float n = fract(sin(dot(floor(p), float2(12.9898, 78.233))) * 43758.5453) - 0.5;
        return float4(col + n / 255.0, 1);
    }

    // ---------------------------------------------------------------- main image
    struct U {
        float2 srcOrigin; float2 srcSize; float2 texSize;
        float2 dstOrigin; float2 dstSize; float2 viewSize;
        float2 grid;
        int mode; float scanline; float curvature; int flags;
        int crtClassic; int maskType; float maskStrength; float bloom;
        float sharpness; float triads; float pad0; float pad1;
    };
    vertex V vmain(uint vid [[vertex_id]], constant U &u [[buffer(0)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 c = corners[vid];
        float2 px = u.dstOrigin + c * u.dstSize;
        V o; o.pos = float4(px.x / u.viewSize.x * 2 - 1, 1 - px.y / u.viewSize.y * 2, 0, 1); o.uv = c; return o;
    }
    // sharp bilinear: nearest-neighbour look without shimmering on non-integer scales. `texel` is a position in
    // grid cells (cell k covers [k, k+1)); the result is the position to sample: the cell centre k + 0.5 over
    // most of the cell, blending into the neighbour only within half an output pixel of the cell edge.
    // (The port's original version returned k + 0 .. k + 1 over the cell, i.e. it sampled at the cell EDGES and
    // showed a 50/50 blend of neighbouring pixels almost everywhere; fixed by the presentation agent.)
    float2 sharpUV(float2 texel, float2 scale) {
        float2 f = fract(texel), i = floor(texel);
        float2 region = max(0.5 - 0.5 / scale, 0.0);
        float2 cd = f - 0.5;
        return i + 0.5 + (cd - clamp(cd, -region, region)) * max(scale, 1.0);
    }
    // phosphor triad, band-limited: one cosine per channel, 120 degrees apart, mean 1 over a triad (no
    // brightness loss) and no harmonics that could alias at 3-4 screen pixels per triad. amount 0..1.
    static float3 maskRGB(float phase, float amount) {
        const float3 centre = float3(0.0, 1.0 / 3.0, 2.0 / 3.0);
        return 1.0 + amount * cos(6.2831853 * (phase - centre));
    }
    fragment float4 fmain(V in [[stage_in]], constant U &u [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        float2 uv = in.uv;
        bool vignette = (u.flags & 1) != 0;
        if (u.mode == 2 && u.curvature > 0) {
            float2 cc = uv * 2 - 1; cc *= 1 + 0.04 * (cc.yx * cc.yx); uv = cc * 0.5 + 0.5;
            if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1) return float4(0,0,0,1);
        }
        float2 lowSize = u.grid;
        float2 tpg = u.srcSize / u.grid;          // texels per grid cell (2,1 for the canvas; 1,1 for MMPX output)
        float2 lp = uv * lowSize;
        float2 scale = u.dstSize / lowSize;
        float4 col;
        // sample positions stay inside the source rect (no bleeding of the rows / columns next to it, e.g. the
        // last game-window line into the top of the HUD magnifier)
        float2 lo = float2(0.5), hi = lowSize - 0.5;
        if (u.mode == 1) {
            float2 tp = (u.srcOrigin + clamp(lp, lo, hi) * tpg) / u.texSize; col = t.sample(s, tp);
        } else if (u.mode == 2 && u.crtClassic == 0) {
            float2 sp = sharpUV(lp, scale);
            sp.x = mix(lp.x, sp.x, u.sharpness);
            col = t.sample(s, (u.srcOrigin + clamp(sp, lo, hi) * tpg) / u.texSize);
        } else {
            float2 sp = sharpUV(lp, scale);
            float2 tp = (u.srcOrigin + clamp(sp, lo, hi) * tpg) / u.texSize;
            col = t.sample(s, tp);
        }
        if (u.mode == 2 && u.crtClassic != 0) {
            // Classic: the port's original CRT (scanlines + slot mask + mild bloom), unchanged
            float yl = fract(lp.y);
            float beam = mix(1.0 - u.scanline, 1.0, exp(-pow((yl - 0.5) * 3.0, 2.0)));
            float3 c = col.rgb;
            float lum = dot(c, float3(0.3, 0.59, 0.11));
            c *= mix(beam, 1.0, lum * 0.5);
            int mx = int(in.pos.x) % 3;
            float3 mask = mx == 0 ? float3(1.0, 0.82, 0.82) : (mx == 1 ? float3(0.82, 1.0, 0.82) : float3(0.82, 0.82, 1.0));
            c *= mask * 1.12;
            if (vignette) { float2 vig = in.uv * (1 - in.uv); c *= pow(vig.x * vig.y * 16, 0.12); }
            return float4(c, 1);
        }
        if (u.mode == 2) {
            float3 c = col.rgb;
            if (u.bloom > 0) {
                float3 b = float3(0);
                const float2 o[8] = { float2(1.5,0), float2(-1.5,0), float2(0,1.2), float2(0,-1.2),
                                      float2(1.1,0.9), float2(-1.1,0.9), float2(1.1,-0.9), float2(-1.1,-0.9) };
                for (int k = 0; k < 8; k++) b += t.sample(s, (u.srcOrigin + (lp + o[k]) * tpg) / u.texSize).rgb;
                b /= 8.0;
                c += b * b * u.bloom * 0.9;
            }
            // scanlines: the beam gets wider on bright lines (brightness mostly kept)
            float lum = dot(c, float3(0.3, 0.59, 0.11));
            float yl = fract(lp.y) - 0.5;
            float w = mix(0.24, 0.42, saturate(lum));
            float beam = exp(-(yl * yl) / (2.0 * w * w));
            float norm = w * 2.5066 ;                 // integral of the gaussian over one line
            c *= mix(1.0, beam / max(norm, 0.3), u.scanline);
            // phosphor mask in content space: an integer number of triads per lowres pixel, so it can't beat
            // against the image; about 3 screen pixels per triad at any output resolution
            if (u.maskType != 0 && u.maskStrength > 0 && u.triads > 0) {
                float tx = lp.x * u.triads;
                float3 m = maskRGB(fract(tx), u.maskStrength);
                if (u.maskType == 2) {
                    // slot mask: soft dark gaps between the slots, staggered by half a line in alternate triad
                    // columns (mean kept at 1)
                    float col2 = fmod(floor(tx), 2.0);
                    float sy = fract(lp.y + col2 * 0.5 + 0.5);
                    float gap = 1.0 - 0.5 * u.maskStrength * (1.0 + cos(6.2831853 * sy)) * 0.5;
                    m *= gap / (1.0 - 0.25 * u.maskStrength);
                }
                c *= m;
            }
            if (vignette) { float2 vig = in.uv * (1 - in.uv); c *= pow(vig.x * vig.y * 16, 0.1); }
            return float4(c, 1);
        }
        return float4(col.rgb, 1);
    }

    // ---------------------------------------------------------------- L4 side columns
    struct SU { float2 dstOrigin; float2 dstSize; float2 viewSize; float2 texSize; float fog; int side; float alpha; float pad; };
    vertex V vcol(uint vid [[vertex_id]], constant SU &u [[buffer(0)]]) {
        float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
        float2 c = corners[vid];
        float2 px = u.dstOrigin + c * u.dstSize;
        V o; o.pos = float4(px.x / u.viewSize.x * 2 - 1, 1 - px.y / u.viewSize.y * 2, 0, 1); o.uv = c; return o;
    }
    fragment float4 fcolumns(V in [[stage_in]], constant SU &u [[buffer(0)]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        float2 lp = in.uv * u.texSize;
        float2 sp = sharpUV(lp, u.dstSize / u.texSize);
        float4 c = t.sample(s, sp / u.texSize);
        // fog: fade towards the outer edge (side 0 = left column: outer edge at uv.x = 0)
        float outer = u.side == 0 ? in.uv.x : 1.0 - in.uv.x;
        float a = u.fog > 0 ? smoothstep(0.0, u.fog, outer) : 1.0;
        return float4(c.rgb, c.a * a * u.alpha);
    }

    // ---------------------------------------------------------------- S13 hit edge tint
    struct TU { float2 viewSize; float amount; float pad; };
    fragment float4 ftint(V in [[stage_in]], constant TU &u [[buffer(0)]]) {
        float2 p = in.uv;
        float2 e = min(p, 1.0 - p) * float2(u.viewSize.x / u.viewSize.y, 1.0);
        float edge = 1.0 - smoothstep(0.0, 0.09, min(e.x, e.y));
        return float4(0.9, 0.05, 0.02, edge * u.amount * 0.65);
    }
    """
}
