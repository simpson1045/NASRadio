from flask import Flask, request, jsonify
import essentia.standard as es
from essentia.standard import TensorflowPredictEffnetDiscogs, TensorflowPredict2D
import numpy as np
import os
import json
import subprocess
import tempfile

app = Flask(__name__)

# Model paths
MODELS_DIR = os.path.join(os.path.dirname(__file__), 'models')
EMBEDDING_MODEL = os.path.join(MODELS_DIR, 'discogs-effnet-bs64-1.pb')
GENRE_MODEL = os.path.join(MODELS_DIR, 'genre_discogs400-discogs-effnet-1.pb')
GENRE_LABELS_FILE = os.path.join(MODELS_DIR, 'genre_discogs400-discogs-effnet-1.json')

# Binary classifiers: (model_path, positive_class_index)
BINARY_MODELS = {
    'happy': (os.path.join(MODELS_DIR, 'mood_happy-discogs-effnet-1.pb'), 0),
    'sad': (os.path.join(MODELS_DIR, 'mood_sad-discogs-effnet-1.pb'), 1),
    'aggressive': (os.path.join(MODELS_DIR, 'mood_aggressive-discogs-effnet-1.pb'), 0),
    'relaxed': (os.path.join(MODELS_DIR, 'mood_relaxed-discogs-effnet-1.pb'), 1),
    'acoustic': (os.path.join(MODELS_DIR, 'mood_acoustic-discogs-effnet-1.pb'), 0),
    'electronic': (os.path.join(MODELS_DIR, 'mood_electronic-discogs-effnet-1.pb'), 0),
    'danceability': (os.path.join(MODELS_DIR, 'danceability-discogs-effnet-1.pb'), 0),
    'instrumental': (os.path.join(MODELS_DIR, 'voice_instrumental-discogs-effnet-1.pb'), 0),
    'party': (os.path.join(MODELS_DIR, 'mood_party-discogs-effnet-1.pb'), 1),
    'tonal': (os.path.join(MODELS_DIR, 'tonal_atonal-discogs-effnet-1.pb'), 1),
    'bright': (os.path.join(MODELS_DIR, 'timbre-discogs-effnet-1.pb'), 0),
}

# Multi-label models
INSTRUMENT_MODEL = os.path.join(MODELS_DIR, 'mtg_jamendo_instrument-discogs-effnet-1.pb')
INSTRUMENT_LABELS_FILE = os.path.join(MODELS_DIR, 'mtg_jamendo_instrument-discogs-effnet-1.json')
MOODTHEME_MODEL = os.path.join(MODELS_DIR, 'mtg_jamendo_moodtheme-discogs-effnet-1.pb')
MOODTHEME_LABELS_FILE = os.path.join(MODELS_DIR, 'mtg_jamendo_moodtheme-discogs-effnet-1.json')
GENDER_MODEL = os.path.join(MODELS_DIR, 'gender-discogs-effnet-1.pb')

# Load labels
with open(GENRE_LABELS_FILE, 'r') as f:
    GENRE_LABELS = json.load(f)['classes']

with open(INSTRUMENT_LABELS_FILE, 'r') as f:
    INSTRUMENT_LABELS = json.load(f)['classes']

with open(MOODTHEME_LABELS_FILE, 'r') as f:
    MOODTHEME_LABELS = json.load(f)['classes']

# Cached TF model instances. Loading these from disk takes ~100-200ms
# each and there are ~14 of them — re-instantiating per request was the
# main source of per-song latency AND a likely contributor to long-run
# instability. With caching, the FIRST /analyze pays the load cost; all
# subsequent calls reuse the same TF session.
print("Loading TF models (one-time)...")
_EMBEDDING_MODEL = TensorflowPredictEffnetDiscogs(
    graphFilename=EMBEDDING_MODEL,
    output="PartitionedCall:1"
)
_GENRE_MODEL = TensorflowPredict2D(
    graphFilename=GENRE_MODEL,
    input="serving_default_model_Placeholder",
    output="PartitionedCall:0"
)
_BINARY_MODELS_CACHE = {}
for _name, (_path, _idx) in BINARY_MODELS.items():
    if os.path.exists(_path):
        _BINARY_MODELS_CACHE[_name] = (
            TensorflowPredict2D(
                graphFilename=_path,
                input="model/Placeholder",
                output="model/Softmax",
            ),
            _idx,
        )
