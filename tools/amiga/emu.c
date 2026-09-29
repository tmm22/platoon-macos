// Minimal headless Amiga 500 (OCS/PAL) emulator used as a reverse-engineering
// harness for the Platoon port. CPU: Musashi. Chipset: copper, blitter,
// bitplane + sprite display, CIA A/B, disk DMA (ADF -> MFM), Paula audio.
//
// Build: see Makefile. Usage: ./emu --help
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <zlib.h>
#include "m68k.h"

#define CHIP_SIZE 0x80000u
#define SLOW_BASE 0xC00000u
#define SLOW_SIZE 0x80000u
#define LINES_PER_FRAME 313
#define CYCLES_PER_LINE 454
#define CANVAS_W 768        /* hires pixels, covers DIW h 0x60..0x1e0 */
#define CANVAS_H 290        /* lines 0x18..0x139 */
#define CANVAS_H0 0x60
#define CANVAS_V0 0x18

typedef struct {
    uint8_t pra, prb, ddra, ddrb;
    uint16_t ta, tb, ta_latch, tb_latch;
    uint8_t cra, crb, icr, icr_mask, sdr;
    uint32_t tod, tod_latch, alarm; int tod_latched;
    double tick_acc;
} CIA;

typedef struct {
    uint32_t lc, ptr; uint16_t len, cnt, per, vol, dat;
    int active; double phase; int8_t cur;
    int pending_irq;
} AudChan;

typedef struct {
    int state; /* 0 idle, 1 waiting vstart, 2 active */
    uint16_t pos, ctl, data, datb;
    int vstart, vstop, hstart, attached, armed;
} Sprite;

typedef struct {
    uint8_t chip[CHIP_SIZE];
    uint8_t slow[SLOW_SIZE];
    uint16_t regs[0x100];
    uint16_t dmacon, intena, intreq, adkcon;
    int vpos; uint64_t frame;
    /* copper */
    uint32_t cop_pc; int cop_waiting; uint16_t cop_w1, cop_w2; int cop_halt;
    /* blitter */
    int bzero;
    /* disk */
    int cyl, side, motor, step_prev, sel_prev; int dsklen_armed; uint16_t dsklen_prev;
    int dskblk_delay;
    CIA ciaa, ciab;
    AudChan aud[4];
    Sprite spr[8];
    uint16_t joy1dat, joy0dat; int fire1, fire0;
    int key_delay;
    double line_audio_acc;
} State;

static State S;
static uint8_t *adf; static size_t adf_size;
static uint32_t canvas[CANVAS_W * CANVAS_H];
static int log_disk = 1, trace = 0, slowram = 0;
static FILE *wav; static uint32_t wav_samples;
static uint32_t hook_pc_log[64]; static int n_hook_pc;
static FILE *pclog;
static uint32_t pc_hist_lo = 0, pc_hist_hi = 0; static uint32_t *pc_hist;
static int stop_emulation = 0;
static int keyq[256], keyq_n = 0;
static FILE *reglog; /* optional custom register write log */
static uint32_t watch_lo = 0, watch_hi = 0; /* memory write watch range */
static FILE *eventlog;
static uint32_t hash_lo, hash_len;

static void elog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    FILE *f = eventlog ? eventlog : stderr;
    fprintf(f, "[f%llu v%03d] ", (unsigned long long)S.frame, S.vpos);
    vfprintf(f, fmt, ap); va_end(ap);
}

/* ------------------------------------------------------------------ */
/* interrupts */
static void update_irq(void) {
    int lvl = 0;
    if (S.intena & 0x4000) {
        uint16_t p = S.intena & S.intreq & 0x3fff;
        if (p & 0x2000) lvl = 6;
        else if (p & 0x1800) lvl = 5;
        else if (p & 0x0780) lvl = 4;
        else if (p & 0x0070) lvl = 3;
        else if (p & 0x0008) lvl = 2;
        else if (p & 0x0007) lvl = 1;
    }
    m68k_set_irq(lvl);
}
static void raise_int(uint16_t bits) { S.intreq |= bits; update_irq(); }

/* ------------------------------------------------------------------ */
/* chip memory helpers */
static inline uint16_t chip_rw(uint32_t a) { a &= (CHIP_SIZE - 1) & ~1u; return (S.chip[a] << 8) | S.chip[a + 1]; }
static inline void chip_ww(uint32_t a, uint16_t v) { a &= (CHIP_SIZE - 1) & ~1u; S.chip[a] = v >> 8; S.chip[a + 1] = v; }
static inline uint32_t reg_ptr(int r) { return ((uint32_t)S.regs[r >> 1] << 16 | S.regs[(r >> 1) + 1]) & 0x1ffffe; }
static inline void set_reg_ptr(int r, uint32_t v) { S.regs[r >> 1] = (v >> 16) & 0x1f; S.regs[(r >> 1) + 1] = v & 0xfffe; }

/* ------------------------------------------------------------------ */
/* blitter */
static inline uint16_t minterm(uint16_t a, uint16_t b, uint16_t c, uint8_t lf) {
    uint16_t r = 0;
    if (lf & 0x01) r |= ~a & ~b & ~c;
    if (lf & 0x02) r |= ~a & ~b & c;
    if (lf & 0x04) r |= ~a & b & ~c;
    if (lf & 0x08) r |= ~a & b & c;
    if (lf & 0x10) r |= a & ~b & ~c;
    if (lf & 0x20) r |= a & ~b & c;
    if (lf & 0x40) r |= a & b & ~c;
    if (lf & 0x80) r |= a & b & c;
    return r;
}

static void blit_line(int h) {
    uint16_t con0 = S.regs[0x40 >> 1], con1 = S.regs[0x42 >> 1];
    int ash = con0 >> 12; int bsh = con1 >> 12;
    uint8_t lf = con0 & 0xff;
    int16_t amod = S.regs[0x64 >> 1], bmod = S.regs[0x62 >> 1], cmod = S.regs[0x60 >> 1];
    uint32_t cpt = reg_ptr(0x48), dpt = reg_ptr(0x54);
    int32_t apt = (int16_t)S.regs[0x52 >> 1];
    uint16_t adat = S.regs[0x74 >> 1], bdat = S.regs[0x72 >> 1];
    int sing = con1 & 2; int sign = (con1 & 0x40) ? 1 : 0;
    int onedot = 0; int any = 0;
    for (int i = 0; i < h; i++) {
        uint16_t a = (adat & S.regs[0x44 >> 1]) >> ash;
        uint16_t b = ((bdat >> bsh) & 1) ? 0xffff : 0;
        uint16_t c = chip_rw(cpt);
        uint16_t d = minterm(a, b, c, lf);
        int pix = !sing || !onedot;
        if (pix) { chip_ww(dpt, d); if (d) any = 1; }
        onedot = 1;
        bsh = (bsh - 1) & 15;
        /* step */
        if (sign) apt += bmod; else apt += amod;
        if (!sign) {
            if (con1 & 0x10) { if (con1 & 0x8) { cpt -= cmod; onedot = 0; } else { cpt += cmod; onedot = 0; } }
            else { if (con1 & 0x8) { if (ash-- == 0) { ash = 15; cpt -= 2; } } else { if (++ash == 16) { ash = 0; cpt += 2; } } }
        }
        if (con1 & 0x10) { if (con1 & 0x4) { if (ash-- == 0) { ash = 15; cpt -= 2; } } else { if (++ash == 16) { ash = 0; cpt += 2; } } }
        else { if (con1 & 0x4) { cpt -= cmod; onedot = 0; } else { cpt += cmod; onedot = 0; } }
        sign = (int16_t)apt < 0;
        dpt = cpt;
    }
    S.regs[0x40 >> 1] = (con0 & 0x0fff) | (ash << 12);
    S.regs[0x42 >> 1] = (con1 & 0x0fbf) | (bsh << 12) | (sign ? 0x40 : 0);
    S.regs[0x52 >> 1] = (uint16_t)apt;
    set_reg_ptr(0x48, cpt); set_reg_ptr(0x54, dpt);
    S.bzero = !any;
}

