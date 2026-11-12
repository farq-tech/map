#!/usr/bin/env python3
"""Imports the off-road «صوت سرى» clips generated in the owner's ElevenLabs account (the 34 lines of
`Resources/SaryVoice/offroad-pending.json`) into the app: prepares them like the existing set, normalises
them with `sary-voice-normalize.py` and moves their rows from the pending file into `manifest.json`.

Usage:
  sary-voice-import.py <src_dir> [--map map.json] [--dry-run]

<src_dir>  the downloaded files (mp3 / wav / m4a). Each file is named `offr_NN.<ext>` (NN as in the pending
           file), or listed in --map as {"<file name>": "offr_NN", ...}.
Steps per clip (the same chain the first set got upstream, see the header of sary-voice-normalize.py):
  decode -> mono 44.1 kHz -> high-pass 70 Hz -> trim silence at both ends -> 80 ms pad at both ends
  -> loudness to -16 LUFS with a true-peak limiter (`sary-voice-normalize.py`) -> AAC 96 kbps m4a.
Needs: ffmpeg, numpy, scipy.
Before moving anything it checks: every key exists in the pending file, no key twice, the clip is > 0.3 s.
After it: run the unit tests (`SaryVoiceTests` asset linter: 226 + imported clips, -16 ±0.5 LUFS) and listen.
"""
import json, os, subprocess, sys, tempfile, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.normpath(os.path.join(HERE, "..", "Resources", "SaryVoice"))
PENDING = os.path.join(RES, "offroad-pending.json")
MANIFEST = os.path.join(RES, "manifest.json")


def sh(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, **kw)


def duration(path):
    out = sh(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path]).stdout
    return float(out.decode().strip())


def prepare(src, dst):
    """decode -> mono 44.1k -> HPF 70 Hz -> trim silence -> 80 ms pads; written as a high-quality m4a."""
    af = ("highpass=f=70,"
          "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,"
          "areverse,silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.05,areverse,"
          "adelay=80:all=1,apad=pad_dur=0.08")
    sh(["ffmpeg", "-v", "error", "-y", "-i", src, "-ac", "1", "-ar", "44100", "-af", af,
        "-c:a", "aac", "-b:a", "256k", dst])


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    mp = None
    if "--map" in sys.argv:
        mp = json.load(open(sys.argv[sys.argv.index("--map") + 1], encoding="utf-8"))
        args = [a for a in args if a != sys.argv[sys.argv.index("--map") + 1]]
    if len(args) != 1:
        sys.exit(__doc__)
    src_dir = args[0]
    pending = json.load(open(PENDING, encoding="utf-8"))
    keys = {r["key"]: r for r in pending}

    found = {}
    for f in sorted(os.listdir(src_dir)):
        base, ext = os.path.splitext(f)
        if ext.lower() not in (".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg"):
            continue
        key = mp.get(f) if mp else (base if base in keys else None)
        if not key:
            print("skip (no key):", f)
            continue
        if key not in keys:
            sys.exit(f"{f}: {key} is not a pending key")
        if key in found:
            sys.exit(f"{key} appears twice: {found[key]} and {f}")
        found[key] = os.path.join(src_dir, f)
    missing = sorted(set(keys) - set(found))
    print(f"found {len(found)} of {len(keys)} pending clips; missing: {', '.join(missing) or '-'}")
    if not found:
        sys.exit("nothing to import")

    tmp = tempfile.mkdtemp(prefix="sary-import-")
    prep, outd = os.path.join(tmp, "prep"), os.path.join(tmp, "out")
    os.makedirs(prep); os.makedirs(outd)
    for k, p in found.items():
        prepare(p, os.path.join(prep, k + ".m4a"))
        d = duration(os.path.join(prep, k + ".m4a"))
        if d < 0.3:
            sys.exit(f"{k}: only {d:.2f}s after trimming: the source is silent or cut")
    norm = sh([sys.executable, os.path.join(HERE, "sary-voice-normalize.py"), prep, outd]).stdout
    for r in json.loads(norm):
        print(f"{r['file']}: {r['I']:.1f} LUFS, TP {r['TP']:.1f} dB")
    if dry:
        print("dry run: nothing moved. work dir:", tmp)
        return

    manifest = json.load(open(MANIFEST, encoding="utf-8"))
    have = {r["key"] for r in manifest}
    for k in found:
        if k in have:
            sys.exit(f"{k} is already in manifest.json")
    for k in sorted(found):
        shutil.copyfile(os.path.join(outd, k + ".m4a"), os.path.join(RES, k + ".m4a"))
        manifest.append(keys[k])
    json.dump(manifest, open(MANIFEST, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    rest = [r for r in pending if r["key"] not in found]
    json.dump(rest, open(PENDING, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"imported {len(found)}; still pending {len(rest)}. Update SaryVoiceTests (entry count) and run the tests.")


if __name__ == "__main__":
    main()