_INSTRUMENT_MODEL_OBJ = TensorflowPredict2D(
    graphFilename=INSTRUMENT_MODEL,
    input="model/Placeholder",
    output="model/Sigmoid",
) if os.path.exists(INSTRUMENT_MODEL) else None
_MOODTHEME_MODEL_OBJ = TensorflowPredict2D(
    graphFilename=MOODTHEME_MODEL,
    input="model/Placeholder",
    output="model/Sigmoid",
) if os.path.exists(MOODTHEME_MODEL) else None
_GENDER_MODEL_OBJ = TensorflowPredict2D(
    graphFilename=GENDER_MODEL,
    input="model/Placeholder",
    output="model/Softmax",
) if os.path.exists(GENDER_MODEL) else None
print("TF models loaded and cached.")

# ── Decoding ────────────────────────────────────────────────────────────
# Every file goes through ffmpeg ONCE, to a 44.1 kHz mono float WAV, and
# Essentia only ever loads that. Two reasons (2026-09-13 post-mortem):
#  1. Memory. MonoLoader decodes at the file's native rate and channel count
#     before downmixing. A 23-minute 192 kHz/24-bit FLAC was 2.1 GB per load,
#     and BPM, key and loudness each loaded it again: 3 GB cap, OOM kill,
#     19 container restarts. ffmpeg streams, so the same file now costs
#     ~10 MB per minute, and the one buffer is shared by every extractor.
#  2. Crashes. Essentia's C++ AudioLoader aborts the whole process on
#     containers it dislikes (opus, ape, wv, dsf). It never sees them now.
MIN_DURATION_SEC = 3
MAX_DURATION_SEC = 1800
# Peak memory grows ~1.25 MB per second of audio (measured 2026-09-20: a
# 1,389 s track peaked at 2.14 GB under the 3 GB cap), so a full 30-minute
# track would sit at ~2.7 GB. Tracks up to MAX_DURATION_SEC are accepted,
# but only the first ANALYZE_WINDOW_SEC are decoded — BPM, key, genre and
# mood don't need minutes 26-30, and the margin stays comfortable.
ANALYZE_WINDOW_SEC = 1500
DECODE_TIMEOUT_SEC = 300


class Unanalyzable(Exception):
    """The input itself is the problem (too short/long, won't decode).
    Retrying won't help; the backend records it and moves on."""


def probe_duration(file_path):
    try:
        out = subprocess.run(
            ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
             '-of', 'default=nw=1:nk=1', file_path],
            capture_output=True, text=True, timeout=30)
        return float(out.stdout.strip().splitlines()[0])
    except Exception:
        raise Unanalyzable('ffprobe could not read a duration')


def decode_once(file_path):
    """Returns (audio at 44.1 kHz mono float32, duration in seconds)."""
    duration = probe_duration(file_path)
    if duration < MIN_DURATION_SEC:
        raise Unanalyzable(f'too short to analyze ({duration:.1f}s)')
    if duration > MAX_DURATION_SEC:
        raise Unanalyzable(f'too long to analyze ({duration / 60:.0f} min)')

    fd, tmp_path = tempfile.mkstemp(suffix='.wav')
    os.close(fd)
    try:
        try:
            r = subprocess.run(
                ['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', file_path,
                 '-map', '0:a:0', '-vn', '-ac', '1', '-ar', '44100',
                 '-c:a', 'pcm_f32le', '-t', str(ANALYZE_WINDOW_SEC), tmp_path],
                capture_output=True, timeout=DECODE_TIMEOUT_SEC)
        except subprocess.TimeoutExpired:
            raise Unanalyzable(f'ffmpeg decode timed out after {DECODE_TIMEOUT_SEC}s')
        if r.returncode != 0 or os.path.getsize(tmp_path) < 1024:
            err = (r.stderr or b'').decode('utf-8', 'replace').strip().splitlines()
            raise Unanalyzable('ffmpeg could not decode it: ' + (err[-1][:160] if err else 'no output'))
        audio = es.MonoLoader(filename=tmp_path, sampleRate=44100)()
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
    if len(audio) < 44100 * MIN_DURATION_SEC:
        raise Unanalyzable('decoded to almost nothing')
    return audio, duration


def to_16k(audio_44k):
    """The ML models want 16 kHz; resample the buffer we already have."""
    return es.Resample(inputSampleRate=44100, outputSampleRate=16000)(audio_44k)


def get_embeddings(audio):
    """Get embeddings from the cached effnet model"""
    return _EMBEDDING_MODEL(audio)

def predict_genres(embeddings, top_n=10):
    """Get genre predictions (cached model)"""
    predictions = _GENRE_MODEL(embeddings)
    avg_predictions = np.mean(predictions, axis=0)

    top_indices = np.argsort(avg_predictions)[::-1][:top_n]
    return [
        {"genre": GENRE_LABELS[i], "confidence": round(float(avg_predictions[i]), 3)}
        for i in top_indices
    ]

