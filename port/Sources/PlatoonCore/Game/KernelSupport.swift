import Foundation

// Kernel/resident support: RAM addresses, 68000 BCD arithmetic and the CPU-time model.
// Spec: re/kernel/NOTES.md. Everything here is shared by Resident.swift and Kernel*.swift.

/// Offsets into the global variable block a6 = $12dde (NOTES.md §(c)).
enum KV {
    static let curMan: UInt32 = 0x1e        // l  pointer to current man record
    static let manIndex: UInt32 = 0x22      // w
    static let mapIcon: UInt32 = 0x24       // w
    static let compassOn: UInt32 = 0x26     // w
    static let tntIcon: UInt32 = 0x28       // w
    static let compassDir: UInt32 = 0x2a    // w
    static let gunCount: UInt32 = 0x2c      // w
    static let morale: UInt32 = 0x2e        // w  8.8 fixed point
    static let textCount: UInt32 = 0x30     // w  text tick countdown
    static let textPeriod: UInt32 = 0x32    // w
    static let textRamp: UInt32 = 0x34      // l  colour ramp table
    static let textStep: UInt32 = 0x38      // w  fade step 0..7
    static let textDir: UInt32 = 0x3a       // w  +1 / -1
    static let textQueue: UInt32 = 0x3c     // 6 w
    static let textN: UInt32 = 0x48         // w  queued messages
    static let textTable: UInt32 = 0x4a     // l
    static let score: UInt32 = 0x4e         // l  8 BCD digits
    static let scorePrinted: UInt32 = 0x52  // b  (tas)
    static let topBarMode: UInt32 = 0x54    // w
    static let frameFlag: UInt32 = 0x56     // b  set by vblank
    static let splitPlus3c: UInt32 = 0x58   // b
    static let topPalPtr: UInt32 = 0x5a     // l
    static let hudPalPtr: UInt32 = 0x5e     // l
    static let drawBuf: UInt32 = 0x62       // l  $70000 / $78000
    static let soundFlags: UInt32 = 0x66    // b  bit0 music, bit1 fx
    static let timerOn: UInt32 = 0x68       // w
    static let timerVbl: UInt32 = 0x6a      // w  vblank countdown
    static let timerMin: UInt32 = 0x6c      // b  BCD
    static let timerSec: UInt32 = 0x6d      // b  BCD
    static let section: UInt32 = 0x6e       // w  next load section
    static let cheats: UInt32 = 0x70        // w
    static let scroll: UInt32 = 0x72        // w  game-window BPLCON1
    static let firstBoot: UInt32 = 0x74     // b
}

