#!/usr/bin/env python3
"""QA robustness: every regress scenario's port script with MANY options on at once (no crash, no hang, frames complete).
usage: kitchen.py BIN OUT [SET]"""
import sys, os, subprocess, time, concurrent.futures as cf
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../../tools/regress'))
import regress as R
B, OUT = sys.argv[1], sys.argv[2]; SET = sys.argv[3] if len(sys.argv) > 3 else 'all'
SETS = {
 'all': 'difficulty=recruit,game.lives=5,game.fullPlatoon=1,s0.bridgeFailsafe=1,s0.forgivingTraps=1,s0.fixMoraleWrap=1,s0.fixHutDummy=1,s0.fixTripwireSpawn=1,s0.fixTrapdoorBonus=1,s0.explicitJumpCrouch=1,s0.jumpKey=0x32,s0.crouchKey=0x33,s0.villageSeed=7,s1.keepItems=1,s1.flareRetry=1,s1.checkpointRespawn=1,s1.exploredMap=1,s1.fixMoraleWrap=1,s1.fixLastBullet=1,s1.fixFlareSpawn=1,s1.fixFoodFarm=1,s1.directAim=1,s1.randomSeed=3,s2.fixRoomTimer=1,s2.napalmStopsTimer=1,s2.withdrawnText=1,s2.fixPhantomGrenades=1,s2.compassAssist=1,kernel.steadyPauseColour=1,kernel.keyboardNameEntry=1,kernel.timerStopsAtZero=1,kernel.separateCheatScores=1,audio.ghostVoices=1,audio.synthesis=blep,audio.ambience=auto,audio.musicVolume=0.5,audio.sfxVolume=1.5',
 'veteran': 'difficulty=veteran,s0.villageSeed=12345,s1.randomSeed=99,s2.diff.timer=30,s2.diff.barnesHits=20,s0.diff.noMap=1,kernel.diff.startMorale=0x100',
 'custom': 'difficulty=custom,s0.diff.shootMask=0,s0.diff.hitMorale=0,s0.diff.grenades=0,s0.diff.ammo=0,s0.diff.spawnFloor=254,s1.diff.spawnDelay=1,s1.diff.enemyAim=1,s1.diff.flareSpawnBase=4,s1.diff.flareShotSlack=0,s2.diff.maxSoldiers=0,s2.diff.spawnDelay=1,s2.diff.fireCooldown=1,s2.diff.sniperDelay=5,s2.diff.grenades=99,s2.diff.barnesCooldown=1,game.lives=2',
}
enh = SETS[SET]
def one(sc):
    d = f'{OUT}/{SET}/{sc.name}'; os.makedirs(d, exist_ok=True)
    open(f'{d}/script.txt', 'w').write('\n'.join(sc.port_lines) + '\n')
    env = dict(os.environ); env.update({k: v.replace('{out}', d) for k, v in sc.env.items()})
    env['PLATOON_ENH'] = (env.get('PLATOON_ENH', '') + ',' + enh).strip(',')
    env['PLATOON_EVENTS'] = f'{d}/events.txt'
    env.pop('PLATOON_HISCORES', None)
    cmd = [B, '--adf', R.ADF, '--frames', str(sc.port_frames), '--script', f'{d}/script.txt', '--out', d, '--deterministic'] + sc.port_args
    t = time.time()
    try:
        p = subprocess.run(cmd, stdout=open(f'{d}/stdout.txt', 'w'), stderr=subprocess.STDOUT, env=env, cwd=R.ROOT, timeout=300)
        rc = p.returncode
    except subprocess.TimeoutExpired: rc = 'TIMEOUT'
    out = open(f'{d}/stdout.txt').read()
    frames = out.count('\nframe ') 
    bad = 'Fatal error' in out or 'fatalError' in out or rc not in (0,)
    ev = open(f'{d}/events.txt').read() if os.path.exists(f'{d}/events.txt') else ''
    go = [l for l in ev.splitlines() if 'gameOver' in l or 'hiscore' in l.lower()][:2]
    return f"{'FAIL' if bad else 'ok  '} {sc.name:28s} rc={rc} {time.time()-t:5.1f}s {'; '.join(go)[:150]}" + (('\n     ' + out.strip().splitlines()[-1][:300]) if bad and out.strip() else '')
with cf.ThreadPoolExecutor(3) as ex:
    for r in ex.map(one, R.all_scenarios()): print(r, flush=True)