def predict_binary_cached(embeddings, mood_name):
    """Get binary classifier prediction using a cached model."""
    entry = _BINARY_MODELS_CACHE.get(mood_name)
    if entry is None:
        return None
    model, positive_index = entry
    predictions = model(embeddings)
    avg_predictions = np.mean(predictions, axis=0)
    return float(avg_predictions[positive_index])

def predict_binary(embeddings, model_path, positive_index):
    """Legacy entry point — kept so anything outside the cache still
    works. Prefer predict_binary_cached(mood_name) for hot-path calls.
    """
    model = TensorflowPredict2D(
        graphFilename=model_path,
        input="model/Placeholder",
        output="model/Softmax"
    )
    predictions = model(embeddings)
    avg_predictions = np.mean(predictions, axis=0)
    return float(avg_predictions[positive_index])

def predict_multilabel_with_model(model_obj, embeddings, labels, top_n=10):
    """Multi-label predictions using a pre-loaded model object."""
    predictions = model_obj(embeddings)
    avg_predictions = np.mean(predictions, axis=0)
    top_indices = np.argsort(avg_predictions)[::-1][:top_n]
    return [
        {"label": labels[i], "confidence": round(float(avg_predictions[i]), 3)}
        for i in top_indices
    ]

def predict_multilabel(embeddings, model_path, labels, top_n=10):
    """Legacy: load + predict. Hot path uses predict_multilabel_with_model."""
    model = TensorflowPredict2D(
        graphFilename=model_path,
        input="model/Placeholder",
        output="model/Sigmoid"
    )
    return predict_multilabel_with_model(model, embeddings, labels, top_n)

def predict_gender(embeddings):
    """Get gender prediction (cached model)"""
    if _GENDER_MODEL_OBJ is None:
        return None
    predictions = _GENDER_MODEL_OBJ(embeddings)
    avg_predictions = np.mean(predictions, axis=0)
    return {
        "female": round(float(avg_predictions[0]), 3),
        "male": round(float(avg_predictions[1]), 3)
    }

def analyze_bpm(audio):
    """Detect BPM using RhythmExtractor2013 (audio: 44.1 kHz mono)"""
    rhythm_extractor = es.RhythmExtractor2013(method="multifeature")
    bpm, beats, beats_confidence, _, beats_intervals = rhythm_extractor(audio)
    return {
        "bpm": round(float(bpm), 1),
        "confidence": round(float(beats_confidence), 3)
    }

def analyze_key(audio):
    """Detect musical key using KeyExtractor (audio: 44.1 kHz mono)"""
    key_extractor = es.KeyExtractor()
    key, scale, strength = key_extractor(audio)
    return {
        "key": key,
        "scale": scale,
        "confidence": round(float(strength), 3)
    }

def analyze_loudness(audio):
    """Analyze loudness/dynamics (audio: 44.1 kHz mono).

    Returns BOTH the legacy Steven's-power-law loudness (kept for
    backward compatibility with existing DB rows + the old
    ratio-based normalization formula) AND the EBU R128 integrated
    loudness in LUFS, plus loudness range and true peak. The LUFS
    values are what every streaming service uses for volume
    normalization — K-weighted, perceptually-correct, and on a
    consistent scale across all music.
    """

    # Legacy Steven's-power-law loudness (arbitrary positive units)
    loudness_legacy = es.Loudness()(audio)
    dynamic_complexity = es.DynamicComplexity()(audio)

    # EBU R128 — needs stereo and 44.1 kHz. Our audio is mono at 44.1k,
    # so we duplicate the channel into a stereo signal as the algorithm
    # expects. integratedLoudness is the long-term LUFS value used for
    # normalization. loudnessRange is in LU (loudness units, relative).
    integrated_lufs = None
    loudness_range = None
    try:
        import numpy as np
        stereo = np.stack([audio, audio], axis=1).astype("float32")
        ebu = es.LoudnessEBUR128(sampleRate=44100)
        _, _, integrated_lufs_raw, loudness_range_raw = ebu(stereo)
        del stereo  # a second full-length copy; don't hold it through the rest
        integrated_lufs = round(float(integrated_lufs_raw), 2)
        loudness_range = round(float(loudness_range_raw), 2)
    except Exception as e:
        print(f"LoudnessEBUR128 failed: {e}")

    # True peak in dBFS (max absolute sample, converted to dB)
    true_peak_dbfs = None
    try:
        import numpy as np
        peak = float(np.max(np.abs(audio)))
        if peak > 0:
            true_peak_dbfs = round(20.0 * np.log10(peak), 2)
    except Exception:
        pass

    return {
        "loudness": round(float(loudness_legacy), 2),
        "dynamic_complexity": round(float(dynamic_complexity[0]), 3),
        "integrated_loudness_lufs": integrated_lufs,
        "loudness_range_lu": loudness_range,
        "true_peak_dbfs": true_peak_dbfs,
    }