static uint64_t blit_count;
static void do_blit(int w, int h) {
    blit_count++;
    uint16_t con0 = S.regs[0x40 >> 1], con1 = S.regs[0x42 >> 1];
    if (reglog) fprintf(reglog, "BLIT f%llu v%d con0=%04x con1=%04x w=%d h=%d A=%06x B=%06x C=%06x D=%06x mods A%d B%d C%d D%d fwm=%04x lwm=%04x adat=%04x bdat=%04x cdat=%04x\n",
        (unsigned long long)S.frame, S.vpos, con0, con1, w, h, reg_ptr(0x50), reg_ptr(0x4c), reg_ptr(0x48), reg_ptr(0x54),
        (int16_t)S.regs[0x64>>1], (int16_t)S.regs[0x62>>1], (int16_t)S.regs[0x60>>1], (int16_t)S.regs[0x66>>1],
        S.regs[0x44>>1], S.regs[0x46>>1], S.regs[0x74>>1], S.regs[0x72>>1], S.regs[0x70>>1]);
    if (con1 & 1) { blit_line(h); goto done; }
    {
        int ash = con0 >> 12, bsh = con1 >> 12;
        int useA = con0 & 0x800, useB = con0 & 0x400, useC = con0 & 0x200, useD = con0 & 0x100;
        uint8_t lf = con0 & 0xff;
        int desc = con1 & 2;
        int fill = (con1 & 0x18) != 0, efe = con1 & 0x10, fci = (con1 >> 2) & 1;
        uint32_t apt = reg_ptr(0x50), bpt = reg_ptr(0x4c), cpt = reg_ptr(0x48), dpt = reg_ptr(0x54);
        int16_t amod = S.regs[0x64 >> 1], bmod = S.regs[0x62 >> 1], cmod = S.regs[0x60 >> 1], dmod = S.regs[0x66 >> 1];
        uint16_t fwm = S.regs[0x44 >> 1], lwm = S.regs[0x46 >> 1];
        uint16_t adat = S.regs[0x74 >> 1], bdat = S.regs[0x72 >> 1], cdat = S.regs[0x70 >> 1];
        uint32_t preva = 0, prevb = 0; int any = 0; int step = desc ? -2 : 2;
        for (int y = 0; y < h; y++) {
            int carry = fci;
            for (int x = 0; x < w; x++) {
                if (useA) { adat = chip_rw(apt); apt += step; }
                if (useB) { bdat = chip_rw(bpt); bpt += step; }
                if (useC) { cdat = chip_rw(cpt); cpt += step; }
                uint16_t am = adat;
                if (x == 0) am &= fwm;
                if (x == w - 1) am &= lwm;
                uint16_t as, bs;
                if (!desc) {
                    as = (uint16_t)((((uint32_t)preva << 16) | am) >> ash);
                    bs = (uint16_t)((((uint32_t)prevb << 16) | bdat) >> bsh);
                } else {
                    as = (uint16_t)(((((uint32_t)am << 16) | preva) << ash) >> 16);
                    bs = (uint16_t)(((((uint32_t)bdat << 16) | prevb) << bsh) >> 16);
                }
                preva = am; prevb = bdat;
                uint16_t d = minterm(as, bs, cdat, lf);
                if (fill) {
                    uint16_t out = 0;
                    for (int i = 0; i < 16; i++) {
                        int bit = (d >> i) & 1;
                        if (efe) { carry ^= bit; if (carry) out |= 1 << i; }
                        else { if (carry | bit) out |= 1 << i; carry ^= bit; }
                    }
                    d = out;
                }
                if (d) any = 1;
                if (useD) { chip_ww(dpt, d); dpt += step; }
            }
            if (useA) apt += desc ? -amod : amod;
            if (useB) bpt += desc ? -bmod : bmod;
            if (useC) cpt += desc ? -cmod : cmod;
            if (useD) dpt += desc ? -dmod : dmod;
        }
        set_reg_ptr(0x50, apt); set_reg_ptr(0x4c, bpt); set_reg_ptr(0x48, cpt); set_reg_ptr(0x54, dpt);
        S.regs[0x74 >> 1] = adat; S.regs[0x72 >> 1] = bdat; S.regs[0x70 >> 1] = cdat;
        S.bzero = !any;
    }
done:
    raise_int(0x0040);
}

/* ------------------------------------------------------------------ */
/* disk: build MFM image of current track from the ADF */
static void mfm_put_long(uint16_t *buf, int *pos, uint32_t v, uint16_t *prevbit) {
    /* encodes 32 data bits as 64 MFM bits (big endian words) */
    for (int w = 0; w < 4; w++) {
        uint16_t out = 0;
        for (int i = 0; i < 8; i++) {
            int bit = (v >> 31) & 1; v <<= 1;
            int clock = (!bit && !*prevbit) ? 1 : 0;
            out = (out << 2) | (clock << 1) | bit;
            *prevbit = bit;
        }
        buf[(*pos)++] = out;
    }
}
static void mfm_put_raw(uint16_t *buf, int *pos, uint16_t w, uint16_t *prevbit) { buf[(*pos)++] = w; *prevbit = w & 1; }
/* odd/even split encoding of `n` longs */
static void mfm_put_oddeven(uint16_t *buf, int *pos, const uint32_t *data, int n, uint16_t *prevbit) {
    for (int i = 0; i < n; i++) { uint32_t v = data[i]; uint32_t odd = 0; for (int b = 0; b < 16; b++) odd |= ((v >> (2 * b + 1)) & 1) << b; mfm_put_long(buf, pos, 0, prevbit); (*pos) -= 4; /*placeholder*/ (void)odd; }
}
static uint32_t odd_bits(uint32_t v) { uint32_t r = 0; for (int b = 0; b < 16; b++) r |= ((v >> (2 * b + 1)) & 1) << b; return r; }
static uint32_t even_bits(uint32_t v) { uint32_t r = 0; for (int b = 0; b < 16; b++) r |= ((v >> (2 * b)) & 1) << b; return r; }
/* Encode 16 data bits (from a 16-bit value) to 32 MFM bits */
static void mfm16(uint16_t *buf, int *pos, uint16_t v, uint16_t *prevbit) {
    uint32_t out = 0;
    for (int i = 0; i < 16; i++) {
        int bit = (v >> 15) & 1; v <<= 1;
        int clock = (!bit && !*prevbit) ? 1 : 0;
        out = (out << 2) | (clock << 1) | bit; *prevbit = bit;
    }
    buf[(*pos)++] = out >> 16; buf[(*pos)++] = out & 0xffff;
}
#define TRACK_WORDS 6400
static uint16_t trackbuf[TRACK_WORDS];
static int build_track(int track) {
    int pos = 0; uint16_t pb = 0;
    (void)mfm_put_oddeven; (void)mfm_put_raw; (void)mfm_put_long;
    const uint8_t *td = adf + (size_t)track * 11 * 512;
    for (int s = 0; s < 11; s++) {
        uint32_t data[128];
        for (int i = 0; i < 128; i++) data[i] = (uint32_t)td[s * 512 + i * 4] << 24 | td[s * 512 + i * 4 + 1] << 16 | td[s * 512 + i * 4 + 2] << 8 | td[s * 512 + i * 4 + 3];
        uint32_t info = 0xff000000u | (track << 16) | (s << 8) | (11 - s);
        /* gap + sync */
        mfm16(trackbuf, &pos, 0x0000, &pb);
        trackbuf[pos++] = 0x4489; trackbuf[pos++] = 0x4489; pb = 1;
        uint32_t hdr[2] = { odd_bits(info), even_bits(info) };
        /* header checksum = xor of mfm longs of info + label */
        uint32_t words_start = pos;
        for (int k = 0; k < 2; k++) mfm16(trackbuf, &pos, hdr[k], &pb);
        for (int k = 0; k < 8; k++) mfm16(trackbuf, &pos, 0, &pb);
        uint32_t hsum = 0;
        for (uint32_t k = words_start; k < (uint32_t)pos; k += 2) hsum ^= ((uint32_t)trackbuf[k] << 16 | trackbuf[k + 1]);
        hsum &= 0x55555555;
        uint32_t hs[2] = { odd_bits(hsum), even_bits(hsum) };
        for (int k = 0; k < 2; k++) mfm16(trackbuf, &pos, hs[k], &pb);
        /* data checksum placeholder */
        int dsum_pos = pos; for (int k = 0; k < 2; k++) mfm16(trackbuf, &pos, 0, &pb);
        int dstart = pos;
        for (int i = 0; i < 128; i++) mfm16(trackbuf, &pos, odd_bits(data[i]), &pb);
        for (int i = 0; i < 128; i++) mfm16(trackbuf, &pos, even_bits(data[i]), &pb);
        uint32_t dsum = 0;
        for (int k = dstart; k < pos; k += 2) dsum ^= ((uint32_t)trackbuf[k] << 16 | trackbuf[k + 1]);
        dsum &= 0x55555555;
        uint16_t pb2 = 0; int p2 = dsum_pos;
        uint32_t ds[2] = { odd_bits(dsum), even_bits(dsum) };
        for (int k = 0; k < 2; k++) mfm16(trackbuf, &p2, ds[k], &pb2);
    }
    while (pos < TRACK_WORDS) trackbuf[pos++] = 0xaaaa;
    return pos;
}
static void disk_dma(uint16_t len) {
    int words = len & 0x3fff;
    uint32_t dst = reg_ptr(0x20);
    int track = S.cyl * 2 + S.side;
    if (log_disk) elog("DISK DMA read track %d (cyl %d side %d) -> %06x words %d\n", track, S.cyl, S.side, dst, words);
    if (len & 0x4000) { elog("disk write ignored\n"); S.dskblk_delay = 2; return; }
    if (!adf || track * 5632 >= (int)adf_size) { S.dskblk_delay = 2; return; }
    int n = build_track(track);
    int p = 0;
    if (S.adkcon & 0x400) { /* wordsync: start after a sync word */
        p = 3 + (rand() % 11) * (n / 11); /* somewhere */
        while (trackbuf[p] != 0x4489) p = (p + 1) % n;
        p = (p + 1) % n;
    }
    for (int i = 0; i < words; i++) { chip_ww(dst, trackbuf[p]); dst += 2; p = (p + 1) % n; }
    set_reg_ptr(0x20, dst);
    S.dskblk_delay = 2;
}

