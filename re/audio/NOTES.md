# Platoon (Amiga) - audio module: David Whittaker music + sound-effect driver

Status: **complete and verified**. The Python re-implementation (`replayer.py`) produces a Paula register-write stream
that is *identical, write for write and in the same order*, to the original code running in `tools/amiga/emu` for every
song (full loops), every sound effect (all 12 synth ids + id $0c clamp, all 6 sample ids, channel 0 and channel 2
routing, with and without music) and three random-play in-game sessions (sections 0/1/2, 6000 frames each). Mixed through
an emulator-identical Paula model (`replayer.Paula`) the output WAV is **bit-identical** to the emulator's `--wav`
capture (title 60 s, songs 1-6 90 s each, two sfx test runs; 0 differing samples). See section 10 for the numbers.

Files in `re/audio/`:

| file | purpose |
|---|---|
| `NOTES.md` | this spec |
| `replayer.py` | faithful Python port of every driver routine + kernel wrappers + emulator-identical Paula mixer (read this next to the pseudocode below; it is the reference implementation for the Swift port) |
| `verify.py` | runs the emulator with breakpoints + `--reglog` (+ `--wav`), replays the recorded API calls through `replayer.py`, compares the register streams and WAVs |
| `extract.py` | writes all tables to `assets/audio.json`, all samples/waveforms as WAV, renders every song and sfx through the replayer to WAV; `--verify` re-runs the emulator comparisons |
| `labels.txt`, `icomments.txt`, `mklisting.py` -> `audio.s` | annotated rdis listing of $2800-$430a (code + tables), from the disk-initial RAM image |
| `assets/` | `audio.json` (every table decoded), `instruments/inst0-7.wav`, `sfx_samples/sfx_80-85.wav`, `synth_waves/wave0-5.wav` + `waves.png`, `songs/song0-6.wav` (one full loop each, driver-rendered), `sfx/sfx_00-0b,80-85.wav` (driver-rendered) |
| `coverage.hist` | merged executed-PC histogram of the driver from all tests (used by rdis) |
| `work/*.txt` | emulator scripts (song selection, sfx tests, random play) |
| `re/states/audio_song{0..6}.state` | title screen, frame 430, song N just started (music on, FX off for 1-6) |

---------------------------------------------------------------------------------------------------------------------

## 1. Scope and how to reach it

The driver lives in the resident main program (tracks 1-17, loaded at $400; **RAM address X = ADF offset X + $1200**
for the whole $2538-$17000 area). All music data, instrument samples and sound-effect samples are resident too
($2800-$ef86); the three load sections contain **no audio data** and never touch Paula directly - they only call the
kernel wrappers. Nothing in $2538-$f800 that belongs to audio is modified by section loads (verified by diffing the title
RAM against `re/dumps/ram_section{0,1,2}.bin`: only driver state variables differ).

Reaching content in the emulator:
* Title music (song 0) starts at frame 125 after boot (`./tools/amiga/emu --adf re/platoon_darc.adf --frames 3000`).
  The title sequence plays sample sfx $80 at frames 1093, 2261, 3429, ... (every 1168 frames).
* **Any song N on the title screen** (F10 trick): the F10 key ($59) handler in the level-3 interrupt cycles the option
  byte ($12e44: 3->0->1->2->3) and re-plays the song number stored in $12cce. Script:
  ```
  400 poke 12cce N 2
  402 key 0x59 1
  408 key 0x59 0      (options -> 0: music+fx off, song N remembered)
  422 key 0x59 1
  428 key 0x59 0      (options -> 1: music on -> init song N at frame 423, first tick frame 424)
  ```
  (`key` takes C-style numbers: use `0x59`, not `59`.) Saved as `re/states/audio_songN.state` (frame 430).
* **Any sound effect** on the title: patch the F10 handler's `clr.w d0` at $10f8a (the sfx id it plays after a toggle)
  with `moveq #id,d0` = $70xx: `F poke 10f8a 70xx 2` then press F10; the sfx plays when the new option state has the FX
  bit (states 2 and 3). `work/sfxtest.txt` does all 18 ids twice (once with music stopped, once with music re-started);
  `work/sfxtest3.txt` additionally NOPs the music re-init (`300 poke 10f86 4e714e71 4`) so that two synth sfx overlap
  and the second one is routed to channel 2.
* In-game: `re/states/section{0,1,2}_play.state` (section 0 is on the "CHOOSE YOUR MAN" screen: press fire). Holding
  fire in section 1 (tunnels) retriggers sample $83 every 4 frames; in section 2 fire plays $82.

Verification commands (all from `re/audio/`):
```
python3 verify.py title 3000 --wav
python3 verify.py song4 4500 --script work/song4.txt --wav
python3 verify.py sfxtest 5600 --script work/sfxtest.txt --wav
python3 verify.py sec1 6000 --state ../states/section1_play.state --script work/rand1.txt
python3 extract.py            # full renders (~5 min); --quick for 20 s per song; --verify to rerun all comparisons
```

---------------------------------------------------------------------------------------------------------------------

## 2. Architecture overview

* One routine `play` ($2990) is called **once per vertical blank** (50 Hz PAL) from the kernel level-3 handler
  ($10eac -> `jsr $280e` at $10f50), after the kernel's CIA/timer work and before the F10/TAB key checks. It runs the
  music (4 channels) and then the sound-effect updater. It keeps running while the game is paused (TAB).
* No audio interrupts are used (INTENA is $a020: master+EXTER+VERTB). No ADKCON modulation (always cleared to $00ff).
* The driver writes the CIA-A PRA bit 1 (`bset #1,$bfe001`) at every song init and every sfx trigger: power LED off =
  **Amiga audio low-pass filter OFF**. But the resident disk loader switches it ON again after every load
  (`bclr #1,$bfe001` at $db4, also $7637c in the boot loader), so on an A500 the LED filter IS heard from the end of a
  load to the next song init / sfx: e.g. the title tune after the hiscore load (~18 s up to the first sfx) and the
  loading tune at each section load. The port models it (Paula `accurate`, port/verify/timing.md).
* Periods below ~114 can't be fed by the one audio DMA slot per line: songs 1 and 6 use 86-113 about 11 % of the time;
  on an A500 the loop then advances one word per line (pitch capped). tools/amiga/emu (and replayer.py) don't model it.
