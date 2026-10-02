// Cycle-exact reference for real-A500 timing: drives the vAmiga core (https://github.com/dirkwhoffmann/vAmiga,
// MPL-2.0; fetched and built by build.sh, not vendored) with the original game, frame by frame, the same way
// tools/amiga/emu is driven. Used to calibrate the port's real-A500 CPU/blitter timing (port/verify/timing.md).
//
// usage: drv ADF ROM SCRIPT FRAMES OUTPREFIX ALIGNFRAME BOOTFRAME        (environment, all optional:)
//   EXTROM=file     AROS extension ROM (needed with the AROS ROM; vAmiga's Resources/.../aros-*-ext.bin)
//   TICKPCS=a,b,..  breakpoint PCs (hex) logged to OUT.hits as "pc frame vpos hpos" (default 17186,17270,17276)
//   ALIGNPC=pc      script frames >= ALIGNFRAME are re-based to the first hit of this PC (default 17186)
//   ENTRY=f         script frames in [f, ALIGNFRAME) are re-based to the section entry ($17000 hit)
//                   (frames < ENTRY are relative to the kernel vblank install, emu frame BOOTFRAME = 90)
//   TICKIN=file     per-tick inputs instead of the script after ALIGNFRAME ("TICK in HEXBITS", "TICK poke A V S"),
//                   applied at the TICK-th hit of TICKPC (default 17186); same format as platoon-headless --tickinput
//   TDLO/TDLEN      region dumped at every TICKPC hit to OUT.td (emu --tickdump format, frames re-based to the
//                   emulator's), default 60c24/a0
//   DEDUPTIME=1     drop repeated hits of a PC within 100 lines (an interrupt taken just before the breakpointed
//                   instruction reports it twice); default: same PC/d0/sp/tick counter ($60cb4, CNTADDR)
//   SHOT=file.ppm   final screen
// The machine is an A500 OCS PAL (68000, 512K chip + 512K slow RAM, the A500_OCS_1MB scheme). Kickstart is not
// needed: AROS (bundled with vAmiga) runs 100 frames, then the cracked bootblock is high-level emulated exactly like
// tools/amiga/emu does it (22 sectors from ADF $70c00 to $76000, jmp $7613a) with the drive motor on; everything
// after that is the original code on vAmiga's cycle-exact CPU, blitter, copper, DMA and disk. --deterministic is
// always on (same NOPs and seed as tools/amiga/emu).
//
// Built against vAmiga's internal classes (private members opened up below): this is a measurement tool, pinned to
// the vAmiga commit in build.sh.
#include "vaconfig.h"
#include <ranges>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <fstream>
#include <sstream>
#include <iostream>
#include <filesystem>
#include <optional>
#include <variant>
#include <array>
#include <unordered_map>
#include <atomic>
#include <latch>
#include <chrono>
#include <algorithm>
#include <span>
#include <deque>
#include <list>
#include <condition_variable>
#include <regex>
#include <bitset>
#include <random>
#include <format>
#define private public
#define protected public
#include "Emulator.h"
#include "Amiga.h"
#undef private
#undef protected
#include <cstdio>
#include <fstream>
#include <sstream>
#include <vector>
#include <string>
#include <unistd.h>

using namespace vamiga;

struct Ev { long f; std::string cmd; std::vector<std::string> a; };