/* ------------------------------------------------------------------ */
/* CIAs */
static void cia_check_irq(void) {
    if (S.ciaa.icr & S.ciaa.icr_mask) S.intreq |= 0x0008;
    if (S.ciab.icr & S.ciab.icr_mask) S.intreq |= 0x2000;
    update_irq();
}
static void tod_inc(CIA *c) { c->tod = (c->tod + 1) & 0xffffff; if (c->tod == c->alarm) { c->icr |= 4; cia_check_irq(); } }
static void cia_tick(CIA *c, int ticks, int is_b) {
    (void)is_b;
    for (int n = 0; n < ticks; n++) {
        int ta_under = 0;
        if (c->cra & 1) {
            if (c->ta == 0) { ta_under = 1; c->icr |= 1; c->ta = c->ta_latch; if (c->cra & 8) c->cra &= ~1; }
            else c->ta--;
        }
        if (c->crb & 1) {
            int inm = (c->crb >> 5) & 3;
            int dec = (inm == 0) || (inm == 2 && ta_under);
            if (dec) {
                if (c->tb == 0) { c->icr |= 2; c->tb = c->tb_latch; if (c->crb & 8) c->crb &= ~1; }
                else c->tb--;
            }
        }
    }
}
static uint8_t cia_read(CIA *c, int r, int is_b) {
    switch (r) {
    case 0:
        if (!is_b) {
            uint8_t v = 0xff;
            if (S.fire1) v &= ~0x80;
            if (S.fire0) v &= ~0x40;
            if (S.motor) v &= ~0x20;  /* RDY */
            if (S.cyl == 0) v &= ~0x10; /* TK0 */
            v &= ~0x04; /* disk inserted */
            v = (v & ~c->ddra) | (c->pra & c->ddra);
            return v;
        }
        return (c->pra & c->ddra) | (~c->ddra & 0xff);
    case 1: return (c->prb & c->ddrb) | (~c->ddrb & 0xff);
    case 2: return c->ddra; case 3: return c->ddrb;
    case 4: return c->ta & 0xff; case 5: return c->ta >> 8;
    case 6: return c->tb & 0xff; case 7: return c->tb >> 8;
    case 8: { uint32_t t = c->tod_latched ? c->tod_latch : c->tod; c->tod_latched = 0; return t & 0xff; }
    case 9: return ((c->tod_latched ? c->tod_latch : c->tod) >> 8) & 0xff;
    case 10: c->tod_latch = c->tod; c->tod_latched = 1; return (c->tod >> 16) & 0xff;
    case 12: return c->sdr;
    case 13: { uint8_t v = c->icr; if (v & c->icr_mask) v |= 0x80; c->icr = 0; return v; }
    case 14: return c->cra; case 15: return c->crb;
    }
    return 0xff;
}
static void cia_write(CIA *c, int r, uint8_t v, int is_b) {
    switch (r) {
    case 0: c->pra = v; break;
    case 1:
        c->prb = v;
        if (is_b) {
            uint8_t out = (v & c->ddrb) | (~c->ddrb & 0xff);
            int sel0 = !(out & 0x08);
            if (sel0 && !S.sel_prev) S.motor = !(out & 0x80);
            S.sel_prev = sel0;
            S.side = (out & 0x04) ? 0 : 1;
            int step = out & 1;
            if (sel0 && step && !S.step_prev) {
                if (out & 2) { if (S.cyl > 0) S.cyl--; } else { if (S.cyl < 79) S.cyl++; }
            }
            S.step_prev = step;
        }
        break;
    case 2: c->ddra = v; break; case 3: c->ddrb = v; break;
    case 4: c->ta_latch = (c->ta_latch & 0xff00) | v; break;
    case 5: c->ta_latch = (c->ta_latch & 0xff) | (v << 8); if (!(c->cra & 1)) { c->ta = c->ta_latch; if (c->cra & 8) c->cra |= 1; } break;
    case 6: c->tb_latch = (c->tb_latch & 0xff00) | v; break;
    case 7: c->tb_latch = (c->tb_latch & 0xff) | (v << 8); if (!(c->crb & 1)) { c->tb = c->tb_latch; if (c->crb & 8) c->crb |= 1; } break;
    case 8: if (c->crb & 0x80) c->alarm = (c->alarm & 0xffff00) | v; else c->tod = (c->tod & 0xffff00) | v; break;
    case 9: if (c->crb & 0x80) c->alarm = (c->alarm & 0xff00ff) | (v << 8); else c->tod = (c->tod & 0xff00ff) | (v << 8); break;
    case 10: if (c->crb & 0x80) c->alarm = (c->alarm & 0x00ffff) | (v << 16); else c->tod = (c->tod & 0x00ffff) | (v << 16); break;
    case 12: c->sdr = v; break;
    case 13: if (v & 0x80) c->icr_mask |= v & 0x7f; else c->icr_mask &= ~(v & 0x7f); cia_check_irq(); break;
    case 14: c->cra = v & ~0x10; if (v & 0x10) c->ta = c->ta_latch; break;
    case 15: c->crb = v & ~0x10; if (v & 0x10) c->tb = c->tb_latch; break;
    }
}

/* ------------------------------------------------------------------ */
/* audio */
static void aud_start(int ch) {
    AudChan *a = &S.aud[ch];
    int base = 0xa0 + ch * 16;
    a->lc = reg_ptr(base); a->ptr = a->lc;
    a->len = S.regs[(base + 4) >> 1]; a->cnt = a->len ? a->len : 0;
    a->active = 1; a->phase = 0;
    a->pending_irq = 1;
    if (eventlog) elog("AUD%d start ptr=%06x len=%d per=%d vol=%d\n", ch, a->lc, a->len, S.regs[(base + 6) >> 1], S.regs[(base + 8) >> 1]);
}
static void audio_line(void) {
    /* raise pending start interrupts */
    for (int ch = 0; ch < 4; ch++) if (S.aud[ch].pending_irq) { S.aud[ch].pending_irq = 0; raise_int(0x80 << ch); }
    /* generate samples for this line: 44100/15625 per line */
    S.line_audio_acc += 44100.0 / (50.0 * LINES_PER_FRAME);
    while (S.line_audio_acc >= 1.0) {
        S.line_audio_acc -= 1.0;
        int l = 0, r = 0;
        for (int ch = 0; ch < 4; ch++) {
            AudChan *a = &S.aud[ch];
            int base = 0xa0 + ch * 16;
            int en = (S.dmacon & 0x200) && (S.dmacon & (1 << ch));
            if (!en) { a->active = 0; continue; }
            if (!a->active) aud_start(ch);
            int per = S.regs[(base + 6) >> 1]; if (per < 64) per = 64;
            a->phase += 3546895.0 / per / 44100.0;
            while (a->phase >= 1.0) {
                a->phase -= 1.0;
                /* each byte; words fetched = cnt */
                static int bytepos[4];
                bytepos[ch]++;
                if (bytepos[ch] >= 2) {
                    bytepos[ch] = 0;
                    a->ptr += 2;
                    if (--a->cnt == 0 || a->cnt > 0xffff) {
                        a->ptr = reg_ptr(base); a->cnt = S.regs[(base + 4) >> 1];
                        raise_int(0x80 << ch);
                    }
                }
                a->cur = (int8_t)S.chip[(a->ptr + bytepos[ch]) & (CHIP_SIZE - 1)];
            }
            int vol = S.regs[(base + 8) >> 1] & 0x7f; if (vol > 64) vol = 64;
            int s = a->cur * vol;
            if (ch == 0 || ch == 3) l += s; else r += s;
        }
        if (wav) { int16_t o[2] = { (int16_t)(l * 3), (int16_t)(r * 3) }; fwrite(o, 2, 2, wav); wav_samples++; }
    }
}

