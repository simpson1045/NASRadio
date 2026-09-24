"""Spectral transcode-detection worker — runs as a SEPARATE PROCESS.

Genuine lossless rips carry energy (music or at least noise floor) up
toward Nyquist (22.05 kHz for CD). Files transcoded from a lossy source
inherit the encoder's brick-wall lowpass: a sharp cliff in the spectrum,
typically 16-20.5 kHz depending on codec/bitrate (MP3 128 ≈ 16k,
MP3 V0 ≈ 19.5k, MP3 320 ≈ 20.5k). We average an STFT power spectrum over
a few windows of the track and look for that cliff.

Deliberately a standalone script with NO app imports: the backend runs
under eventlet, and librosa/numpy FFT work is CPU-bound — done in-process
it would freeze the hub (streams, /api/health, websockets). The
orchestrator (spectral_analysis.py) invokes this via safe_subprocess_run.

Invocation (batch — amortizes the ~2-4s librosa import across a chunk):
    python spectral_worker.py --list <file-with-one-audio-path-per-line>
Or a single file (handy for manual testing):
    python spectral_worker.py <audio_file>

Output: one JSON object per input line on stdout:
    {"path": ..., "sample_rate": 44100, "cutoff_hz": 20512,
     "cliff_db": 34.2, "suspect": true}
or {"path": ..., "error": "..."} — the batch always continues.

Known limitation (inherent to spectral methods): high-bitrate AAC (256k+)
can preserve content to ~22 kHz and is indistinguishable from lossless
here. MP3 at any bitrate and low-bitrate AAC/Vorbis are caught.
"""

import json
import sys

import numpy as np

# Analysis windows: a few short slices spread across the track so one
# quiet intro/outro can't skew the average spectrum.
WINDOW_SECONDS = 8.0
WINDOW_POSITIONS = (0.25, 0.50, 0.75)  # fractions of duration

# STFT resolution. 8192 @ 44.1k → ~5.4 Hz/bin; plenty to localize a cliff.
N_FFT = 8192

# A drop this steep across ~1.1 kHz is an encoder lowpass, not natural
# rolloff — real program material (even old masters) falls off gradually.
CLIFF_DB = 20.0

# Only call it a transcode if the cliff sits below this — the lossy-encoder
# signature, independent of container rate. CD mastering lowpass filters
# legitimately live at ~21-22 kHz; MP3 320 tops out at ~20.5 kHz, so 20.8k
# splits them. Deliberately NOT higher for hi-res files: a 96k file whose
# content dies at ~22 kHz is an upsampled CD-rate master (fake hi-res, but
# still lossless bandwidth — observed live: AC/DC Stiff Upper Lip 24/96,
# textbook 44.1k anti-alias rolloff at 21.5-22k, silence to 48k). An
# upsampled MP3 would still cut <= ~20.5 kHz and stays caught. Fake hi-res
# remains queryable: sample rate > 48k with spectral_cutoff_hz ~22k.
SUSPECT_LIMIT = 20800.0

# If the mid-band (2-8 kHz) reference sits this far below peak, the
# windows we sampled are essentially silence — no verdict.
QUIET_FLOOR_DB = -70.0

# The region above the cliff must be genuinely DEAD to call it a transcode —
# but only for cliffs in the borderline zone (>= 18 kHz). Lossy decode chains
# leave true digital silence above the encoder lowpass (~-120 dB eps floor).
# Early-digital CD masters (mid-80s) ALSO brick-wall at ~20.5 kHz — but their
# noise-shaped dither fills the top octave at -85..-95 dB, well above this
# line. Observed live: Van Halen 5150 (1986) cliffs at 20.6 kHz with dither
# above → legit, while MP3/AAC controls measure < -115 dB above the cutoff.
# BELOW 18 kHz no legitimate CD mastering filter exists, so a hard cliff is
# damning by itself — and requiring a dead tail there would miss transcodes
# that picked up analog hiss after the lossy stage (observed: song 41804,
# 49 dB wall at 11.8 kHz with -72 dB hiss above it).
DEAD_ABOVE_DB = -105.0
TAIL_CHECK_ABOVE_HZ = 18000.0


def _average_spectrum(path):
    """Median power spectrum over the analysis windows. Returns (spec, sr).

    Median across STFT frames, NOT mean: percussive transients (and, with
    center=True, librosa's reflection-padded edge frames) splatter broadband
    energy that a mean smears across the whole spectrum — measured at ~-72 dB,
    enough to completely bury an encoder brick wall whose true floor is
    -120 dB. The median ignores those outlier frames and shows the real
    per-bin noise floor. Blackman-Harris window for the same reason: Hann
    sidelobe leakage from loud bass content sets a false HF floor.
    """
    import librosa
    import soundfile as sf

    info = sf.info(path)
    sr = info.samplerate
    duration = info.frames / float(sr)

    if duration <= WINDOW_SECONDS + 1:
        offsets = [0.0]
    elif duration < 60:
        offsets = [max(0.0, duration / 2 - WINDOW_SECONDS / 2)]
    else:
        offsets = [duration * p for p in WINDOW_POSITIONS]

    specs = []
    for off in offsets:
        y, sr = librosa.load(
            path, sr=None, mono=True, offset=off, duration=WINDOW_SECONDS
        )
        if len(y) < N_FFT:
            continue
        stft = librosa.stft(
            y,
            n_fft=N_FFT,
            hop_length=N_FFT // 2,
            window="blackmanharris",
            center=False,
        )
        specs.append(np.median(np.abs(stft) ** 2, axis=1))

    if not specs:
        raise ValueError("file too short to analyze")
    return np.mean(specs, axis=0), sr