int main(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage\n"); return 1; }
    std::string adf = argv[1], rom = argv[2], script = argv[3], out = argv[5];
    long frames = atol(argv[4]);
    long align = argc > 6 ? atol(argv[6]) : 813;
    long bootOff = argc > 7 ? atol(argv[7]) : 0;   // emu frame at which our boot reference point happens

    std::vector<Ev> ev;
    { std::ifstream in(script); std::string l;
      while (std::getline(in, l)) { std::istringstream s(l); Ev e; if (!(s >> e.f >> e.cmd)) continue;
        std::string x; while (s >> x) e.a.push_back(x); ev.push_back(e); } }

    auto *emu = new Emulator();
    emu->launch(nullptr, nullptr);
    while (!emu->isInitialized()) usleep(1000);
    emu->powerOff();
    emu->set(ConfigScheme::A500_OCS_1MB);
    Amiga &a = emu->main;
    a.mem.loadRom(fs::path(rom));
    if (getenv("EXTROM")) a.mem.loadExt(fs::path(getenv("EXTROM")));
    a.df0.swapDisk(fs::path(adf));
    a.controlPort2.setDevice(ControlPortDevice::JOYSTICK);
    emu->powerOn();
    emu->suspend();

    FILE *ft = fopen((out + ".ticks").c_str(), "w"), *fw = fopen((out + ".wait").c_str(), "w");
    FILE *td = fopen((out + ".td").c_str(), "wb"), *td6 = fopen((out + ".td6").c_str(), "wb");
    auto rd8 = [&](u32 ad) { return a.mem.spypeek8<Accessor::CPU>(ad); };
    auto rd32 = [&](u32 ad) { return (u32)a.mem.spypeek16<Accessor::CPU>(ad) << 16 | a.mem.spypeek16<Accessor::CPU>(ad + 2); };

    std::vector<u32> bpl; u32 alignPC = 0x17186;
    if (getenv("TICKPCS")) { std::stringstream ss(getenv("TICKPCS")); std::string x; while (std::getline(ss, x, ',')) bpl.push_back((u32)strtoul(x.c_str(), nullptr, 16)); }
    else bpl = { 0x17186, 0x17270, 0x17276 };
    if (getenv("ALIGNPC")) alignPC = (u32)strtoul(getenv("ALIGNPC"), nullptr, 16);
    FILE *fh = fopen((out + ".hits").c_str(), "w");
    struct TIn { long k; std::string cmd; std::vector<std::string> a; };
    std::vector<TIn> tin; size_t tnext = 0;
    if (getenv("TICKIN")) { std::ifstream in(getenv("TICKIN")); std::string l;
        while (std::getline(in, l)) { std::istringstream s(l); TIn e; if (!(s >> e.k >> e.cmd)) continue; std::string x; while (s >> x) e.a.push_back(x); tin.push_back(e); }
        std::stable_sort(tin.begin(), tin.end(), [](const TIn &x, const TIn &y) { return x.k < y.k; }); }
    bool tickMode = !tin.empty();
    u32 lastPC = 0, lastD0 = 0, lastSP = 0, lastCnt = 0; long lastHitL = -1000;
    u32 tickPC = getenv("TICKPC") ? (u32)strtoul(getenv("TICKPC"), nullptr, 16) : 0x17186;
    u32 tdLo = getenv("TDLO") ? (u32)strtoul(getenv("TDLO"), nullptr, 16) : 0x60c24;
    u32 tdLen = getenv("TDLEN") ? (u32)strtoul(getenv("TDLEN"), nullptr, 16) : 0xa0;
    u32 cntAddr = getenv("CNTADDR") ? (u32)strtoul(getenv("CNTADDR"), nullptr, 16) : 0x60cb4;
    long entryEmu = getenv("ENTRY") ? atol(getenv("ENTRY")) : 0, entryFrame = -1;
    long kernelFrame = -1, firstTick = -1, tick = 0;
    bool bpsOn = false, seeded = false, hleDone = false;
    size_t next = 0;
    auto &joy = a.controlPort2.joystick;
    auto apply = [&](const Ev &e) {
        int v = e.a.empty() ? 0 : atoi(e.a[0].c_str());
        if (e.cmd == "right") joy.trigger(v ? GamePadAction::PULL_RIGHT : GamePadAction::RELEASE_X);
        else if (e.cmd == "left") joy.trigger(v ? GamePadAction::PULL_LEFT : GamePadAction::RELEASE_X);
        else if (e.cmd == "up") joy.trigger(v ? GamePadAction::PULL_UP : GamePadAction::RELEASE_Y);
        else if (e.cmd == "down") joy.trigger(v ? GamePadAction::PULL_DOWN : GamePadAction::RELEASE_Y);
        else if (e.cmd == "fire") joy.trigger(v ? GamePadAction::PRESS_FIRE : GamePadAction::RELEASE_FIRE);
        else if (e.cmd == "key") { int code = (int)strtol(e.a[0].c_str(), nullptr, 0); int down = atoi(e.a[1].c_str());
            if (down) a.keyboard.press(KeyCode(code)); else a.keyboard.release(KeyCode(code)); }
        else if (e.cmd == "poke") { u32 ad = (u32)strtoul(e.a[0].c_str(), nullptr, 16); u32 val = (u32)strtoul(e.a[1].c_str(), nullptr, 16);
            int sz = atoi(e.a[2].c_str());
            if (sz == 1) a.mem.patch(ad, (u8)val); else if (sz == 2) a.mem.patch(ad, (u16)val); else a.mem.patch(ad, (u32)val); }
        else if (e.cmd == "shot" || e.cmd == "quit") {}
        else fprintf(stderr, "unknown cmd %s\n", e.cmd.c_str());
    };

    long startFrame = a.agnus.pos.frame; long calls = 0;
    while (true) {
        if (++calls > frames * 3) { fprintf(stderr, "too many calls (reset loop?)\n"); break; }
        long f = a.agnus.pos.frame - startFrame;
        if (f >= frames) break;
        // map script frame -> our frame
        while (next < ev.size()) {
            long target;
            if (entryEmu > 0 && ev[next].f >= entryEmu && ev[next].f < align) {   // section intro: relative to $17000
                if (entryFrame < 0) break;
                target = entryFrame + (ev[next].f - entryEmu);
            } else if (ev[next].f < align) {           // boot/title phase: relative to the kernel install
                if (kernelFrame < 0) break;
                target = kernelFrame + (ev[next].f - bootOff);
            } else {
                if (tickMode) { next++; continue; }      // replaced by the per-tick inputs
                if (firstTick < 0) break;
                target = firstTick + (ev[next].f - align);
            }
            if (f < target) break;
            apply(ev[next]); next++;
        }
        if (f % 250 == 0) { fprintf(stderr, "frame %ld pc %06x v6c %08x\n", f, a.cpu.getPC0(), rd32(0x6c)); fflush(stderr); }
        if (f == 100 && !hleDone && getenv("NOHLE") == nullptr) {
            // HLE of the cracked bootblock, same as tools/amiga/emu
            FILE *af = fopen(adf.c_str(), "rb"); std::vector<u8> img(901120); fread(img.data(), 1, img.size(), af); fclose(af);
            for (u32 k = 0; k < 0x2c00; k++) a.mem.patch((u32)0x76000 + k, img[0x70c00 + k]);
            a.mem.poke16<Accessor::CPU>(0xdff09a, 0x7fff); a.mem.poke16<Accessor::CPU>(0xdff09c, 0x7fff);
            a.mem.poke16<Accessor::CPU>(0xdff096, 0x7fff);
            a.mem.poke8<Accessor::CPU>(0xbfed01, 0x7f); a.mem.poke8<Accessor::CPU>(0xbfdd00, 0x7f);
            a.mem.poke8<Accessor::CPU>(0xbfd300, 0xff); a.mem.poke8<Accessor::CPU>(0xbfd100, 0xff); a.mem.poke8<Accessor::CPU>(0xbfd100, 0x7f); a.mem.poke8<Accessor::CPU>(0xbfd100, 0x77); a.mem.poke8<Accessor::CPU>(0xbfd100, 0x7f);
            a.cpu.setSR(0x2700); a.cpu.setSP(0x7fffc); a.cpu.jump(0x7613a);
            hleDone = true; fprintf(stderr, "bootblock HLE at frame %ld\n", f);
        }
        if (kernelFrame < 0 && rd32(0x6c) == 0x10eac) { kernelFrame = f; fprintf(stderr, "kernel vblank handler at frame %ld\n", f); }
        // deterministic patch (same as tools/amiga/emu)
        if (rd8(0x10ede) == 0xd3 && rd8(0x10edf) == 0xb9) for (int k = 0; k < 16; k += 2) { a.mem.patch((u32)0x10ede + k, (u16)0x4e71); }
        if (!bpsOn && kernelFrame >= 0) {
            a.cpu.breakpoints.setAt(0x17000);
            for (u32 p : bpl) a.cpu.breakpoints.setAt(p);
            bpsOn = true;
        }
        try {
            a.computeFrame();
        } catch (StateChangeException &) {
            u32 pc = a.cpu.getPC0();
            long fr = a.agnus.pos.frame - startFrame;
            if (pc == 0x17000) {
                a.mem.patch((u32)0x12d70, (u32)0x31415926); seeded = true;
                if (entryFrame < 0) entryFrame = fr;
                fprintf(stderr, "section entry $17000 at frame %ld v%ld\n", fr, (long)a.agnus.pos.v);
            }
            // an interrupt taken just before the breakpointed instruction reports it twice: drop the repeat
            {
                long nowL = fr * 313 + (long)a.agnus.pos.v;
                bool dup = pc == lastPC && a.cpu.getD(0) == lastD0 && a.cpu.getA(7) == lastSP && rd32(cntAddr) == lastCnt;
                if (getenv("DEDUPTIME")) dup = pc == lastPC && nowL - lastHitL < 100;
                if (dup) continue;
                lastHitL = nowL;
            }
            lastPC = pc; lastD0 = a.cpu.getD(0); lastSP = a.cpu.getA(7); lastCnt = rd32(cntAddr);
            fprintf(fh, "%x %ld %ld %ld\n", pc, fr, (long)a.agnus.pos.v, (long)a.agnus.pos.h);
            if (pc == alignPC && firstTick < 0) { firstTick = fr; fprintf(stderr, "first align-pc hit at frame %ld\n", fr); }
            if (pc == 0x17000 || pc == alignPC) {} 
            if (pc == tickPC && tickMode) {
                long k = tick;     // index of the tick starting now
                while (tnext < tin.size() && tin[tnext].k <= k) {
                    auto &e = tin[tnext++];
                    if (e.cmd == "in") {
                        int b = (int)strtol(e.a[0].c_str(), nullptr, 16);
                        joy.trigger(b & 2 ? GamePadAction::PULL_RIGHT : b & 8 ? GamePadAction::PULL_LEFT : GamePadAction::RELEASE_X);
                        joy.trigger(b & 1 ? GamePadAction::PULL_DOWN : b & 4 ? GamePadAction::PULL_UP : GamePadAction::RELEASE_Y);
                        joy.trigger(b & 0x80 ? GamePadAction::PRESS_FIRE : GamePadAction::RELEASE_FIRE);
                    } else if (e.cmd == "poke") { Ev pe; pe.cmd = "poke"; pe.a = e.a; apply(pe); }
                }
            }
            if (pc == tickPC) {
                fprintf(ft, "%ld %ld %ld %ld\n", tick++, fr, (long)a.agnus.pos.v, (long)a.agnus.pos.h);
                u32 fr32 = (u32)(fr - firstTick + align);
                fwrite(&fr32, 4, 1, td); for (u32 k = 0; k < tdLen; k++) fputc(rd8(tdLo + k), td);
                fwrite(&fr32, 4, 1, td6); for (u32 k = 0; k < 0x78; k++) fputc(rd8(0x12dde + k), td6);
            } else if (pc == 0x17270 || pc == 0x17276) {
                fprintf(fw, "%x %ld %ld %ld\n", pc, fr, (long)a.agnus.pos.v, (long)a.agnus.pos.h);
            }
        }
    }
    (void)seeded;
    if (getenv("SHOT")) {
        FILE *p = fopen(getenv("SHOT"), "wb"); fprintf(p, "P6 %ld %ld 255\n", (long)HPIXELS, (long)VPIXELS);
        Texel *ptr = a.denise.pixelEngine.stablePtr();
        for (isize i = 0; i < HPIXELS * VPIXELS; i++) { u32 c = (u32)ptr[i]; fputc(c & 0xff, p); fputc((c >> 8) & 0xff, p); fputc((c >> 16) & 0xff, p); }
        fclose(p);
        fprintf(stderr, "df0 hasDisk %d\n", (int)a.df0.hasDisk());
    }
    fclose(ft); fclose(fw); fclose(fh); fclose(td); fclose(td6);
    fprintf(stderr, "done %ld frames, %ld ticks\n", (long)(a.agnus.pos.frame - startFrame), tick);
    _exit(0);
}