/* ------------------------------------------------------------------ */
/* copper */
static void custom_write(uint32_t reg, uint16_t v, int from_copper);
static int beam_hpos(void);
static void copper_run(int vpos, int hpos_limit) {
    if (!((S.dmacon & 0x200) && (S.dmacon & 0x80))) return;
    int guard = 0;
    while (!S.cop_halt && guard++ < 2000) {
        if (S.cop_waiting) {
            int vp = S.cop_w1 >> 8, hp = S.cop_w1 & 0xfe;
            int ve = ((S.cop_w2 >> 8) & 0x7f) | 0x80, he = S.cop_w2 & 0xfe;
            int v = vpos & 0xff;
            int ok = ((v & ve) > (vp & ve)) || (((v & ve) == (vp & ve)) && ((hpos_limit & he) >= (hp & he)));
            if (!ok) return;
            S.cop_waiting = 0;
            continue;
        }
        uint16_t w1 = chip_rw(S.cop_pc), w2 = chip_rw(S.cop_pc + 2);
        S.cop_pc += 4;
        if (!(w1 & 1)) {
            int reg = w1 & 0x1fe;
            if (reg < 0x40 && !(S.regs[0x2e >> 1] & 2)) { S.cop_halt = 1; return; }
            if (reg < 0x20) { S.cop_halt = 1; return; }
            custom_write(reg, w2, 1);
        } else if (!(w2 & 1)) {
            S.cop_w1 = w1; S.cop_w2 = w2; S.cop_waiting = 1;
            if (w1 == 0xffff && w2 == 0xfffe) { S.cop_halt = 1; return; }
        } else {
            /* SKIP */
            int vp = w1 >> 8, hp = w1 & 0xfe;
            int ve = ((w2 >> 8) & 0x7f) | 0x80, he = w2 & 0xfe;
            int v = vpos & 0xff;
            int ok = ((v & ve) > (vp & ve)) || (((v & ve) == (vp & ve)) && ((hpos_limit & he) >= (hp & he)));
            if (ok) S.cop_pc += 4;
        }
    }
}

/* ------------------------------------------------------------------ */
/* display */
static uint32_t rgb12(uint16_t c) {
    uint32_t r = (c >> 8) & 15, g = (c >> 4) & 15, b = c & 15;
    return (r * 17) << 16 | (g * 17) << 8 | (b * 17);
}
static void sprites_line(int v) {
    if (!((S.dmacon & 0x200) && (S.dmacon & 0x20))) return;
    for (int i = 0; i < 8; i++) {
        Sprite *s = &S.spr[i];
        uint32_t pr = 0x120 + i * 4;
        if (v == 0x19) {
            uint32_t p = reg_ptr(pr);
            s->pos = chip_rw(p); s->ctl = chip_rw(p + 2); set_reg_ptr(pr, p + 4);
            s->vstart = (s->pos >> 8) | ((s->ctl & 4) << 6);
            s->vstop = (s->ctl >> 8) | ((s->ctl & 2) << 7);
            s->hstart = ((s->pos & 0xff) << 1) | (s->ctl & 1);
            s->attached = (s->ctl >> 7) & 1;
            s->state = 1; s->armed = 0;
            continue;
        }
        if (v < 0x1a) continue;
        if (s->state == 1 && v == s->vstart) s->state = 2;
        if (s->state == 2) {
            uint32_t p = reg_ptr(pr);
            if (v == s->vstop) {
                s->pos = chip_rw(p); s->ctl = chip_rw(p + 2); set_reg_ptr(pr, p + 4);
                s->vstart = (s->pos >> 8) | ((s->ctl & 4) << 6);
                s->vstop = (s->ctl >> 8) | ((s->ctl & 2) << 7);
                s->hstart = ((s->pos & 0xff) << 1) | (s->ctl & 1);
                s->attached = (s->ctl >> 7) & 1;
                s->armed = 0;
                s->state = (s->pos == 0 && s->ctl == 0) ? 0 : 1;
                if (s->state == 1 && v == s->vstart) s->state = 2; /* rarely */
            } else {
                s->data = chip_rw(p); s->datb = chip_rw(p + 2); set_reg_ptr(pr, p + 4);
                s->armed = 1;
            }
        } else s->armed = 0;
    }
}

static void render_line(int v) {
    int cy = v - CANVAS_V0;
    uint16_t bplcon0 = S.regs[0x100 >> 1], bplcon1 = S.regs[0x102 >> 1], bplcon2 = S.regs[0x104 >> 1];
    uint16_t diwstrt = S.regs[0x8e >> 1], diwstop = S.regs[0x90 >> 1];
    int vstart = diwstrt >> 8, vstop = (diwstop >> 8) | ((diwstop & 0x8000) ? 0 : 0x100);
    int hstart = diwstrt & 0xff, hstop = (diwstop & 0xff) | 0x100;
    int nplanes = (bplcon0 >> 12) & 7;
    int hires = bplcon0 & 0x8000;
    int dpf = bplcon0 & 0x400;
    int ham = bplcon0 & 0x800;
    int bpl_dma = (S.dmacon & 0x200) && (S.dmacon & 0x100);
    uint8_t pix[CANVAS_W]; memset(pix, 0, sizeof pix);
    uint8_t spr_pix[CANVAS_W / 2]; memset(spr_pix, 0, sizeof spr_pix);
    uint8_t spr_idx[CANVAS_W / 2]; memset(spr_idx, 0, sizeof spr_idx);
    int in_v = v >= vstart && v < vstop;
    if (in_v && bpl_dma && nplanes > 0) {
        int ddfstrt = S.regs[0x92 >> 1] & 0xfc, ddfstop = S.regs[0x94 >> 1] & 0xfc;
        if (ddfstrt < 0x18) ddfstrt = 0x18; if (ddfstop > 0xd8) ddfstop = 0xd8;
        int nwords = hires ? ((ddfstop - ddfstrt) / 8 + 1) * 2 : (ddfstop - ddfstrt) / 8 + 1;
        if (nwords < 0) nwords = 0; if (nwords > 64) nwords = 64;
        uint16_t words[6][64];
        for (int p = 0; p < nplanes; p++) {
            uint32_t pt = reg_ptr(0xe0 + p * 4);
            for (int w = 0; w < nwords; w++) words[p][w] = chip_rw(pt + w * 2);
            int16_t mod = (p & 1) ? S.regs[0x10a >> 1] : S.regs[0x108 >> 1];
            set_reg_ptr(0xe0 + p * 4, pt + nwords * 2 + mod);
        }
        int delay1 = bplcon1 & 15, delay2 = (bplcon1 >> 4) & 15;
        /* x in hires canvas units: first pixel at DIW h = ddfstrt*2 + 17 (lowres) */
        int x0 = (ddfstrt * 2 + 17 - CANVAS_H0) * 2;
        int npix = nwords * 16;
        for (int k = 0; k < npix; k++) {
            int wi = k >> 4, bi = 15 - (k & 15);
            for (int p = 0; p < nplanes; p++) {
                int delay = (p & 1) ? delay2 : delay1;
                int bit = (words[p][wi] >> bi) & 1;
                if (!bit) continue;
                int x = hires ? x0 + k + delay * 2 : x0 + (k + delay) * 2;
                if (x < 0 || x >= CANVAS_W) continue;
                pix[x] |= 1 << p;
                if (!hires && x + 1 < CANVAS_W) pix[x + 1] |= 1 << p;
            }
        }
    }
    /* sprites */
    for (int i = 7; i >= 0; i--) {
        Sprite *s = &S.spr[i];
        if (!s->armed) continue;
        int att = (i & 1) && S.spr[i].attached && S.spr[i - 1].armed;
        for (int k = 0; k < 16; k++) {
            int b = 15 - k;
            int c = ((s->data >> b) & 1) | (((s->datb >> b) & 1) << 1);
            int x = s->hstart + 1 + k - CANVAS_H0;
            if (x < 0 || x >= CANVAS_W / 2) continue;
            if (att) {
                Sprite *e = &S.spr[i - 1];
                int ce = ((e->data >> b) & 1) | (((e->datb >> b) & 1) << 1);
                int col = ce | (c << 2);
                if (col) { spr_pix[x] = 16 + col; spr_idx[x] = i >> 1; }
                continue;
            }
            if ((i & 1) == 0 && i + 1 < 8 && S.spr[i + 1].attached && S.spr[i + 1].armed) continue; /* drawn by pair */
            if (c) { spr_pix[x] = 16 + (i >> 1) * 4 + c; spr_idx[x] = i >> 1; }
        }
    }
    if (cy < 0 || cy >= CANVAS_H) return;
    uint32_t *row = &canvas[cy * CANVAS_W];
    uint16_t *col = &S.regs[0x180 >> 1];
    int pf1p = bplcon2 & 7, pf2p = (bplcon2 >> 3) & 7, pf2pri = bplcon2 & 0x40;
    uint16_t hamcol = col[0];
    for (int x = 0; x < CANVAS_W; x++) {
        int lx = x / 2 + CANVAS_H0; /* diw h */
        int inwin = in_v && lx >= hstart && lx < hstop;
        uint16_t c;
        if (!inwin) { row[x] = rgb12(col[0]); continue; }
        uint8_t p = pix[x];
        int front_pf = 0; /* which playfield visible pixel belongs to */
        int ci;
        if (dpf) {
            int p1 = (p & 1) | ((p >> 1) & 2) | ((p >> 2) & 4);
            int p2 = ((p >> 1) & 1) | ((p >> 2) & 2) | ((p >> 3) & 4);
            if (pf2pri) { if (p2) { ci = 8 + p2; front_pf = 2; } else if (p1) { ci = p1; front_pf = 1; } else ci = 0; }
            else { if (p1) { ci = p1; front_pf = 1; } else if (p2) { ci = 8 + p2; front_pf = 2; } else ci = 0; }
            c = col[ci];
        } else if (ham && nplanes >= 5) {
            int ctl = p >> 4, val = p & 15;
            switch (ctl) { case 0: hamcol = col[val]; break; case 1: hamcol = (hamcol & 0xff0) | val; break; case 2: hamcol = (hamcol & 0x0ff) | (val << 8); break; case 3: hamcol = (hamcol & 0xf0f) | (val << 4); break; }
            c = hamcol; front_pf = p ? 1 : 0;
        } else {
            if (nplanes == 6 && (p & 32)) c = (col[p & 31] >> 1) & 0x777; else c = col[p & 31];
            front_pf = p ? 1 : 0;
        }
        int sx = x / 2;
        if (spr_pix[sx]) {
            int pair = spr_idx[sx];
            int sprite_front = 1;
            if (front_pf == 1 && !(pair < pf1p)) sprite_front = 0;
            if (front_pf == 2 && !(pair < pf2p)) sprite_front = 0;
            if (sprite_front) c = col[spr_pix[sx]];
        }
        row[x] = rgb12(c);
    }
}