* Music and sfx share the 4 Paula channels. A 12-byte **shadow register block per channel** ($4084) always receives the
  music's intended LC/LEN/PER/VOL; while a sound effect owns a channel (`shadow+$b != 0`) the music keeps running but
  its hardware writes to that channel are suppressed; when the sfx ends the shadow values are written back.
* All tempo is in whole frames ("ticks"); every song has speed 0, so **one music tick = one vblank = 20 ms**.
* All addresses in the code are PC-relative to a3 = $2800; the tables below give absolute addresses.

API (jump block at $2800, each entry saves registers and calls the worker):

| entry | worker | args | called by |
|---|---|---|---|
| $2800 `api_init_song` | $2854 | d0.b = song 0..6 | kernel $10c00 |
| $280e `api_play` | $2990 | - | level-3 handler $10f50 (every vblank) |
| $281c `api_stop` | $28e8 | - | kernel $10c00 (music option off), $10c3a; internally by init and cmd $84 |
| $282a `api_resume` | $2960 | - | never |
| $2838 `api_sfx` | $3c90 | d0.w = (channel<<8) \| id | kernel $10c92 |
| $2846 `api_sfx_stop_all` | $2942 | - | never |

Kernel wrappers (main program, kernel area; a6 = $12dde):

| addr | jump-table | function |
|---|---|---|
| $10c00 | $f868 | **play music d0**: `$12cce := d0.w`; if option bit0 ($12e44 bit 0 "MUZAK") set: `jsr $2800` else `jsr $281c`; then master volume `$2d98 := $40` in both cases |
| $10c3a | - | music off: `jsr $281c`; `$2d98 := 0` |
| $fed6 | - | fade: if `$2d98 != 0` then `$2d98 -= 1` (game-over screen calls it once per frame) |
| $10c50 | $f86c | **play sfx d0**: if option bit1 ($12e44 bit 1 "FX") clear -> return. d0 &= $ff. If d0 < $80 (synth): channel 0, but channel 2 if a sfx is active on channel 0 (`tst.b $4012`) -> `jsr $2838` once. If d0 >= $82: `jsr $2838` with d0 (channel 0) then with d0\|$200 (channel 2). If d0 = $80/$81: d0\|$100 (channel 1) then d0\|$300 (channel 3). (Sample sfx always play on a left+right pair: ch0+ch2 or ch1+ch3.) |
| $10f5c.. | - | in level-3 handler, after play: key F10 ($59) edge -> `$12e44 = ($12e44+1)&3`, `bsr $10c00` with d0=$12cce, then `bsr $10c50` with d0=0 (click) |
| $f922 | - | first boot: `$12e44 := 3` (music+fx on) |

Option byte $12e44 = `$66(a6)`: bit0 music, bit1 fx; shown on the title as "MUZAK: ON/OFF  FX: ON/OFF" by $10ca2.

---------------------------------------------------------------------------------------------------------------------

## 3. Memory map / RAM variables (all absolute; initial values are the disk image)

### 3.1 Music globals
| addr | size | name | init | meaning |
|---|---|---|---|---|
| $2d80 | 11 w | cmd jump table | | offsets (rel $2800) of the handlers for commands $80..$8a |
| $2d96 | w | tempo | 0 | duration unit: duration bytes $e0-$ff give (b-$df)*tempo ticks. Set by init (signed song byte 0) and cmd $8a |
| $2d98 | w | master volume | $40 | 0..64; written by the kernel ($40 on every song request, 0 by $10c3a, -1/frame by $fed6) |
| $2d9a | b | speed | 0 | added to $2d9c each vblank; if the add carries, the music tick is skipped (sfx still run). All songs: 0 |
| $2d9b | b | speed copy | 0 | written at init, never read |
| $2d9c | b | speed accumulator | 0 | never reset |
| $2d9d | b | song loaded | 0 | $ff after init; 0 after cmd $84; tested by resume |
| $2d9e | b | tables built | 0 | $ff after `init_tables` |
| $2d9f | b | playing | 0 | $ff = process music in play |
| $2da0 | b | global transpose | 0 | cleared at init, set by cmd $85 |
| $2da1 | b | NTSC counter | 6 | only used if $2da2 != 0 |
| $2da2 | b | NTSC enable | 0 | never set by the game (if set: every 6th vblank play returns immediately, skipping sfx too) |
| $2da4 | l | silence ptr | 0 -> $89c0 | 64 zero bytes after the last instrument sample |
| $2da8 | w | PWM direction | 0 | 0 = widening ($c0c0 writes), $ffff = narrowing ($3f3f writes) |
| $2daa | w | PWM offset | 0 -> $20 | byte offset in instrument 5's waveform, $20..$2c |
| $2dac | 4 x $30 | channel structs | 0 | ch0 $2dac, ch1 $2ddc, ch2 $2e0c, ch3 $2e3c |
| $3c8e | b | sample-sfx table built | 0 | |
| $3ffa | 4 x $22 | sfx channel structs | 0 | ch0 $3ffa, ch1 $401c, ch2 $403e, ch3 $4060 |
| $4082 | w | last sfx request | 0 | $4082 = channel, $4083 = id |
| $4084 | 4 x 12 | shadow registers | 0 | ch0 $4084, ch1 $4090, ch2 $409c, ch3 $40a8 |
| $41fc | l | synth wave base | 0 -> $8a00 | |

### 3.2 Music channel struct (a0 = $2dac + $30*ch)
| off | size | meaning |
|---|---|---|
| +$00 | b | flags: bit1 = portamento active (whole byte cleared at every new event) |
| +$01 | b | vibrato state: 0 = off; set to $ff by cmd $86; bit7 = moving up (pos += speed), bit0 = add (1) / subtract (0) |
| +$02 | b | current note (raw pattern value) |
| +$03 | b | channel transpose (cmd $88) |
| +$04 | l | pattern read pointer |
| +$08 | w | sequence offset (rel $2800) |
| +$0a | w | sequence index (byte offset of the NEXT entry) |
| +$0c | l | arpeggio list start |
| +$10 | l | arpeggio current pointer |
| +$14 | b | portamento speed (signed) |
| +$15 | b | portamento delay counter |
| +$16 | b | loop-pending: 0 = a note started on the previous tick, the repeat pointer must still be written |
| +$18 | l | instrument pointer (-> 12-byte entry at $2f48) |
| +$1c | w | current duration in ticks |
| +$1e | w | tick counter |
| +$20 | w | portamento accumulated slide |
| +$22 | l | volume envelope start |
| +$26 | l | volume envelope current pointer |
| +$2a | b | envelope speed (reload value) |
| +$2b | b | envelope counter |
| +$2c | b | vibrato speed |
| +$2d | b | vibrato position |
| +$2e | b | vibrato depth |
Fields not reset by `init_song` (+$18, +$1c, +$22, +$26, +$2a..+$2e, +$14, +$15, +$20) keep the values of the previous
song (all zero at boot); every song sets instrument/envelope/duration before its first note.

