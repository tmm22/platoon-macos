// David Whittaker music/sfx driver API ($2800 jump block). Spec: re/audio/NOTES.md.
// The audio translation implements the *_impl functions (MusicDriver.swift) and removes the stubs.

extension Platoon {
    /// $2800 api_init_song: d0.b = song 0..6.
    func md_initSong(_ d0: UInt8) { md_initSong_impl(d0) }
    /// $280e api_play: one driver tick, called from the vblank handler every frame.
    func md_play() { md_play_impl() }
    /// $281c api_stop.
    func md_stop() { md_stop_impl() }
    /// $2838 api_sfx: d0.w = (channel << 8) | id.
    func md_sfx(_ d0: UInt16) { md_sfx_impl(d0) }
    /// $2d98: master volume byte ($40 = full); the kernel fades it during GAME OVER.
    var md_masterVolume: UInt8 { get { mem.r8(0x2d98) } set { mem.w8(0x2d98, newValue) } }
}