/* ------------------------------------------------------------------ */
/* custom registers */
static int beam_hpos(void) { int h = m68k_cycles_run() / 2; if (h > 0xe2) h = 0xe2; return h; }
static uint16_t custom_read(uint32_t reg) {
    reg &= 0x1fe;
    switch (reg) {
    case 0x000: return S.regs[0];
    case 0x002: return S.dmacon | (S.bzero ? 0x2000 : 0);
    case 0x004: return ((S.frame & 1) ? 0x8000 : 0) | ((S.vpos >> 8) & 1);
    case 0x006: return ((S.vpos & 0xff) << 8) | beam_hpos();
    case 0x00a: return S.joy0dat;
    case 0x00c: return S.joy1dat;
    case 0x010: return S.adkcon;
    case 0x012: case 0x014: return 0;
    case 0x016: return 0xff00;
    case 0x018: return 0x3000;
    case 0x01a: return 0x0000;
    case 0x01c: return S.intena;
    case 0x01e: return S.intreq;
    }
    return 0xffff;
}
static void custom_write(uint32_t reg, uint16_t v, int from_copper) {
    reg &= 0x1fe;
    if (reglog && reg != 0x9c && !(reg >= 0x40 && reg <= 0x74) && !(reg >= 0x180 && reg < 0x1c0 && from_copper) && !(reg >= 0xe0 && reg < 0xf8 && from_copper))
        fprintf(reglog, "W f%llu v%d %s %03x=%04x pc=%06x\n", (unsigned long long)S.frame, S.vpos, from_copper ? "COP" : "CPU", reg, v, m68k_get_reg(NULL, M68K_REG_PPC));
    switch (reg) {
    case 0x020: S.regs[0x10] = v & 0x1f; return;
    case 0x022: S.regs[0x11] = v & 0xfffe; return;
    case 0x024:
        if ((v & 0x8000) && (S.dsklen_prev & 0x8000) && (S.dmacon & 0x210) == 0x210) disk_dma(v);
        else if ((v & 0x8000) && (S.dsklen_prev & 0x8000)) disk_dma(v);
        S.dsklen_prev = v; S.regs[0x12] = v; return;
    case 0x02a: return;
    case 0x02e: S.regs[0x17] = v; return;
    case 0x034: S.regs[0x1a] = v; return; /* POTGO */
    case 0x058: {
        int h = v >> 6, w = v & 63; if (!h) h = 1024; if (!w) w = 64;
        do_blit(w, h); return;
    }
    case 0x05c: S.regs[0x2e] = v; return;
    case 0x05e: { int h = S.regs[0x2e] & 0x7fff, w = v & 0x7ff; if (!h) h = 0x8000; if (!w) w = 0x800; do_blit(w, h); return; }
    case 0x080: S.regs[0x40] = v; return;
    case 0x082: S.regs[0x41] = v & 0xfffe; return;
    case 0x084: S.regs[0x42] = v; return;
    case 0x086: S.regs[0x43] = v & 0xfffe; return;
    case 0x088: S.cop_pc = reg_ptr(0x80); S.cop_waiting = 0; S.cop_halt = 0; return;
    case 0x08a: S.cop_pc = reg_ptr(0x84); S.cop_waiting = 0; S.cop_halt = 0; return;
    case 0x096: {
        uint16_t old = S.dmacon;
        if (v & 0x8000) S.dmacon |= v & 0x7ff; else S.dmacon &= ~(v & 0x7ff);
        (void)old; return;
    }
    case 0x09a: if (v & 0x8000) S.intena |= v & 0x7fff; else S.intena &= ~(v & 0x7fff); update_irq(); return;
    case 0x09c: if (v & 0x8000) S.intreq |= v & 0x7fff; else S.intreq &= ~(v & 0x7fff); cia_check_irq(); return;
    case 0x09e: if (v & 0x8000) S.adkcon |= v & 0x7fff; else S.adkcon &= ~(v & 0x7fff); return;
    }
    if (reg >= 0x140 && reg < 0x180) {
        int i = (reg - 0x140) >> 3, r = (reg >> 1) & 3;
        Sprite *s = &S.spr[i];
        if (r == 0) { s->pos = v; s->hstart = ((v & 0xff) << 1) | (s->ctl & 1); s->vstart = (v >> 8) | ((s->ctl & 4) << 6); }
        if (r == 1) { s->ctl = v; s->hstart = ((s->pos & 0xff) << 1) | (v & 1); s->attached = (v >> 7) & 1; s->armed = 0; }
        if (r == 2) { s->data = v; s->armed = 1; }
        if (r == 3) s->datb = v;
    }
    if (reg >= 0x180 && reg < 0x1c0) v &= 0xfff;
    S.regs[reg >> 1] = v;
    if (reg >= 0xa0 && reg < 0xe0 && ((reg - 0xa0) & 15) == 0xa) { /* AUDxDAT */ }
}