### 3.3 Shadow block (a4 = $4084 + 12*ch)
+0 l sample pointer, +4 w length (words), +6 w period, +8 w volume, +$a b music-active ($ff, set by every music tick of
that channel; cleared only by `stop`), +$b b sfx-owns-channel. `stop` clears +$a/+$b with one `clr.w`.

### 3.4 Sfx channel struct (a1 = $3ffa + $22*ch); +$00..+$15 are copied from the 22-byte synth definition
| off | size | meaning |
|---|---|---|
| +$00 | w | per-frame period delta (signed add) |
| +$02 | w | period reset value (loaded every +$0e frames) |
| +$04 | w | alternating period step A (used when pattern bit = 0) |
| +$06 | w | alternating period step B (used when pattern bit = 1) |
| +$08 | w | current period |
| +$0a | w | waveform offset A (pattern bit = 0) |
| +$0c | w | waveform offset B (pattern bit = 1) |
| +$0e | b | reset interval in frames (0 = never) |
| +$0f | b | alternation interval in frames (0 = never) |
| +$10 | b | alternation bit pattern (rotated right one bit per use) |
| +$11 | b | waveform bit pattern (rotated right one bit every frame) |
| +$12 | b | remaining duration in frames (sfx ends when it decrements to 0; 0 means 256) |
| +$13 | b | volume-envelope speed (frames per step) |
| +$14 | b | volume-envelope index (0..2, table $41bc) |
| +$15 | b | 0 for synth sfx; sample sfx store their id here (non-zero => update only counts duration) |
| +$16 | b | reset counter (init = +$0e) |
| +$17 | b | alternation counter (init = +$0f) |
| +$18 | b | active |
| +$19 | b | envelope counter (init 1) |
| +$1a | l | envelope pointer |
| +$1e, +$20 | w | sample sfx: copy of the period (never read) |

---------------------------------------------------------------------------------------------------------------------

## 4. Data formats (all verified by `extract.py` -> `assets/audio.json`)

### 4.1 Song table $2fa8: 7 songs x 10 bytes
`b tempo (signed), b speed, w seq_ch0, w seq_ch1, w seq_ch2, w seq_ch3` (sequence offsets rel $2800)

| song | tempo | speed | sequences (rel $2800) | loop length (frames) | used for |
|---|---|---|---|---|---|
| 0 | 8 | 0 | 07f2 07ee 084c 0870 | 5633 (112.7 s) | title screen (kernel $f90e and $f93e at boot) |
| 1 | 7 | 0 | 0a04 0a00 0a08 0a16 | 4481 | high-score entry after game over (kernel $ff40) |
| 2 | 8 | 0 | 0b24 0b1e 0b58 0ba8 | 13825 | section 0 (Jungle & Village) in-game (section0 $17180) |
| 3 | 8 | 0 | 0cee 0c98 0d50 0d6c | 7169 | "LOADING... THE xxx SECTIONS" intro screen before every section (kernel $11076, reached from the title $fcc4 and from sections via $f874 on completion) and every failure/death message screen (section0 $19daa "GAME OVER", section1 $17272, section2 $176de) |
| 4 | 8 | 0 | 0f3c 0efe 0f7a 0fa8 | 7681 | section 1 Tunnels in-game (section1 $172c2, after a message: wait fire, then song 4) |
| 5 | 6 | 0 | 104c 1036 1050 1092 | 3073 | section 2 Jungle/Foxhole in-game (section2 $1771e, reached from $17038 and $17eba) |
| 6 | 3 | 0 | 11c2 1128 11ec 1256 | 5569 | section 1 Flare/Bunker sub-section (section1 $18b66) |
Loop length = frames until every multi-entry sequence of the song has wrapped (renders in `assets/songs/`). No song ends
(command $84 is not used): all loop forever. At game over the kernel stops music with vol 0 ($10c3a at $ff1a) after
fading ($fed6) and plays song 1 if the score qualifies, else restarts at $f890 (title, song 0).

### 4.2 Sequences $2fee-$3073 (28 sequences)
List of big-endian words, each the offset (rel $2800) of a pattern, terminated by a 0 word. Playback restarts at the
first entry when the terminator is reached.

### 4.3 Patterns $3074-$3bcd (80 patterns)
Byte stream, read at every new event until a byte that ends the event (note, $82, $83, $84):

| byte | meaning | extra bytes | ends event |
|---|---|---|---|
| $00-$7f | note n (period index n + global + channel transpose, + arpeggio) | - | yes |
| $80 | end of pattern: next sequence entry, continue reading | - | no |
| $81 | portamento: speed (signed, added to slide each tick), delay (ticks before sliding) | 2 | no |
| $82 | rest for one duration (repeat -> silence buffer; DMA already off) | - | yes |
| $83 | tie: extend the current note by one duration, no retrigger | - | yes |
| $84 | end song: `song_loaded := 0`, `stop`, return from play (**unused**) | - | - |
| $85 | global transpose := byte | 1 | no |
| $86 | vibrato on: speed, depth | 2 | no |
| $87 | vibrato off | - | no |
| $88 | channel transpose := byte | 1 | no |
| $89 | new sequence: hi, lo (offset rel $2800), index := 0 (**unused**) | 2 | no |
| $8a | tempo := signed byte (**unused**) | 1 | no |
| $8b-$9f | undefined (jump table overrun) - never used | | |
| $a0-$af | arpeggio list index (table $2efc) | - | no |
| $b0-$bf | volume envelope index (table $4200) | - | no |
| $c0-$df | instrument (b - $c0), 12-byte entries at $2f48 (only 0..7 exist) | - | no |
| $e0-$ff | duration := (b - $df) * tempo ticks | - | no |
Used in the data: $80 $81 $82 $83 $85 $86 $87 $88, arpeggios, envelopes, instruments 0-7, durations; notes 5..62.
Example (song 0, ch0, pattern $3074): `c5 86 02 02 88 0c b3 e0 0c 0c 0c 0c e1 18 0c ...` = instrument 5, vibrato 2/2,
transpose +12, envelope 3, duration 1*8, notes 12,12,12,12, duration 2*8, note 24 ...