/// Absolute kernel addresses ($f800-$16a6b).
enum KA {
    static let initEntry: UInt32 = 0xf800          // jt00
    static let level3: UInt32 = 0x10eac
    static let level6: UInt32 = 0x10faa
    static let setHudPal: UInt32 = 0x11000
    static let setTopPal: UInt32 = 0x11010
    static let logoCnt: UInt32 = 0x10dbe           // w
    static let logoState: UInt32 = 0x10dc0         // b
    static let cheatHeld: UInt32 = 0x10ea2         // w
    static let cheatPtr: UInt32 = 0x10ea4          // l
    static let pauseColour: UInt32 = 0x10ea8       // w
    static let pause: UInt32 = 0x10eaa             // w
    static let bcdZero: UInt32 = 0x10fa6           // 4 zero bytes (sbcd source)
    static let woundFlag: UInt32 = 0x1069e         // b
    static let rleOperand: UInt32 = 0x102e4        // l  self-modified operand of move.w $xxxxxxxx,d3
    static let compassFrames: UInt32 = 0x1051c     // 4 l
    static let secLoaders: UInt32 = 0x11166        // 3 l
    static let strLoading: UInt32 = 0x11172
    static let secNames: UInt32 = 0x1118a          // 3 l
    static let strSec0: UInt32 = 0x11196, strSec1: UInt32 = 0x111b7, strSec2: UInt32 = 0x111d6
    static let hexDigits: UInt32 = 0x111f7
    static let cheat1: UInt32 = 0x11207, cheat2: UInt32 = 0x11211
    static let strScoreHdr: UInt32 = 0x11217
    static let strHiscoreHdr: UInt32 = 0x11220
    static let strTextHdr: UInt32 = 0x11229
    static let strHudLabels: UInt32 = 0x11232
    static let strTimeHdr: UInt32 = 0x11267
    static let strDiskError: UInt32 = 0x11272
    static let strFatal: UInt32 = 0x1129a
    static let strSaving: UInt32 = 0x112c3
    static let strLoadingHs: UInt32 = 0x112da
    static let strBlank22: UInt32 = 0x112f1
    static let barMasks: UInt32 = 0x1131e
    static let rampCyan: UInt32 = 0x1133e, rampRed: UInt32 = 0x1135e
    static let palLogo: UInt32 = 0x1137e           // c0; c1 = +2, c6 = +$0c
    static let palText: UInt32 = 0x1139e
    static let palBlack: UInt32 = 0x113be
    static let palCredits: UInt32 = 0x113de
    static let palAttract: UInt32 = 0x113fe
    static let kernelTexts: UInt32 = 0x1141e
    static let strCredits: UInt32 = 0x114a1
    static let strMuzakOnOff: UInt32 = 0x115a6
    static let strFxOnOff: UInt32 = 0x115b0
    static let cheat1Flag: UInt32 = 0x115b3
    static let cheat2Flag: UInt32 = 0x115c2
    static let copperA: UInt32 = 0x115d0
    static let copperCommon: UInt32 = 0x115f0
    static let copTopBplcon1: UInt32 = 0x115f2
    static let copTopDiwstrt: UInt32 = 0x115f6
    static let copTopPalette: UInt32 = 0x115fa
    static let copSplitWait: UInt32 = 0x11638
    static let copHudBplpt: UInt32 = 0x1163e
    static let copHudBplcon1: UInt32 = 0x1165e
    static let copHudPalette: UInt32 = 0x11666
    static let copCol8: UInt32 = 0x11686, copCol9: UInt32 = 0x1168a
    static let copperB: UInt32 = 0x116a8
    static let hiscoreTrack: UInt32 = 0x116cc      // track 77 image, $1600 bytes
    static let hsEntries: UInt32 = 0x116e5
    static let hsNames: UInt32 = 0x116eb
    static let hsOffsets: UInt32 = 0x117e0
    static let hsScores: UInt32 = 0x11808
    static let hsNameLine: UInt32 = 0x11830
    static let hsNameBuf: UInt32 = 0x11836
    static let hsEraseCol: UInt32 = 0x1184b
    static let hsCursorCol: UInt32 = 0x1184f
    static let f10Debounce: UInt32 = 0x12ccc       // w
    static let curTune: UInt32 = 0x12cce           // w
    static let fadeBufTop: UInt32 = 0x12cd0
    static let fadeBufHud: UInt32 = 0x12cf0
    static let retryCount: UInt32 = 0x12d1e
    static let retryArgs: UInt32 = 0x12d20
    static let junk: UInt32 = 0x12d60             // w  (d3 stored by k_save_hiscores)
    static let cache28: UInt32 = 0x12d62, cache24: UInt32 = 0x12d64, cache2c: UInt32 = 0x12d66
    static let cache26: UInt32 = 0x12d68, cache2a: UInt32 = 0x12d6a, cacheTime: UInt32 = 0x12d6c
    static let cacheOnOff: UInt32 = 0x12d6e, cacheSndIcons: UInt32 = 0x12d6f
    static let rng: UInt32 = 0x12d70
    static let swapPending: UInt32 = 0x12d74
    static let nextCop: UInt32 = 0x12d76
    static let rowTab: UInt32 = 0x12d7a
    static let firstBootFlag: UInt32 = 0x12e52     // = $74(a6)
    static let font: UInt32 = 0x12e54
    static let hudHeart: UInt32 = 0x13254, hudBullet: UInt32 = 0x13274, hudGrenade: UInt32 = 0x13294
    static let hudFlare: UInt32 = 0x132d4
    static let iconMap: UInt32 = 0x13774, iconTnt: UInt32 = 0x13894, iconWound: UInt32 = 0x139b4
    static let iconGun: UInt32 = 0x13ad4
    static let iconMusicOn: UInt32 = 0x13bf4, iconFxOn: UInt32 = 0x13d14
    static let iconMusicOff: UInt32 = 0x13e34, iconFxOff: UInt32 = 0x13f54
    static let rleLogo: UInt32 = 0x14074, rleAttract: UInt32 = 0x14ec4
    static let musVolume: UInt32 = 0x2d98          // w master music volume (audio driver)
    static let musCh0Busy: UInt32 = 0x4012         // b
    static let sectionEntry: UInt32 = 0x17000
}