/* ------------------------------------------------------------------ */
/* CPU memory interface */
static int bad_logged;
unsigned int m68k_read_memory_8(unsigned int a) {
    a &= 0xffffff;
    if (a < 0x200000) return S.chip[a & (CHIP_SIZE - 1)];
    if (slowram && a >= SLOW_BASE && a < SLOW_BASE + SLOW_SIZE) return S.slow[a - SLOW_BASE];
    if ((a & 0xfff000) == 0xbfe000 && (a & 1)) return cia_read(&S.ciaa, (a >> 8) & 15, 0);
    if ((a & 0xfff000) == 0xbfd000 && !(a & 1)) return cia_read(&S.ciab, (a >> 8) & 15, 1);
    if ((a & 0xfff000) == 0xdff000) { uint16_t w = custom_read(a & ~1); return (a & 1) ? (w & 0xff) : (w >> 8); }
    if (bad_logged++ < 20) elog("read8 unmapped %06x pc=%06x\n", a, m68k_get_reg(NULL, M68K_REG_PPC));
    return 0;
}
unsigned int m68k_read_memory_16(unsigned int a) {
    a &= 0xffffff;
    if (a < 0x200000) { a &= CHIP_SIZE - 1; return (S.chip[a] << 8) | S.chip[(a + 1) & (CHIP_SIZE - 1)]; }
    if (slowram && a >= SLOW_BASE && a < SLOW_BASE + SLOW_SIZE) { a -= SLOW_BASE; return (S.slow[a] << 8) | S.slow[a + 1]; }
    if ((a & 0xfff000) == 0xdff000) return custom_read(a);
    return (m68k_read_memory_8(a) << 8) | m68k_read_memory_8(a + 1);
}
unsigned int m68k_read_memory_32(unsigned int a) { return (m68k_read_memory_16(a) << 16) | m68k_read_memory_16(a + 2); }
static void watch_check(unsigned int a, unsigned int v, int sz) {
    if (a + sz > watch_lo && a < watch_hi) elog("WATCH write%d %06x=%x pc=%06x\n", sz * 8, a, v, m68k_get_reg(NULL, M68K_REG_PPC));
}
void m68k_write_memory_8(unsigned int a, unsigned int v) {
    a &= 0xffffff;
    if (watch_hi) watch_check(a, v, 1);
    if (a < 0x200000) { S.chip[a & (CHIP_SIZE - 1)] = v; return; }
    if (slowram && a >= SLOW_BASE && a < SLOW_BASE + SLOW_SIZE) { S.slow[a - SLOW_BASE] = v; return; }
    if ((a & 0xfff000) == 0xbfe000 && (a & 1)) { cia_write(&S.ciaa, (a >> 8) & 15, v, 0); return; }
    if ((a & 0xfff000) == 0xbfd000 && !(a & 1)) { cia_write(&S.ciab, (a >> 8) & 15, v, 1); return; }
    if ((a & 0xfff000) == 0xdff000) { custom_write(a & ~1, (a & 1) ? v : (v << 8) | v, 0); return; }
    if (bad_logged++ < 20) elog("write8 unmapped %06x=%02x pc=%06x\n", a, v, m68k_get_reg(NULL, M68K_REG_PPC));
}
void m68k_write_memory_16(unsigned int a, unsigned int v) {
    a &= 0xffffff;
    if (watch_hi) watch_check(a, v, 2);
    if (a < 0x200000) { a &= CHIP_SIZE - 1; S.chip[a] = v >> 8; S.chip[(a + 1) & (CHIP_SIZE - 1)] = v; return; }
    if (slowram && a >= SLOW_BASE && a < SLOW_BASE + SLOW_SIZE) { a -= SLOW_BASE; S.slow[a] = v >> 8; S.slow[a + 1] = v; return; }
    if ((a & 0xfff000) == 0xdff000) { custom_write(a, v, 0); return; }
    m68k_write_memory_8(a, v >> 8); m68k_write_memory_8(a + 1, v & 0xff);
}
void m68k_write_memory_32(unsigned int a, unsigned int v) { m68k_write_memory_16(a, v >> 16); m68k_write_memory_16(a + 2, v & 0xffff); }
unsigned int m68k_read_disassembler_8(unsigned int a) { return a < 0x200000 ? S.chip[a & (CHIP_SIZE - 1)] : 0; }
unsigned int m68k_read_disassembler_16(unsigned int a) { return (m68k_read_disassembler_8(a) << 8) | m68k_read_disassembler_8(a + 1); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return (m68k_read_disassembler_16(a) << 16) | m68k_read_disassembler_16(a + 2); }

/* instruction hook: breakpoints, tracing, pc histogram */
static uint32_t bp_addr[32]; static int n_bp;
static int trace_count, trace_regs;
static uint32_t breaksave_pc = 0xffffffff; static char breaksave_path[256]; static int breaksave_hit;
static void save_state(const char *path);
static char outdir[512];
static void out_path(char *dst, size_t n, const char *arg) { if (arg[0] == '/') snprintf(dst, n, "%s", arg); else snprintf(dst, n, "%s/%s", outdir, arg); }
static uint32_t breakdump_pc = 0xffffffff; static char breakdump_file[256]; static int breakdump_hit;
static void dump_ram(const char *path);
void emu_instr_hook(unsigned int pc) {
    if (pc_hist && pc >= pc_hist_lo && pc < pc_hist_hi) pc_hist[(pc - pc_hist_lo) >> 1]++;
    for (int i = 0; i < n_bp; i++) if (pc == bp_addr[i]) {
        elog("BP %06x d0=%08x d1=%08x d2=%08x d3=%08x a0=%08x a1=%08x a2=%08x a6=%08x sp=%08x\n", pc,
            m68k_get_reg(NULL, M68K_REG_D0), m68k_get_reg(NULL, M68K_REG_D1), m68k_get_reg(NULL, M68K_REG_D2), m68k_get_reg(NULL, M68K_REG_D3),
            m68k_get_reg(NULL, M68K_REG_A0), m68k_get_reg(NULL, M68K_REG_A1), m68k_get_reg(NULL, M68K_REG_A2), m68k_get_reg(NULL, M68K_REG_A6), m68k_get_reg(NULL, M68K_REG_SP));
    }
    if (pc >= 0xf80000) { elog("PC in ROM %06x (reset?) — stopping\n", pc); stop_emulation = 1; m68k_end_timeslice(); }
    if (pc == breakdump_pc && !breakdump_hit) { breakdump_hit = 1; dump_ram(breakdump_file); }
    if (pc == breaksave_pc && !breaksave_hit) { breaksave_hit = 1; elog("breaksave hit at %06x\n", pc); m68k_end_timeslice(); }
    if (trace_count > 0 && pclog) {
        char buf[128]; m68k_disassemble(buf, pc, M68K_CPU_TYPE_68000);
        if (trace_regs) fprintf(pclog, "%06x %-36s d0=%08x d1=%08x d2=%08x d3=%08x a0=%08x a1=%08x a2=%08x a3=%08x a4=%08x a5=%08x a6=%08x\n", pc, buf,
            m68k_get_reg(NULL, M68K_REG_D0), m68k_get_reg(NULL, M68K_REG_D1), m68k_get_reg(NULL, M68K_REG_D2), m68k_get_reg(NULL, M68K_REG_D3),
            m68k_get_reg(NULL, M68K_REG_A0), m68k_get_reg(NULL, M68K_REG_A1), m68k_get_reg(NULL, M68K_REG_A2), m68k_get_reg(NULL, M68K_REG_A3), m68k_get_reg(NULL, M68K_REG_A4), m68k_get_reg(NULL, M68K_REG_A5), m68k_get_reg(NULL, M68K_REG_A6));
        else fprintf(pclog, "%06x %s\n", pc, buf);
        trace_count--;
    }
    (void)hook_pc_log; (void)n_hook_pc;
}

/* ------------------------------------------------------------------ */
/* PNG writer */
static void png_chunk(FILE *f, const char *type, const uint8_t *data, uint32_t len) {
    uint8_t b[4] = { len >> 24, len >> 16, len >> 8, len };
    fwrite(b, 1, 4, f); fwrite(type, 1, 4, f); if (len) fwrite(data, 1, len, f);
    uint32_t crc = crc32(0, (const uint8_t *)type, 4); crc = crc32(crc, data, len);
    uint8_t c[4] = { crc >> 24, crc >> 16, crc >> 8, crc }; fwrite(c, 1, 4, f);
}
static void write_png(const char *path, const uint32_t *px, int w, int h, int xstep) {
    int ow = w / xstep;
    size_t rawlen = (size_t)(ow * 3 + 1) * h; uint8_t *raw = malloc(rawlen);
    for (int y = 0; y < h; y++) {
        uint8_t *r = raw + (size_t)y * (ow * 3 + 1); *r++ = 0;
        for (int x = 0; x < ow; x++) { uint32_t p = px[y * w + x * xstep]; *r++ = p >> 16; *r++ = p >> 8; *r++ = p; }
    }
    uLongf clen = compressBound(rawlen); uint8_t *comp = malloc(clen);
    compress2(comp, &clen, raw, rawlen, 6);
    FILE *f = fopen(path, "wb"); if (!f) { perror(path); free(raw); free(comp); return; }
    fwrite("\x89PNG\r\n\x1a\n", 1, 8, f);
    uint8_t ihdr[13] = { ow >> 24, ow >> 16, ow >> 8, ow, h >> 24, h >> 16, h >> 8, h, 8, 2, 0, 0, 0 };
    png_chunk(f, "IHDR", ihdr, 13); png_chunk(f, "IDAT", comp, clen); png_chunk(f, "IEND", NULL, 0);
    fclose(f); free(raw); free(comp);
}

/* ------------------------------------------------------------------ */
/* input script: lines "<frame> <cmd> [args]" */
typedef struct { uint64_t frame; char cmd[32]; char arg[256]; } Ev;
static Ev evs[65536]; static int n_evs, ev_i;
static int joy_up, joy_down, joy_left, joy_right;
static void update_joy(void) {
    /* JOY1DAT encoding */
    int y1 = joy_up ^ joy_left, y0 = joy_down ^ joy_right; /* bit9 = left ^ up? see HRM */
    uint16_t v = 0;
    if (joy_right) v |= 0x0002; if (joy_left) v |= 0x0200;
    int b8 = joy_up ^ joy_left, b0 = joy_down ^ joy_right;
    if (b8) v |= 0x0100; if (b0) v |= 0x0001;
    (void)y1; (void)y0;
    S.joy1dat = v;
}