### 4.4 Period table $2e6c: 72 words (6 octaves, index 0 = 8192 ... index 71 = 135, each octave halves)
Real period = `(table[i] * inst.mult) >> 10` (32-bit product, 32-bit shift, low word used). **Quirk**: the index is not
range-checked; song 6 reaches index 76 (transposes/arpeggio), which reads the *arpeggio offset table* that follows:
indices 72..83 = 1814 1816 1819 1822 1825 1828 1830 1838 1845 1851 1853 1855 (very low notes). Keep the table contiguous
with $2efc in the port.

### 4.5 Arpeggio tables: $2efc = 13 words (rel $2800) -> byte lists; last byte has bit 7 set (value = low 7 bits)
$a0 [0] (at $2f16, the default), $a1 [7,12,15], $a2 [3,7,12], $a3 [0,3,7], $a4 [0,4,7], $a5 [0,12], $a6 [12,0,0,0,0,0,0,0],
$a7 [12,0,0,0,0,0,0], $a8 [12,0,0,0,0,0], $a9 [0,3], $aa [0,4], $ab [0,5], $ac [24,0,0,0,0,0,0].
(Note: the list's first byte is consumed on the first effects tick, i.e. the tick after the note start; the note-start
tick itself always uses offset 0.)

### 4.6 Volume envelopes: $4200 = 16 words (rel $2800); the byte *before* each list is its speed; last byte bit 7 = hold
| cmd | addr | speed | volumes |
|---|---|---|---|
| $b0 | $4221 | 0 | 40 40 |
| $b1 | $4224 | 3 | 64 56 48 40 32 24 |
| $b2 | $422b | 1 | 64 48 32 24 48 32 24 16 32 24 16 8 24 16 12 8 16 12 8 6 12 8 6 4 8 6 4 2 6 4 2 1 |
| $b3 | $424c | 1 | 64 48 32 24 16 48 32 24 16 12 32 24 16 12 8 24 16 12 8 4 16 12 10 8 6 12 10 8 6 4 10 8 6 4 3 8 6 4 3 2 6 4 3 2 1 |
| $b4 | $427a | 10 | 64 48 |
| $b5 | $427d | 2 | 64 48 32 24 16 48 32 24 16 12 32 24 16 12 8 24 16 12 8 4 16 12 8 4 2 12 8 4 2 1 8 4 2 1 0 |
| $b6 | $42a1 | 1 | 48 64 40 24 16 8 |
| $b7 | $42a8 | 2 | 24 32 40 48 56 64 64 56 56 48 48 40 40 32 32 32 32 24 24 24 24 18 18 18 18 12 12 12 12 8 8 8 8 4 4 4 2 1 |
| $b8 | $42cf | 1 | 40 32 24 16 8 4 24 16 8 4 2 |
| $b9 | $42db | 1 | 48 32 24 16 24 16 8 4 8 4 2 1 |
| $ba | $42e8 | 1 | 32 24 16 8 24 16 8 4 16 8 4 2 |
| $bb | $42f5 | 2 | 32 40 48 40 36 24 |
| $bc-$bf | $42fc/$42ff/$4302/$4305 | 255 | 16 / 24 / 60 / 0 (held) |
The first value is applied at the note start; subsequent values every (speed+1) effect ticks (see 5.4). The final value
(bit 7 set) is re-applied (as `value & $7f`) at each step without advancing.

### 4.7 Instruments: table $2f48, 8 x 12 bytes: `l sample ptr, l loop offset in bytes (-1 = one-shot), w length words, w period multiplier`
The pointers/lengths/multipliers are filled by `init_tables` from the chained sample headers at $430a
(`l length bytes, w rate Hz, data`); loop offsets are preset on disk. `mult = 3579545 / rate` (NTSC clock constant).
| # | ptr | bytes | rate | mult | loop | notes |
|---|---|---|---|---|---|---|
| 0 | $4310 | 4806 | 6400 | 559 | 0 (whole sample) | looped sample |
| 1 | $55dc | 5500 | 18900 | 189 | one-shot | |
| 2 | $6b5e | 5300 | 13500 | 265 | one-shot | |
| 3 | $8018 | 2000 | 16100 | 222 | one-shot | |
| 4 | $87ee | 64 | 8500 | 421 | 0 | synthetic waveform |
| 5 | $8834 | 128 (only 64 played: len forced to 32 words) | 8500 | 421 | 0 | **PWM square**, rewritten at run time (4.8) |
| 6 | $88ba | 128 | 8500 | 421 | 0 | square |
| 7 | $8940 | 128 | 8500 | 421 | 0 | square (2x frequency) |
Silence buffer $89c0 (64 zero bytes). WAVs: `assets/instruments/inst0-7.wav`; waveform plots `assets/synth_waves/waves.png`.

### 4.8 PWM waveform (instrument 5, $8834, 64 bytes)
`init_tables` fills it with 32 x $c0 then 32 x $3f and sets offset=$20, dir=0. Every music tick (before the channel loop):
```
if dir >= 0: word[$8834+ofs] = $c0c0; ofs += 2; if ofs == $2c: dir = ~dir
else:        word[$8834+ofs] = $3f3f; ofs -= 2; if ofs == $20: dir = ~dir
```
(12-tick triangle sweep of the duty cycle between 32/64 and 44/64; Paula reads the modified RAM live, so the port's
virtual Paula must read sample data from the same emulated RAM that this code modifies.)

