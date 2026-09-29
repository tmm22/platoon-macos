// Stand-alone audio test harness (host-side, not a translation): used by `platoon-headless --music-test /
// --sfx-test` to render songs and sound effects through the translated driver without the kernel.
// It loads the main program like the boot does (tracks 1-17 to $400: RAM X = ADF offset X + $1200 for the
// whole $2538-$17000 area, see re/audio/NOTES.md §1), installs a minimal level-3 handler that calls
// `md_play` once per vblank (like the kernel handler $10eac -> jsr $280e) and offers the kernel wrappers
// $10c00 (music) / $10c3a (music off) / $10c50 (sfx) with music and fx enabled (option byte = 3).

public final class MusicDriverTestHarness {
    let p: Platoon
    public init(machine m: Machine) { p = Platoon(machine: m) }

    /// Loads the resident program and installs the vblank handler. Call before `Machine.start`.
    public func setup() {
        p.disk.loadTracks(first: 1, count: 17, to: 0x400, memory: p.mem)
        p.chip.interruptHandlers[3] = { [p] in
            p.md_play()
            p.chip.write(0x09c, 0x0070)
        }
        p.chip.write(0x09a, 0xc020)
    }

    /// Kernel $10c00 with MUZAK on: start song `n`, master volume := $40.
    public func music(_ n: Int) {
        p.md_initSong(UInt8(truncatingIfNeeded: n))
        p.md_masterVolume = 0x40
    }

    /// Kernel $10c3a: stop the music, master volume := 0.
    public func musicOff() {
        p.md_stop()
        p.md_masterVolume = 0
    }

    /// Kernel $10c00 with MUZAK off: `jsr $281c` (stop), master volume := $40.
    public func stop() {
        p.md_stop()
        p.md_masterVolume = 0x40
    }

    /// Kernel $fed6: fade the master volume one step.
    public func fade() {
        if p.md_masterVolume != 0 { p.md_masterVolume -= 1 }
    }

    /// Driver entry $2838 called directly: d0.w = (channel << 8) | id.
    public func rawSfx(_ d0: UInt16) { p.md_sfx(d0) }

    /// Kernel $10c50 channel routing with FX on: synth ids on channel 0 (channel 2 if a sfx is active on 0),
    /// samples $82-$85 on channels 0+2, $80/$81 on channels 1+3.
    public func sfx(_ id: Int) {
        var d0 = UInt16(id & 0xff)
        if d0 & 0x80 == 0 {
            if p.mem.r8(0x4012) != 0 { d0 |= 0x200 }
            p.md_sfx(d0)
        } else if d0 >= 0x82 {
            p.md_sfx(d0)
            p.md_sfx(d0 | 0x200)
        } else {
            p.md_sfx(d0 | 0x100)
            p.md_sfx(d0 | 0x300)
        }
    }
}