static const int save_regs[] = { M68K_REG_D0, M68K_REG_D1, M68K_REG_D2, M68K_REG_D3, M68K_REG_D4, M68K_REG_D5, M68K_REG_D6, M68K_REG_D7,
    M68K_REG_A0, M68K_REG_A1, M68K_REG_A2, M68K_REG_A3, M68K_REG_A4, M68K_REG_A5, M68K_REG_A6, M68K_REG_A7,
    M68K_REG_PC, M68K_REG_SR, M68K_REG_USP, M68K_REG_ISP };
#define N_SAVE_REGS (int)(sizeof save_regs / sizeof save_regs[0])
static void save_state(const char *path) {
    FILE *f = fopen(path, "wb"); if (!f) { perror(path); return; }
    uint32_t r[N_SAVE_REGS]; for (int i = 0; i < N_SAVE_REGS; i++) r[i] = m68k_get_reg(NULL, save_regs[i]);
    fwrite(r, 4, N_SAVE_REGS, f); fwrite(&S, sizeof S, 1, f); fclose(f);
    elog("state saved to %s\n", path);
}
static void load_state(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    uint32_t r[N_SAVE_REGS]; fread(r, 4, N_SAVE_REGS, f); fread(&S, sizeof S, 1, f); fclose(f);
    m68k_pulse_reset();
    m68k_set_reg(M68K_REG_SR, r[17]); m68k_set_reg(M68K_REG_USP, r[18]); m68k_set_reg(M68K_REG_ISP, r[19]);
    for (int i = 0; i < 17; i++) m68k_set_reg(save_regs[i], r[i]);
    m68k_set_reg(M68K_REG_SR, r[17]);
    update_irq();
}
static void dump_ram(const char *path) { FILE *f = fopen(path, "wb"); if (!f) { elog("cannot write %s\n", path); return; } fwrite(S.chip, 1, CHIP_SIZE, f); fclose(f); elog("chip ram dumped to %s\n", path); }
static void do_event(Ev *e) {
    char path[1024];
    if (!strcmp(e->cmd, "up")) joy_up = atoi(e->arg);
    else if (!strcmp(e->cmd, "down")) joy_down = atoi(e->arg);
    else if (!strcmp(e->cmd, "left")) joy_left = atoi(e->arg);
    else if (!strcmp(e->cmd, "right")) joy_right = atoi(e->arg);
    else if (!strcmp(e->cmd, "fire")) S.fire1 = atoi(e->arg);
    else if (!strcmp(e->cmd, "fire0")) S.fire0 = atoi(e->arg);
    else if (!strcmp(e->cmd, "key")) { int code = 0, down = 1; sscanf(e->arg, "%i %d", &code, &down); keyq[keyq_n++ & 255] = (code & 0x7f) | (down ? 0 : 0x80); }
    else if (!strcmp(e->cmd, "shot")) { snprintf(path, sizeof path, "%s/%s.png", outdir, e->arg[0] ? e->arg : "shot"); write_png(path, canvas, CANVAS_W, CANVAS_H, 2); elog("shot %s\n", path); }
    else if (!strcmp(e->cmd, "save")) { snprintf(path, sizeof path, "%s", e->arg); save_state(path); }
    else if (!strcmp(e->cmd, "dump")) { out_path(path, sizeof path, e->arg); dump_ram(path); }
    else if (!strcmp(e->cmd, "poke")) { unsigned a, v, sz = 1; sscanf(e->arg, "%x %x %u", &a, &v, &sz); if (sz == 1) m68k_write_memory_8(a, v); else if (sz == 2) m68k_write_memory_16(a, v); else m68k_write_memory_32(a, v); }
    else if (!strcmp(e->cmd, "trace")) { trace_count = atoi(e->arg); if (!pclog) { snprintf(path, sizeof path, "%s/trace.txt", outdir); pclog = fopen(path, "w"); } }
    else if (!strcmp(e->cmd, "regs")) {
        elog("REGS pc=%06x sr=%04x d0-7=%08x %08x %08x %08x %08x %08x %08x %08x a0-7=%08x %08x %08x %08x %08x %08x %08x %08x\n", m68k_get_reg(NULL, M68K_REG_PC), m68k_get_reg(NULL, M68K_REG_SR),
            m68k_get_reg(NULL, M68K_REG_D0), m68k_get_reg(NULL, M68K_REG_D1), m68k_get_reg(NULL, M68K_REG_D2), m68k_get_reg(NULL, M68K_REG_D3), m68k_get_reg(NULL, M68K_REG_D4), m68k_get_reg(NULL, M68K_REG_D5), m68k_get_reg(NULL, M68K_REG_D6), m68k_get_reg(NULL, M68K_REG_D7),
            m68k_get_reg(NULL, M68K_REG_A0), m68k_get_reg(NULL, M68K_REG_A1), m68k_get_reg(NULL, M68K_REG_A2), m68k_get_reg(NULL, M68K_REG_A3), m68k_get_reg(NULL, M68K_REG_A4), m68k_get_reg(NULL, M68K_REG_A5), m68k_get_reg(NULL, M68K_REG_A6), m68k_get_reg(NULL, M68K_REG_A7));
    }
    else if (!strcmp(e->cmd, "dumpr")) { unsigned a, l; char fn[256]; if (sscanf(e->arg, "%x %x %255s", &a, &l, fn) == 3) { out_path(path, sizeof path, fn); FILE *df = fopen(path, "wb"); if (!df) { elog("cannot write %s\n", path); return; } for (unsigned i = 0; i < l; i++) fputc(m68k_read_memory_8(a + i), df); fclose(df); elog("dumped %06x+%x to %s\n", a, l, path); } }
    else if (!strcmp(e->cmd, "breaksave")) { unsigned a; char fn[256]; if (sscanf(e->arg, "%x %255s", &a, fn) == 2) { breaksave_pc = a; snprintf(breaksave_path, sizeof breaksave_path, "%s", fn); } }
    else if (!strcmp(e->cmd, "breakdump")) { unsigned a; char fn[256]; if (sscanf(e->arg, "%x %255s", &a, fn) == 2) { breakdump_pc = a; out_path(breakdump_file, sizeof breakdump_file, fn); breakdump_hit = 0; } }
    else if (!strcmp(e->cmd, "tracer")) { trace_regs = 1; trace_count = atoi(e->arg); if (!pclog) { snprintf(path, sizeof path, "%s/trace.txt", outdir); pclog = fopen(path, "w"); } }
    else if (!strcmp(e->cmd, "chipdump")) {
        out_path(path, sizeof path, e->arg); FILE *cf = fopen(path, "wb"); if (!cf) { elog("cannot write %s\n", path); return; }
        fwrite(S.chip, 1, CHIP_SIZE, cf);
        for (int i = 0; i < 0x100; i++) { uint16_t r = S.regs[i]; if (i == 1) r = S.dmacon; fputc(r >> 8, cf); fputc(r & 0xff, cf); }
        uint16_t x[4] = { S.dmacon, S.intena, S.intreq, S.adkcon };
        for (int i = 0; i < 4; i++) { fputc(x[i] >> 8, cf); fputc(x[i] & 0xff, cf); }
        fclose(cf); elog("chipdump %s\n", path);
    }
    else if (!strcmp(e->cmd, "quit")) stop_emulation = 1;
    update_joy();
}

static void run_frame(void) {
    for (S.vpos = 0; S.vpos < LINES_PER_FRAME && !stop_emulation; S.vpos++) {
        int v = S.vpos;
        if (v == 0) {
            S.cop_pc = reg_ptr(0x80); S.cop_waiting = 0; S.cop_halt = 0;
            raise_int(0x0020); /* VERTB */
            tod_inc(&S.ciaa);
            for (int i = 0; i < 8; i++) { S.spr[i].armed = 0; if (S.spr[i].state) S.spr[i].state = 0; }
        }
        copper_run(v, 0x30);
        sprites_line(v);
        render_line(v);
        m68k_execute(CYCLES_PER_LINE);
        if (breaksave_hit == 1) { breaksave_hit = 2; save_state(breaksave_path); stop_emulation = 1; }
        copper_run(v, 0xe2);
        tod_inc(&S.ciab);
        /* CIA E clock: 709379 Hz -> ~45.3 ticks/line */
        S.ciaa.tick_acc += 709379.0 / (50.0 * LINES_PER_FRAME);
        int t = (int)S.ciaa.tick_acc; S.ciaa.tick_acc -= t;
        cia_tick(&S.ciaa, t, 0); cia_tick(&S.ciab, t, 1);
        if (S.dskblk_delay && --S.dskblk_delay == 0) raise_int(0x0002);
        if (S.key_delay > 0) S.key_delay--;
        else if (keyq_n > 0 && v == 100) {
            int k = keyq[0]; memmove(keyq, keyq + 1, sizeof(int) * (keyq_n - 1)); keyq_n--;
            uint8_t raw = ((k & 0x7f) << 1) | ((k & 0x80) ? 1 : 0);
            S.ciaa.sdr = ~raw; S.ciaa.icr |= 8; S.key_delay = 313 * 2;
        }
        audio_line();
        cia_check_irq();
    }
    S.frame++;
}