### 4.9 Synth sfx definitions: $40b4, 12 x 22 bytes (layout = sfx struct +$00..+$15, section 3.4)
| id | per start | delta/frame | reset val / every | alt A/B every (pattern) | wave off A/B (pattern) | dur | vol env (speed) |
|---|---|---|---|---|---|---|---|
| 0 | 480 | +4 | 770 / 4 | +3/+30 every 1 ($aa) | $100/$100 ($aa) | 25 | env0 (5) |
| 1 | 2400 | +12 | 3400 / 7 | +100/-15 every 1 ($00) | $200/$000 ($00) | 50 | env0 (1) |
| 2 | 1700 | +4 | 1900 / 9 | +120/-15 every 1 ($00) | $200/$000 ($00) | 50 | env0 (1) |
| 3 | 200 | +4 | 300 / 8 | +100/-15 every 1 ($00) | $200/$000 ($00) | 15 | env0 (1) |
| 4 | 2100 | -40 | 2800 / 3 | +15/-15 every 1 ($92) | $200/$180 ($aa) | 15 | env0 (5) |
| 5 | 5000 | +4 | 6000 / 8 | +15/-15 every 1 ($00) | $200/$000 ($00) | 20 | env0 (4) |
| 6 | 590 | +55 | 420 / 1 | +70/-71 every 1 ($aa) | $180/$200 ($8c) | 16 | env0 (4) |
| 7 | 2000 | -7 | 3000 / never | +10/-11 every 1 ($aa) | $180/$000 ($00) | 55 | env0 (10) |
| 8 | 1450 | -8 | 1460 / 50 | never | $200/$000 ($00) | 50 | env0 (1) |
| 9 | 650 | -1 | 660 / never | +20/-20 every 1 ($aa) | $080/$200 ($aa) | 150 | env2 (25) |
| 10 | 2000 | +12 | 2800 / 7 | +100/-15 every 1 ($00) | $200/$000 ($00) | 30 | env1 (1) |
| 11 | 1700 | +12 | 4400 / 8 | +100/-15 every 1 ($00) | $200/$000 ($00) | 100 | env0 (3) |
"alt A/B": step added when the rotated pattern bit is 0 (A = word +4) or 1 (B = word +6). Pattern $00 -> always A.
Wave offsets are added (sign-extended) to $8a00: 6 waveforms of 128 bytes: offset $000 wave0 ($8a00, square-ish),
$080 wave1 ($8a80, stepped triangle), $100 wave2 ($8b00, buzzy), $180 wave3 ($8b80, saw-like), $200 wave4 ($8c00,
noise), $280 wave5 ($8c80, fast square, unused) (`assets/synth_waves/`).
Synth sfx volume envelopes: table $41bc = 3 words rel $2800: env0 $41c2 = 64,62,...,2,0 (33 steps); env1 $41e4 =
4 8 12 16 22 24 28 26 30 35 40 45 50 40 35 30 25 20 15 10 5; env2 $41fa = 44. Terminated by a byte with bit 7 set
(value not used, volume holds).

### 4.10 Sample sfx: headers $8d02 (5 chained `l len, w rate, data`), table $3d72 (5 x 16) built by $3c42
Table entry: `l ptr, l loop (preset -1 = none), w len words, w period = 3579545/rate, b frames = (len_lo_word*50)/rate + 1, b long-flag (0)`.
| id | ptr | bytes | rate | period | frames | usage (from call sites; content inferred, not listened to) |
|---|---|---|---|---|---|---|
| $80 | $8d08 | 5660 | 10000 | 357 | 29 | title sequence (kernel $fa52); enemy killed/death cry in sections (sec0 $176c4, sec1 $17d20/$17dd6/$1932a, sec2 $1932e, sec2 $180f6 via variable $57f64) |
| $81 | $a32a | 7650 | 10000 | 357 | 39 | player hit ("YOU'RE HIT", sec0 $1777a); sec1 $17c0a/$17c94/$17d08; sec2 $183ce, $186d2->$57f64 |
| $82 | $c112 | 4828 | 10000 | 357 | 25 | player rifle shot (sec0 $1741e bullet spawn, sec1 $18398, sec2 $18162: fire button) |
| $83 | $d3f4 | 6810 | 10000 | 357 | 35 | automatic fire: section 1 tunnels fire button retriggers it every 4 frames ($18f44/$18fc2, ammo decrement), sec1 $179d8/$17b5e, sec1/2 $19206 |
| $84 | $ee94 | 2290 | 10000 | 357 | 12 | short shot, enemy firing (sec1/sec2 $191be, every 16 frames of an enemy state) |
| $85 | = $83 | | | 714 | 70 | sample $83 an octave lower, double length: explosion/boom (sec0 $17676) |
Sample data end: $ef86. WAVs: `assets/sfx_samples/`.

---------------------------------------------------------------------------------------------------------------------

## 5. Replay algorithm (exact pseudocode; `replayer.py` is the executable version)

Notation: `hw(ch)` = $dff0a0 + 16*ch; `w8/w16` byte/word stores; all byte arithmetic wraps mod 256, word mod 65536.
`owns(ch)` = `shadow[ch].b_sfx != 0`. Paula writes are listed in exact order. "LC" = 32-bit write to AUDxLC
(two word writes: LCH then LCL).

### 5.1 init_tables ($3bce, once; guarded by $2d9e)
```
a0 = $430a
for i in 0..7:  len = long(a0); rate = word(a0+4); a0 += 6
                inst[i].ptr = a0; a0 += len; inst[i].lenw = len>>1; inst[i].mult = 3579545 / rate (divu, quotient)
silence_ptr ($2da4) = a0            ; $89c0
synth_wave  ($41fc) = a0 + $40      ; $8a00
fill inst[5].ptr: 16 words $c0c0, 16 words $3f3f; inst[5].lenw = $20; pwm_ofs = $20; pwm_dir = 0; tables_built = $ff
```

### 5.2 init_song(d0) ($2854)
```
bset #1,$bfe001                      ; LED off = filter off
stop()                               ; 5.6 (writes DMACON=$000f, ADKCON=$00ff, AUD0..3VOL=0)
init_tables()
gtranspose = 0
o = sext8(d0) * 10                   ; 16-bit
tempo = sext8(song[o+0]); speed = song[o+1]; speed_copy = speed
for ch in 0..3:
    c.counter(+$1e) = 1; c.flags = 0; c.vib = 0; c.ctrans = 0; c.loop_pending(+$16) = $ff
    c.arp_start = c.arp_ptr = $2f16
    c.seq = word(song + o + 2 + 2*ch); c.seq_idx = 2
    c.pat_ptr = $2800 + word($2800 + c.seq)
playing = $ff; loaded = $ff
```
No hardware write besides the stop; the first notes are started by the next `play`.