def analyze(path):
    spec, sr = _average_spectrum(path)
    nyquist = sr / 2.0
    freqs = np.linspace(0.0, nyquist, len(spec))
    bin_hz = freqs[1] - freqs[0]

    # dB relative to the loudest bin, smoothed over ~120 Hz so single-bin
    # wiggle doesn't fake a cliff edge.
    s_db = 10.0 * np.log10(spec / (spec.max() + 1e-30) + 1e-12)
    w = max(3, int(round(120.0 / bin_hz)))
    s_db = np.convolve(s_db, np.ones(w) / w, mode="same")

    mid = (freqs >= 2000.0) & (freqs <= 8000.0)
    ref_db = float(np.median(s_db[mid]))

    # Highest frequency still carrying content (within 60 dB of mid-band).
    above = np.where((s_db > ref_db - 60.0) & (freqs > 4000.0))[0]
    extent_hz = float(freqs[above[-1]]) if len(above) else float(freqs[mid][-1])

    result = {
        "path": path,
        "sample_rate": int(sr),
        "cutoff_hz": int(round(extent_hz)),
        "cliff_db": 0.0,
        "suspect": False,
    }

    # Sampled windows are near-silence — a spectrum of noise proves nothing.
    if ref_db < QUIET_FLOOR_DB:
        return result

    # Cliff scan: compare mean level in a 500 Hz band just below each
    # candidate frequency vs just above it (100 Hz guard gap). Encoder
    # lowpass → one candidate with a huge drop.
    look = max(1, int(round(500.0 / bin_hz)))
    gap = max(1, int(round(100.0 / bin_hz)))
    lo = int(np.searchsorted(freqs, 10000.0))
    hi = int(np.searchsorted(freqs, nyquist - 800.0))
    if hi <= lo:
        return result  # sr too low for a meaningful scan (e.g. 22 kHz files)

    csum = np.concatenate(([0.0], np.cumsum(s_db)))

    def band_mean(i0, i1):
        i0, i1 = max(0, i0), min(len(s_db), i1)
        return (csum[i1] - csum[i0]) / max(1, i1 - i0) if i1 > i0 else -np.inf

    best_idx, best_drop, best_before = -1, 0.0, -np.inf
    for i in range(lo, hi):
        before = band_mean(i - gap - look, i - gap)
        after = band_mean(i + gap, i + gap + look)
        drop = before - after
        if drop > best_drop:
            best_idx, best_drop, best_before = i, drop, before

    # A real cliff needs actual content on its low side — a 20 dB step
    # deep inside the noise floor is just noise shaping.
    if best_idx >= 0 and best_drop >= CLIFF_DB and best_before > ref_db - 50.0:
        cutoff_hz = float(freqs[best_idx])
        limit = SUSPECT_LIMIT

        # Everything from 1 kHz past the cliff up to Nyquist: encoder
        # output is digital silence there; a mastering filter leaves
        # noise-shaped dither. See DEAD_ABOVE_DB.
        tail_lo = int(np.searchsorted(freqs, cutoff_hz + 1000.0))
        tail_hi = int(np.searchsorted(freqs, nyquist - 200.0))
        tail_db = band_mean(tail_lo, tail_hi) if tail_hi > tail_lo else -200.0

        result["cutoff_hz"] = int(round(cutoff_hz))
        result["cliff_db"] = round(float(best_drop), 1)
        result["tail_db"] = round(float(tail_db), 1)
        # bool(): and/or return an operand, and numpy comparisons yield
        # np.bool_, which json.dumps rejects ("Object of type bool is not
        # JSON serializable" — numpy 2.x repr). Crashed whole chunks live.
        result["suspect"] = bool(
            cutoff_hz < limit
            and (cutoff_hz < TAIL_CHECK_ABOVE_HZ or tail_db < DEAD_ABOVE_DB)
        )

    return result


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: spectral_worker.py <file> | --list <listfile>"}))
        sys.exit(2)

    if sys.argv[1] == "--list":
        with open(sys.argv[2], "r", encoding="utf-8") as f:
            paths = [line.strip() for line in f if line.strip()]
    else:
        paths = [sys.argv[1]]

    for path in paths:
        try:
            out = analyze(path)
        except Exception as e:  # keep the batch moving, report per-file
            out = {"path": path, "error": f"{type(e).__name__}: {e}"}
        # default=: last-resort coercion for any numpy scalar that sneaks
        # into a result — one unserializable value must never kill the
        # remaining files in the chunk.
        print(
            json.dumps(
                out,
                default=lambda o: o.item() if hasattr(o, "item") else str(o),
            ),
            flush=True,
        )


if __name__ == "__main__":
    main()