static void usage(void) {
    fprintf(stderr,
        "emu --adf FILE [options]\n"
        "  --frames N            run N frames (default 500)\n"
        "  --script FILE         input/event script (frame cmd arg)\n"
        "  --out DIR             output directory (default out)\n"
        "  --shot-every N        save a screenshot every N frames\n"
        "  --load-state FILE     start from a saved state\n"
        "  --wav FILE            record audio\n"
        "  --reglog FILE         log custom register writes + blits\n"
        "  --events FILE         event log file (disk, audio, bp)\n"
        "  --bp ADDR             breakpoint log (repeatable)\n"
        "  --watch LO HI         log CPU writes in [LO,HI)\n"
        "  --pchist LO HI FILE   pc histogram over range\n"
        "  --slowram             enable 512K slow RAM at $C00000\n"
        "  --hash HEXLO HEXLEN   print FNV-1a hash of RAM region after every frame (lockstep vs platoon-headless)\n"
        "script cmds: up/down/left/right/fire/fire0 0|1, key CODE 0|1, shot NAME, save PATH, dump FILE,\n"
        "  chipdump FILE (chip RAM + custom regs for platoon-headless --chipdump),\n  dumpr HEXADDR HEXLEN FILE, poke HEXADDR HEXVAL SIZE, trace N, tracer N (with regs), regs,\n"
        "  breakdump HEXPC FILE (dump chip RAM the first time pc is hit), key CODE uses C %%i parsing: write hex as 0x46,\n"
        "  paths for dump/dumpr/chipdump/breakdump are relative to --out unless absolute; events are sorted by frame,\n"
        "  breaksave HEXPC PATH (save state+stop when pc hit; note: saved mid-line), quit\n");
}

int main(int argc, char **argv) {
    const char *adfpath = NULL, *script = NULL, *loadst = NULL, *wavpath = NULL, *histfile = NULL;
    long frames = 500; int shot_every = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--adf")) adfpath = argv[++i];
        else if (!strcmp(argv[i], "--frames")) frames = atol(argv[++i]);
        else if (!strcmp(argv[i], "--script")) script = argv[++i];
        else if (!strcmp(argv[i], "--out")) snprintf(outdir, sizeof outdir, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--shot-every")) shot_every = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--load-state")) loadst = argv[++i];
        else if (!strcmp(argv[i], "--wav")) wavpath = argv[++i];
        else if (!strcmp(argv[i], "--reglog")) reglog = fopen(argv[++i], "w");
        else if (!strcmp(argv[i], "--events")) eventlog = fopen(argv[++i], "w");
        else if (!strcmp(argv[i], "--bp")) bp_addr[n_bp++] = strtoul(argv[++i], NULL, 16);
        else if (!strcmp(argv[i], "--watch")) { watch_lo = strtoul(argv[++i], NULL, 16); watch_hi = strtoul(argv[++i], NULL, 16); }
        else if (!strcmp(argv[i], "--pchist")) { pc_hist_lo = strtoul(argv[++i], NULL, 16); pc_hist_hi = strtoul(argv[++i], NULL, 16); histfile = argv[++i]; pc_hist = calloc((pc_hist_hi - pc_hist_lo) / 2 + 1, 4); }
        else if (!strcmp(argv[i], "--slowram")) slowram = 1;
        else if (!strcmp(argv[i], "--hash")) { hash_lo = strtoul(argv[++i], NULL, 16); hash_len = strtoul(argv[++i], NULL, 16); }
        else { usage(); return 1; }
    }
    if (!adfpath) { usage(); return 1; }
    FILE *f = fopen(adfpath, "rb"); if (!f) { perror(adfpath); return 1; }
    fseek(f, 0, SEEK_END); adf_size = ftell(f); fseek(f, 0, SEEK_SET); adf = malloc(adf_size); fread(adf, 1, adf_size, f); fclose(f);
    char cmd[600]; snprintf(cmd, sizeof cmd, "mkdir -p '%s'", outdir); system(cmd);
    if (script) {
        FILE *sf = fopen(script, "r"); char line[512];
        while (sf && fgets(line, sizeof line, sf)) {
            if (line[0] == '#' || line[0] == '\n') continue;
            Ev *e = &evs[n_evs]; e->arg[0] = 0;
            int n = sscanf(line, "%llu %31s %255[^\n]", (unsigned long long *)&e->frame, e->cmd, e->arg);
            if (n >= 2 && n_evs < 65536) n_evs++;
        }
        if (sf) fclose(sf);
        for (int a = 1; a < n_evs; a++) { Ev t = evs[a]; int b = a - 1; while (b >= 0 && evs[b].frame > t.frame) { evs[b + 1] = evs[b]; b--; } evs[b + 1] = t; }
    }
    if (wavpath) {
        wav = fopen(wavpath, "wb"); uint8_t hdr[44] = { 0 }; fwrite(hdr, 1, 44, wav);
    }
    if (!outdir[0]) snprintf(outdir, sizeof outdir, "out");
    m68k_init(); m68k_set_cpu_type(M68K_CPU_TYPE_68000);
    memset(&S, 0, sizeof S);
    if (loadst) load_state(loadst);
    else {
        /* HLE of the cracked bootblock: load 22 sectors from $70c00 to $76000, jump $7613a */
        memcpy(&S.chip[0x76000], adf + 0x70c00, 0x2c00);
        m68k_pulse_reset();
        m68k_set_reg(M68K_REG_SR, 0x2700);
        m68k_set_reg(M68K_REG_SP, 0x7fffc);
        m68k_set_reg(M68K_REG_PC, 0x7613a);
        S.ciaa.ddra = 0x03; S.ciab.ddrb = 0xff; S.ciab.prb = 0xff; S.sel_prev = 0;
        S.intena = 0; S.dmacon = 0;
    }
    uint64_t start = S.frame;
    while ((long)(S.frame - start) < frames && !stop_emulation) {
        while (ev_i < n_evs && evs[ev_i].frame <= S.frame - start) do_event(&evs[ev_i++]);
        if (stop_emulation) break;
        run_frame();
        if (hash_len) { uint64_t h = 0xcbf29ce484222325ULL; for (uint32_t k = 0; k < hash_len; k++) { h ^= S.chip[(hash_lo + k) & (CHIP_SIZE - 1)]; h *= 0x100000001b3ULL; } printf("frame %llu hash %016llx\n", (unsigned long long)(S.frame - start), (unsigned long long)h); }
        if (shot_every && (S.frame - start) % shot_every == 0) {
            char path[1024]; snprintf(path, sizeof path, "%s/f%06llu.png", outdir, (unsigned long long)(S.frame - start));
            write_png(path, canvas, CANVAS_W, CANVAS_H, 2);
        }
    }
    while (ev_i < n_evs) { if (!strcmp(evs[ev_i].cmd, "shot") || !strcmp(evs[ev_i].cmd, "save") || !strcmp(evs[ev_i].cmd, "dump")) do_event(&evs[ev_i]); ev_i++; }
    if (wav) {
        uint32_t data = wav_samples * 4; uint8_t h[44];
        memcpy(h, "RIFF", 4); uint32_t v = 36 + data; memcpy(h + 4, &v, 4); memcpy(h + 8, "WAVEfmt ", 8);
        v = 16; memcpy(h + 16, &v, 4); uint16_t s = 1; memcpy(h + 20, &s, 2); s = 2; memcpy(h + 22, &s, 2);
        v = 44100; memcpy(h + 24, &v, 4); v = 44100 * 4; memcpy(h + 28, &v, 4); s = 4; memcpy(h + 32, &s, 2); s = 16; memcpy(h + 34, &s, 2);
        memcpy(h + 36, "data", 4); memcpy(h + 40, &data, 4); fseek(wav, 0, SEEK_SET); fwrite(h, 1, 44, wav); fclose(wav);
    }
    if (pc_hist) {
        FILE *hf = fopen(histfile, "w");
        for (uint32_t a = pc_hist_lo; a < pc_hist_hi; a += 2) if (pc_hist[(a - pc_hist_lo) >> 1]) fprintf(hf, "%06x %u\n", a, pc_hist[(a - pc_hist_lo) >> 1]);
        fclose(hf);
    }
    elog("done: %llu frames, %llu blits, pc=%06x\n", (unsigned long long)S.frame, (unsigned long long)blit_count, m68k_get_reg(NULL, M68K_REG_PC));
    if (reglog) fclose(reglog); if (eventlog) fclose(eventlog); if (pclog) fclose(pclog);
    return 0;
}