### 5.3 play ($2990) - once per vblank
```
if !playing: goto sfx_update
if ntsc_enable: if --ntsc_count == 0: ntsc_count = 6; return      ; (never)
acc += speed; if carry: goto sfx_update                             ; (never: speed 0)
PWM step (4.8)
for ch in 0..3: if channel_tick(ch) == STOP: return                 ; STOP only from cmd $84
sfx_update()
```

### 5.4 channel_tick(ch) ($29f6-$2c38)
```
a4 = shadow[ch]; a4.music_active = $ff
a0 = chan[ch]; a1 = a0.pat_ptr; a5 = a0.inst
if a0.loop_pending == 0:                               ; note started on the previous tick
    a0.loop_pending = $ff
    if a5.loop < 0: a4.ptr = silence_ptr; a4.len = $20
    else:           a4.ptr = a5.ptr + a5.loop; a4.len = a5.lenw - (a5.loop >> 1)
    if !owns: LC = a4.ptr; LEN = a4.len               ; Paula uses them at the next buffer wrap
a0.counter -= 1
if a0.counter == 1:                                    ; last tick of the event
    if !owns and byte(a1) != $83: DMACON = 1<<ch       ; stop the voice -> 1-tick gap before the next note
    return                                              ; (no effects on this tick)
if a0.counter != 0: effects(); return
; ---- counter == 0: new event ----
a0.flags = 0
loop:
  b = byte(a1++)
  if b < $80:                                          ; NOTE
     a0.note = b; n = (b + gtranspose + a0.ctrans) & $ff
     e = a0.env_start; v = byte(e); a0.env_ptr = e+1; a0.env_cnt = a0.env_speed
     a4.ptr = a5.ptr; a4.len = a5.lenw
     vol = (((sext8(v) & $ffff) * master) & $ffff) >> 6 ; a4.vol = vol
     if !owns: LC = a5.ptr; LEN = a5.lenw; VOL = vol
     per = (pertab[n] * a5.mult) >> 10 (low word); a4.per = per
     if !owns: PER = per
     a0.loop_pending = 0; a0.pat_ptr = a1; a0.counter = a0.duration
     DMACON = $8200 | 1<<ch                            ; even when owns (harmless)
     return
  if b >= $e0: a0.duration = ((b-$df) * tempo) & $ffff; continue
  if b >= $c0: a5 = a0.inst = $2f48 + 12*(b-$c0); continue
  if b >= $b0: e = $2800 + sext16(word($4200 + 2*(b-$b0))); a0.env_start = e; a0.env_speed = byte(e-1); continue
  if b >= $a0: p = $2800 + sext16(word($2efc + 2*(b-$a0))); a0.arp_start = a0.arp_ptr = p; continue
  switch b:
   $80: i = a0.seq_idx; e = a0.seq + i; i += 2
        if word($2800+e) == 0: e = a0.seq; i = 2
        a1 = $2800 + word($2800+e); a0.seq_idx = i; continue
   $81: a0.slide = 0; a0.porta_speed = byte(a1++); a0.porta_delay = byte(a1++); a0.flags |= 2; continue
   $82: a0.counter = a0.duration; a0.pat_ptr = a1
        a4.ptr = silence_ptr; a4.len = $20; if !owns: LC = silence_ptr; LEN = $20
        return                                          ; no DMA write (it was switched off at counter==1)
   $83: a0.pat_ptr = a1; a0.counter = a0.duration; DMACON = $8200|1<<ch; return
   $84: loaded = 0; stop(); return STOP
   $85: gtranspose = byte(a1++); continue
   $86: a0.vib = $ff; a0.vib_speed = byte(a1++); a0.vib_depth = byte(a1++); a0.vib_pos = 0; continue
   $87: a0.vib = 0; continue
   $88: a0.ctrans = byte(a1++); continue
   $89: a0.seq = (byte(a1)<<8)|byte(a1+1); a1 += 2; a0.seq_idx = 0; continue
   $8a: tempo = sext8(byte(a1++)); continue
```
effects() ($2b4a), only on ticks where the counter after decrement is >= 2:
```
n = (a0.note + gtranspose + a0.ctrans) & $ff
d = byte(a0.arp_ptr); p = a0.arp_ptr + 1
if d & $80: d &= $7f; p = a0.arp_start               ; last entry: use it, then restart
a0.arp_ptr = p
n = (n + d) & $ff
per = ((pertab[n] * a5.mult) >> 10) & $ffff
if a0.flags & 2:
    if a0.porta_delay != 0: a0.porta_delay -= 1        ; slide not applied while delaying
    else: a0.slide += sext8(a0.porta_speed); per -= a0.slide
if a0.vib != 0:
    if a0.vib & $80: pos = (a0.vib_pos + a0.vib_speed) & $ff; a0.vib_pos = pos; if pos == a0.vib_depth: a0.vib ^= $80
    else:            pos = (a0.vib_pos - a0.vib_speed) & $ff; a0.vib_pos = pos; if pos == 0: a0.vib ^= $80
    if a0.vib_pos == 0: a0.vib ^= $01
    if a0.vib & 1: per += sext8(pos) else per -= sext8(pos)
a4.per = per; if !owns: PER = per
c = a0.env_cnt; a0.env_cnt = c - 1
if c == 0:                                             ; subq.b #1 / bcc: step when the counter underflows
    a0.env_cnt = a0.env_speed
    v = byte(a0.env_ptr); if !(v & $80): a0.env_ptr += 1
    vol = (((v & $7f) * master) & $ffff) >> 6; a4.vol = vol; if !owns: VOL = vol
```
Timing consequences: an event of D ticks starting on tick t: t = note start (vol = env[0], period = arpeggio offset 0),
t+1 .. t+D-2 effects (arpeggio advances one entry per tick; envelope steps every speed+1 ticks, first on tick t+1+speed),
t+D-1 DMA off (unless the next pattern byte is $83), t+D next event. The volume/period of a tick are written in the
vblank; loop pointers of a note are written on tick t+1.