extension Platoon {
    // MARK: 68000 BCD arithmetic (exactly as Musashi, the emulator's CPU core)

    /// `abcd`: returns (result, X/C).
    @inline(__always) static func abcd(_ dst: UInt8, _ src: UInt8, x: Bool) -> (UInt8, Bool) {
        var res = UInt32(src & 0x0f) + UInt32(dst & 0x0f) + (x ? 1 : 0)
        if res > 9 { res += 6 }
        res += UInt32(src & 0xf0) + UInt32(dst & 0xf0)
        let c = res > 0x99
        if c { res = res &- 0xa0 }
        return (UInt8(truncatingIfNeeded: res), c)
    }

    /// `sbcd` dst - src - X: returns (result, X/C).
    @inline(__always) static func sbcd(_ dst: UInt8, _ src: UInt8, x: Bool) -> (UInt8, Bool) {
        var res = UInt32(dst & 0x0f) &- UInt32(src & 0x0f) &- (x ? 1 : 0)
        if res > 9 { res = res &- 6 }
        res = res &+ UInt32(dst & 0xf0) &- UInt32(src & 0xf0)
        let c = res > 0x99
        if c { res = res &+ 0xa0 }
        return (UInt8(truncatingIfNeeded: res), c)
    }

    // MARK: CPU-time model
    //
    // The translated code runs in zero emulated time, but on the A500 (and in tools/amiga/emu, which runs a
    // cycle-counted 68000 at 454 cycles per raster line) the CPU-heavy kernel routines (screen clears, RLE
    // decoding, text printing, disk loading with its step delays) take many raster lines, which decides in
    // which frame the following vblank-paced code runs. To keep the port frame-aligned with the original, the
    // heavy routines add their 68000 cycle cost with `cpu(n)`; the debt is paid (the game thread waits the
    // corresponding number of raster lines, letting interrupts run meanwhile) before the next wait. The costs
    // are the Musashi cycle counts of the original loops (measured against the emulator, see STATUS/verification).

    static let cyclesPerLine = 454

    // Real-A500 timing (default; enhancements.kernel.referenceEmulator = the emulator's): tools/amiga/emu gives the
    // 68000 every bus cycle and completes blits instantly, a real A500 does neither. Measured with the cycle-exact
    // vAmiga (tools/vamiga, port/verify/timing.md) on identical ticks of the original game: CPU-only code runs 6.6%
    // slower than its Musashi count (bus alignment), and the blitter's DMA time mostly adds to the CPU time
    // (the program waits for each blit before it sets up the next, and the 4-plane display takes half the slots).
    // So `cpuCycles` stays in Musashi cycles, a raster line holds `cpuLine` of them, and every blit adds its
    // cycle-diagram time scaled by `a500BlitCost` (per mille, Musashi cycles per blitter DMA cycle).
    static let a500CPULine = 426          // 454 / 1.066
    static let a500BlitCost = 2_720

    /// Musashi cycles of main-program work per raster line (CPU-time model).
    var cpuLine: Int { a500Timing ? Platoon.a500CPULine : Platoon.cyclesPerLine }

    /// Installs the blitter's share of the A500 timing (at run start, after the enhancements are resolved).
    func installTimingModel() {
        a500Timing = !enhancements.kernel.referenceEmulator
        chip.paula.accurate = a500Timing
        chip.onBlitCycles = a500Timing ? { [weak self] dma in self?.cpu(dma * Platoon.a500BlitCost / 1000) } : nil
    }

    /// Adds `cycles` of 68000 execution time (paid at the next wait / settleCPU()).
    func cpu(_ cycles: Int) { cpuCycles += cycles }

