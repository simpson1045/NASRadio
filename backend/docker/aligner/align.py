#!/usr/bin/env python3
"""Word-level lyric timing for karaoke fill (prototype, Oct 30 2026).

We already have LRC lyrics (one timestamp per LINE). This finds when each
WORD is sung by forced alignment: the text is known, so a CTC speech model
only has to place each word inside its line's window, which is far easier
and more accurate than transcription.

  1. Demucs (htdemucs) isolates the vocals so guitars/drums don't confuse it
     (CPU: the NAS GTX 1050 has only 2 GB, kept for the aligner).
  2. torchaudio MMS_FA (wav2vec2 CTC, ~1 GB) aligns each line's words inside
     [line start - 0.75 s, next line start + 0.75 s] on the GPU.
  3. Normalized words map back to the original display words (punctuation,
     capitals, "—" kept) and we write:
       {"version": 1, "song_id": N, "lines": [
           {"t": 12.34, "text": "...", "words": [{"w": "Two", "s": 12.4, "e": 12.7}, ...]}]}

Usage: align.py <audio file> <lyrics.lrc> <out.json> [--song-id N] [--no-demucs]
"""

import argparse
import json
import re
import sys
import time

import torch
import torchaudio

LRC_LINE = re.compile(r"^\s*\[(\d+):(\d+(?:\.\d+)?)\](.*)$")
PAD = 0.75          # seconds of slack around each line's window
LAST_LINE_SPAN = 8  # seconds given to the final line
# No sung line is longer than this. Without the cap a line before a long solo
# got the whole gap (2 Minutes to Midnight: 100 s) and ran the 2 GB 1050 out
# of memory.
MAX_LINE_SPAN = 12


def parse_lrc(text):
    lines = []
    for raw in text.splitlines():
        m = LRC_LINE.match(raw)
        if not m:
            continue
        t = int(m.group(1)) * 60 + float(m.group(2))
        words = m.group(3).strip()
        lines.append((t, words))
    lines.sort(key=lambda x: x[0])
    return lines


def norm_word(w):
    """MMS_FA's dictionary is lowercase latin letters plus apostrophe."""
    w = w.lower().replace("’", "'").replace("‘", "'")
    w = re.sub(r"[^a-z']", "", w)
    return w.strip("'")


def separate_vocals(wave, sr):
    """htdemucs vocals stem on CPU. wave: [channels, samples] at sr."""
    from demucs.apply import apply_model
    from demucs.pretrained import get_model

    model = get_model("htdemucs")
    model.eval()
    if sr != model.samplerate:
        wave = torchaudio.functional.resample(wave, sr, model.samplerate)
        sr = model.samplerate
    if wave.shape[0] == 1:
        wave = wave.repeat(2, 1)
    ref = wave.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    with torch.no_grad():
        sources = apply_model(model, ((wave - mean) / std)[None], device="cpu",
                              split=True, overlap=0.25, progress=False)[0]
    vocals = sources[model.sources.index("vocals")] * std + mean
    return vocals, sr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("lrc")
    ap.add_argument("out")
    ap.add_argument("--song-id", type=int, default=None)
    ap.add_argument("--no-demucs", action="store_true")
    args = ap.parse_args()
    t0 = time.time()

    lines = parse_lrc(open(args.lrc, encoding="utf-8").read())
    if not lines:
        sys.exit("no timed lines in the LRC")

    wave, sr = torchaudio.load(args.audio)
    duration = wave.shape[1] / sr
    if args.no_demucs:
        vocals, vsr = wave, sr
    else:
        vocals, vsr = separate_vocals(wave, sr)
    t_sep = time.time()
    mono = torchaudio.functional.resample(vocals.mean(0, keepdim=True), vsr, 16000)

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    bundle = torchaudio.pipelines.MMS_FA
    model = bundle.get_model(with_star=False).to(device).eval()
    tokenizer = bundle.get_tokenizer()
    aligner = bundle.get_aligner()

    out_lines = []
    for i, (t, text) in enumerate(lines):
        display = text.split()
        normed = [norm_word(w) for w in display]
        keep = [j for j, w in enumerate(normed) if w]
        entry = {"t": round(t, 3), "text": text, "words": []}
        if keep:
            end_t = lines[i + 1][0] if i + 1 < len(lines) else min(t + LAST_LINE_SPAN, duration)
            end_t = min(end_t, t + MAX_LINE_SPAN)
            a = max(0.0, t - PAD)
            b = min(duration, end_t + PAD)
            seg = mono[:, int(a * 16000):int(b * 16000)]
            if seg.shape[1] > 16000 * 0.3:
                emission = None
                with torch.inference_mode():
                    try:
                        emission, _ = model(seg.to(device))
                    except torch.OutOfMemoryError:
                        # One long window: do just this line on the CPU.
                        torch.cuda.empty_cache()
                        emission, _ = model.cpu()(seg)
                        model.to(device)
                        emission = emission.to(device)
                try:
                    spans = aligner(emission[0], tokenizer([normed[j] for j in keep]))
                    ratio = seg.shape[1] / emission.shape[1] / 16000
                    timed = {}
                    for j, word_spans in zip(keep, spans):
                        timed[j] = (a + word_spans[0].start * ratio,
                                    a + word_spans[-1].end * ratio)
                    # Words with no letters ("—", "&") ride with a neighbour.
                    last = None
                    for j, w in enumerate(display):
                        if j in timed:
                            last = timed[j]
                            s, e = last
                        else:
                            s = e = (last[1] if last else (timed[keep[0]][0]))
                        entry["words"].append({"w": w, "s": round(s, 3), "e": round(e, 3)})
                except Exception as e:  # alignment can fail on a bad window
                    entry["error"] = str(e)[:120]
        out_lines.append(entry)

    # A word may not run past the start of the next one (held last words
    # used to swallow the next line's first word, e.g. "love" over "Along").
    flat = [w for l in out_lines for w in l["words"]]
    for a, b in zip(flat, flat[1:]):
        if a["e"] > b["s"] >= a["s"]:
            a["e"] = b["s"]

    result = {"version": 1, "song_id": args.song_id, "model": "MMS_FA",
              "demucs": not args.no_demucs, "device": str(device),
              "seconds": {"separate": round(t_sep - t0, 1),
                          "total": round(time.time() - t0, 1)},
              "lines": out_lines}
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    print(json.dumps(result["seconds"]), "lines:", len(out_lines),
          "aligned:", sum(1 for l in out_lines if l["words"]),
          "errors:", sum(1 for l in out_lines if "error" in l))


if __name__ == "__main__":
    main()