### 5.5 Hardware order of a typical tick
Note start: `AUDxLCH, AUDxLCL, AUDxLEN, AUDxVOL, AUDxPER, DMACON($8200|bit)`; next tick: `AUDxLCH, AUDxLCL, AUDxLEN`
(repeat) then (effects) `AUDxPER [, AUDxVOL]`. Channels are processed 0,1,2,3, then the sfx updates for channels 0..3.

### 5.6 stop ($28e8)
```
playing = 0
sfx[0..3].active = 0
shadow[0..3].music_active = shadow[0..3].sfx_owns = 0     ; clr.w
DMACON = $000f; ADKCON = $00ff; AUD0VOL = AUD1VOL = AUD2VOL = AUD3VOL = 0
```
Note: a new song (init) or music-off therefore also kills any running sound effect.
resume ($2960, unused): `if loaded: ADKCON=$00ff; DMACON=$820f; playing=$ff`. sfx_stop_all ($2942, unused):
`sfx[0..3].duration = 1`.

### 5.7 sfx trigger ($3c90), d0.w = (ch<<8)|id
```
bset #1,$bfe001; ADKCON = $00ff
d0 &= $3ff; request($4082) = d0; ch = d0>>8
sfx[ch].active = 0
init_tables()
shadow[ch].sfx_owns = $ff                              ; music on this channel now silent (shadow only)
if sext8(id) < 0: goto sample_sfx
if id > 11: id = 0
s = sfx[ch]; s.active = 0; DMACON = 1<<ch; AUDxLEN = $40
copy 22 bytes from $40b4 + 22*id to s+$00..s+$15
s.reset_cnt(+$16) = s.reset_int(+$0e); s.alt_cnt(+$17) = s.alt_int(+$0f)
s.env_cnt(+$19) = 1; s.env_ptr = $2800 + sext16(word($41bc + 2*sext8(s.env_idx)))
busy-wait (dbra $200); s.active = $ff                  ; DMA is enabled by the next sfx_update
sample_sfx ($3dc2):
  init_smp_sfx()
  if sext8(id) > sext8($85): return                    ; ids $86..$ff ignored (but the channel stays marked sfx-owned!)
  if id == $85: tbl[3].per <<= 1; tbl[3].frames = (tbl[3].frames*2)&$ff; play($83); tbl[3].per >>= 1; tbl[3].frames >>= 1; return
  play(id):  ch = byte($4082); s = sfx[ch]; s.active = 0; s.b15 = id; DMACON = 1<<ch
             e = tbl[id & $7f]; s.duration = e.frames; if e.long_flag: s.duration = 0
             busy-wait
             AUDxLEN = e.lenw; LC = e.ptr; AUDxPER = e.per; s.w1e = s.w20 = e.per; AUDxVOL = 64
             DMACON = $8200|1<<ch; s.active = $ff; busy-wait
             if e.loop < 0: LC = silence_ptr; AUDxLEN = $20        ; one-shot: repeat = silence
             else: AUDxLEN = e.lenw - e.loop/2; LC = e.ptr + e.loop
```
(The busy waits are ~5100 CPU cycles each; they make sure Paula sees the DMA-off before the restart. In the emulator a
vblank can land inside a trigger; the port can treat a trigger as atomic.)

### 5.8 sfx_update ($3eb4), end of every play; for ch = 0..3 with sfx[ch].active:
```
s.duration -= 1
if s.duration == 0:
    s.active = 0; DMACON = 1<<ch; shadow.sfx_owns = 0
    if shadow.music_active: LC = shadow.ptr; AUDxLEN = shadow.len; AUDxPER = shadow.per; AUDxVOL = shadow.vol; DMACON = $8200|1<<ch
    continue
if s.b15 != 0: continue                                ; sample sfx: nothing else
if s.alt_int != 0 and --s.alt_cnt == 0:
    s.alt_cnt = s.alt_int; bit = s.alt_pat & 1; s.alt_pat = ror8(s.alt_pat)
    s.per += (bit ? s.altB(+6) : s.altA(+4))
s.per += s.delta(+0)
if s.reset_int != 0 and --s.reset_cnt == 0: s.reset_cnt = s.reset_int; s.per = s.reset(+2)
if --s.env_cnt == 0:
    s.env_cnt = s.env_speed; v = byte(s.env_ptr); if !(v & $80): s.env_ptr += 1; AUDxVOL = v
p = s.per; if sext16(p) < $7c: p = $7c; AUDxPER = p
bit = s.wave_pat & 1; s.wave_pat = ror8(s.wave_pat)
LC = $8a00 + sext16(bit ? s.waveB(+$c) : s.waveA(+$a))
DMACON = $8200 | 1<<ch
```
So a synth sfx with duration N is audible for N-1 frames starting with the first vblank after the trigger; a sample sfx
starts immediately and is released on the vblank where its frame counter reaches 0 (the sample may still be sounding
from the "silence" repeat, i.e. it is cut exactly at that frame).

### 5.9 Channel allocation / priority
There is no priority logic. A request always takes the channel chosen by the kernel wrapper (section 2), killing any
sfx already on it. Synth sfx: ch0, or ch2 if ch0 has an active sfx. Sample sfx: ch0+ch2 ($82-$85) or ch1+ch3
($80/$81). Music continues underneath (shadow registers), inaudible on owned channels, and is restored at the end of the
sfx with the *current* music state (not a restart). Starting a song / turning music off cancels all sfx.

---------------------------------------------------------------------------------------------------------------------

## 6. Per-frame flow and timing
* Level-3 handler $10eac: CIA TOD resets / random seed, TAB pause toggle, game timer, `st $56(a6)` (frame flag used by
  `$10ad6` wait-for-vblank), `jsr $280e` (music+sfx; its Paula writes land on raster lines ~2-16), `$10cfe` (kernel,
  not audio), F10 option toggle (may call $10c00/$10c50 from inside the interrupt), clear INTREQ.
* Music logic rate: 50 Hz (one tick per PAL frame); note durations are multiples of the song tempo (3..8 frames).
* Sfx triggers happen in main code at arbitrary raster positions (they take ~30-60 lines because of the busy waits).

## 7. Rendering / display
The driver has no display side. (The title shows "MUZAK: ON/OFF FX: ON/OFF" via kernel $10ca2 from option byte $12e44.)