    /// Lets the beam advance by the accumulated CPU time (whole raster lines). Interrupt handlers that run
    /// meanwhile preempt the main program: their cost (irqCharge) extends the stretch.
    func settleCPU() {
        // Only the main program waits: inside an interrupt handler (which may run on the host thread, or on the
        // game thread when a register write dispatches it synchronously) the time is kept as debt for later.
        guard irqDepth == 0, Thread.current.name == "Platoon game" else { return }
        let cpl = cpuLine
        while cpuCycles >= cpl {
            let lines = cpuCycles / cpl
            let target = m.beamLine + lines
            cpuBusy = true
            if target < Chipset.linesPerFrame {
                cpuCycles -= lines * cpl
                m.waitLine(target)
            } else {
                cpuCycles -= (Chipset.linesPerFrame - m.beamLine) * cpl
                m.waitVBlank()
            }
            cpuBusy = false
            cpuCycles += irqPreempted
            irqPreempted = 0
        }
    }

    /// Waits `lines` raster lines of CPU time from the current beam position (crossing vblanks if needed).
    func advanceBeam(_ lines: Int) {
        cpu(lines * cpuLine)
        settleCPU()
    }

    /// Absolute CPU time (cycles since power-on) of the current beam position.
    var beamCycles: Int { (Int(m.frameCount) * Chipset.linesPerFrame + chip.vpos) * Platoon.cyclesPerLine }

    /// Called by the translated interrupt handlers with their 68000 cost: if the main program was executing
    /// (a CPU-time stretch being settled) the handler delays it by the full cost; if it was waiting (vblank,
    /// raster line) only the part of the handler that extends past the wake-up delays it (irqCatchUp).
    func irqCharge(_ cycles: Int) {
        if cpuBusy { irqPreempted += cycles; return }
        irqBusyUntil = max(irqBusyUntil, beamCycles) + cycles * Platoon.cyclesPerLine / cpuLine
    }

    /// After a wait: the main program resumes only when the interrupt handlers running at that moment finished.
    func irqCatchUp() {
        let now = beamCycles
        if irqBusyUntil > now { cpuCycles += (irqBusyUntil - now) * cpuLine / Platoon.cyclesPerLine }
        irqBusyUntil = 0
    }

    /// Emulated duration of the level-3 handler in 68000 cycles, fitted to tools/amiga/emu over long CPU-bound
    /// stretches (disk loads with the exact track model, the credits print): 3 lines without music, ~11 lines
    /// with the title tune, ~10.2 with the loading tune (the per-frame variation of the music driver, +-2
    /// lines, is not modelled).
    var vblankHandlerCycles: Int {
        guard musicPlaying else { return 3 * Platoon.cyclesPerLine }
        return mem.r16(KA.curTune) == 3 ? 4_620 : 4_970                   // loading tune / title & others
    }
    /// Level-6 split handler (movem of 4 registers, swap, pause colour, scroll copy).
    static let level6Cycles = 250

    /// Busy-wait iteration of a polling loop (`jsr $410; btst #7,d0; bne` etc.): the original spins on
    /// hardware; here the game thread yields until the next frame, when the input can have changed.
    func busyWaitYield() {
        settleCPU()
        m.waitVBlank()
        irqCatchUp()
    }
}

// MARK: - 68000 cycle costs of the CPU-heavy original loops (Musashi timings, calibrated against the emulator)
extension Platoon {
    static let putcharCycles = 7_591          // $1e46 one glyph (emu: 16.88 lines per char incl. the print loop)
    static let printLoopCycles = 72           // $1a6e per string byte
    static let printColourCycles = 150        // $1aa2 colour code
    static let bootPutbyteCycles = 180        // $76224 + ByteRun1 loop per output byte
    static let diskLoadOverheadCycles = 300
    static let diskSeekCycles = 1_000
    static let diskStepCycles = 183_900       // one head step incl. the $2800 dbra delay loop (emu: 405 lines)
    static let diskReadRawCycles = 1_135      // disk_read_raw: DMA setup + wait for DSKBLK (2 lines in the emu)
    static let diskDecodeCycles = 134_700     // 11 x header + 128-long MFM decode (emu, $d3c -> $d9a)
    static let diskSyncScanCycles10 = 211     // one `cmpi.w #$4489,(a2)+ ; bne` iteration, x10
}