@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        "status": "ok",
        "genre_count": len(GENRE_LABELS),
        "instrument_count": len(INSTRUMENT_LABELS),
        "moodtheme_count": len(MOODTHEME_LABELS),
        "binary_models": list(BINARY_MODELS.keys())
    })

@app.route('/analyze', methods=['POST'])
def analyze():
    data = request.json
    file_path = data.get('file_path')
    print(f"Received request for: {file_path}", flush=True)

    if not file_path or not os.path.exists(file_path):
        return jsonify({"error": f"File not found: {file_path}", "permanent": True}), 400

    try:
        # One ffmpeg decode, shared by everything below.
        audio_44k, duration = decode_once(file_path)
        audio = to_16k(audio_44k)

        # Get embeddings (shared across all models)
        embeddings = get_embeddings(audio)
        del audio  # the 16 kHz copy is only for the embedding model

        # Get genre predictions
        genres = predict_genres(embeddings)

        # Get binary mood/feature scores (cached models)
        moods = {}
        for mood_name in BINARY_MODELS.keys():
            val = predict_binary_cached(embeddings, mood_name)
            if val is not None:
                moods[mood_name] = round(val, 3)

        # Get instruments (cached model)
        instruments = []
        if _INSTRUMENT_MODEL_OBJ is not None:
            instruments = predict_multilabel_with_model(
                _INSTRUMENT_MODEL_OBJ, embeddings, INSTRUMENT_LABELS
            )

        # Get mood themes (cached model)
        themes = []
        if _MOODTHEME_MODEL_OBJ is not None:
            themes = predict_multilabel_with_model(
                _MOODTHEME_MODEL_OBJ, embeddings, MOODTHEME_LABELS
            )

        # Get voice gender
        voice_gender = predict_gender(embeddings)

        # Get BPM, Key, and Loudness. Each in its own try/except so a
        # failure in one extractor (looking at you, RhythmExtractor2013
        # "output buffer full" bug on certain files) does not lose the
        # other measurements. Returns None for the failed extractor.
        try:
            bpm_info = analyze_bpm(audio_44k)
        except Exception as e:
            print(f"BPM extraction failed: {e}")
            bpm_info = None
        try:
            key_info = analyze_key(audio_44k)
        except Exception as e:
            print(f"Key extraction failed: {e}")
            key_info = None
        try:
            loudness_info = analyze_loudness(audio_44k)
        except Exception as e:
            print(f"Loudness extraction failed: {e}")
            loudness_info = None

        results = {
            "file": file_path,
            "duration": round(duration, 2),
            "bpm": bpm_info,
            "key": key_info,
            "loudness": loudness_info,
            "genres": genres,
            "moods": moods,
            "instruments": instruments,
            "themes": themes,
            "voice_gender": voice_gender
        }

        return jsonify(results)
    except Unanalyzable as e:
        print(f"Unanalyzable: {file_path}: {e}", flush=True)
        return jsonify({"error": str(e), "permanent": True}), 422
    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({"error": str(e), "traceback": traceback.format_exc()}), 500


@app.route('/analyze-loudness', methods=['POST'])
def analyze_loudness_only():
    """Fast-path endpoint: just the loudness/dynamics analysis, no ML.
    Used by the backend to backfill LUFS into already-analyzed rows
    without re-running the expensive Discogs-Effnet inference.
    Roughly 10x faster than the full /analyze for a typical song.
    """
    data = request.json
    file_path = data.get('file_path')
    if not file_path or not os.path.exists(file_path):
        return jsonify({"error": f"File not found: {file_path}", "permanent": True}), 400
    try:
        audio_44k, _duration = decode_once(file_path)
        loudness_info = analyze_loudness(audio_44k)
        return jsonify({"file": file_path, "loudness": loudness_info})
    except Unanalyzable as e:
        print(f"Unanalyzable: {file_path}: {e}", flush=True)
        return jsonify({"error": str(e), "permanent": True}), 422
    except Exception as e:
        import traceback
        traceback.print_exc()
        return jsonify({"error": str(e), "traceback": traceback.format_exc()}), 500


if __name__ == '__main__':
    print("Starting Essentia Analysis Service...")
    print(f"Loaded {len(GENRE_LABELS)} genres, {len(INSTRUMENT_LABELS)} instruments, {len(MOODTHEME_LABELS)} themes")
    print(f"Binary models: {list(BINARY_MODELS.keys())}")
    app.run(host='0.0.0.0', port=5005, debug=False, threaded=True)