## 8. Input
F10 (raw key $59): cycle options 3 -> 0 -> 1 -> 2 -> 3 (bit0 music, bit1 fx); each press re-requests the current song
($12cce, i.e. restarts it from the beginning if music is on, stops it otherwise) and requests synth sfx 0 (only audible
when fx on). TAB ($42) pauses the game but not the music. Cheat-code letters (kernel $10e14, string at $11207/$11211)
play synth sfx 2 per correct letter.

## 9. Sound-effect call sites (all `jsr $f86c` / wrappers; d0 = id before the call)
Kernel: $fa52 ($80, title sequence), $10e4e (2, cheat letter), $10f8c (0, F10 click).
Section 0 (wrapper $19f82 = `jmp $f86c`): $1741e $82 player shot; $1748e $0a grenade throw (every >=16 frames, decrements
a count at +0 of the current man, likely grenades); $17676 $85 explosion; $176c4 $80; $1777a $81 player hit; $17cca 0
item pickup (position range table $1aafa).
Section 1 (direct `jsr $f86c`): $179d8 $83, $17b5e $83, $17c0a $81, $17c94 $81, $17d08 $81, $17d20 $80, $17dd6 $80,
$18398 $82 (ammo-1), $187c2 0 (menu/door selection click, then `jmp (a0)`), $18d46 $0a (flare throw: $2c(a6)-1),
$18f44 $83 and $18fc2 $83 (ammo-1: tunnel gun, autofire every 4 frames), $191be $84 (enemy fire, every 16 frames),
$19206 $83 (every 8 frames), $1932a $80 (enemy death).
Section 2 (wrapper $18860): $180fc var ($57f64 in {$80,$81}, reset to $80), $18164 $82 player shot, $183d8 $81,
$183e8 $81 (d0 from the preceding path), $191be $84, $19206 $83, $1932a $80 (same enemy code as section 1).
Music calls: kernel $f90e/$f93e (0), $ff40 (1), $11076 (3); section0 $17180 (2), $19daa (3); section1 $17278 (3),
$172c2 (4), $18b66 (6); section2 $176e4 (3), $17724 (5). Music off: kernel $f8de, $ff1a ($10c3a); fade $fed6 at $ff00.
Synth sfx ids used by the game: 0, 2, 10 ($0a). Ids 1, 3-9, 11 exist but are never requested.

---------------------------------------------------------------------------------------------------------------------

## 10. Verification results
`verify.py` (register level: every Paula write made by code in $2800-$40ff, compared in order; WAV: python register
stream fed at the emulator's raster line of each write into `replayer.Paula`, a line-for-line port of emu.c
`audio_line()`):

| run | frames | emulator writes | result |
|---|---|---|---|
| title (song 0 + sfx $80 x2) | 3000 | 23588 | identical; WAV 2 646 000 samples, 0 differ |
| songs 1..6 via F10 trick | 4500 each | 27k-36k | identical; WAV 0 differ (each) |
| songs 0..6 full loop + 300 | 3.8k-14.5k | up to 98174 | identical |
| sfxtest (all 18 ids x2, with/without music) | 5600 | ~26k | identical; WAV 0 differ |
| sfxtest3 (overlapping synth sfx -> ch2, id $0c) | 2600 | 22962 | identical; WAV 0 differ |
| section 1/2 random play from saved states | 6000 each | 41767 / 40417 | play-side and call-side streams identical |
| section 0 from boot (intro, song 3, song 2, choose man, random play) | 5000 | 31565 | play-side and call-side streams identical |
In the in-game runs a vblank sometimes lands inside a main-code sfx trigger (the trigger has ~10k cycles of busy waits).
The emulator then shows the trigger's writes split across two frames with the music/sfx update in between; in that
vblank the music already sees the channel as sfx-owned (flag set at the start of the trigger) but the sfx is not active
yet, so its duration count starts one frame later. `verify.py` models this (runs the trigger, defers the `active` flag
to after the next play) and then both sub-streams (interrupt-side play writes, main-side trigger writes) match exactly;
only the per-frame split of the global stream differs (2-8 frames per run). A port with atomic triggers is off by at
most one frame in such rare cases.
Not exercised (not reachable with the game's data/calls): commands $84/$89/$8a, NTSC skip, resume, sfx_stop_all,
sample loops, period clamp $7c, sfx ids >= $86. They are implemented from the disassembly only.

Standalone renders (`assets/songs/*.wav`, all writes at raster line 3) differ from the emulator only by sub-frame write
timing (frame RMS correlation 0.998, spectrogram correlation 0.98 for song 0).

## 11. Emulator notes / Paula model used for the bit-exact comparison
emu.c: 313 lines/frame, 44100 Hz output (882 samples/frame), PAL clock 3546895, per output sample
`phase += 3546895/per/44100`, word fetch every 2 bytes, reload LC/LEN at counter wrap, DMA start latches LC/LEN on
the first output sample after DMACON enable, volume and period take effect immediately, `per < 64 -> 64`, vol>64 -> 64,
no filter, ch0+ch3 left, ch1+ch2 right, output = sum*3 (int16 wrap). `bytepos` is a per-channel static not reset on
restart. Disabled channels output nothing (real Paula holds the last value - DC, inaudible). The Swift virtual Paula
should model at least: LC/LEN latching at DMA start and at every buffer wrap, immediate PER/VOL, RAM read at fetch time
(PWM waveform is modified live), DMA off/on semantics. **Important for sample sfx**: the trigger writes the sample
LC/LEN, enables DMA, busy-waits ~12 raster lines and only then writes the repeat (silence) LC/LEN; Paula must latch
the sample pointer at DMA enable. If the port applies a whole trigger's writes at one instant it must still latch
at the DMACON write (i.e. process writes in order against the voice state), otherwise the sample never plays
(`extract.py` models the busy waits with log markers `(-2, 12)` = advance 12 raster lines).

## 12. Open questions
* Sample content names (gunshot/scream/explosion) are inferred from call-site context, not by listening.
* The purpose of section-1 $83 calls at $179d8/$17b5e and the exact meaning of the grenade/flare counters belong to the
  section modules (jungle/tunnels/flare agents).
* `re/NOTES.md` says tracks 1-17 are relocated ($404 -> $400); for the $2538-$17000 area the RAM image equals the ADF at
  offset +$1200 exactly (no shift).
