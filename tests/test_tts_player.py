import numpy as np

import tts_stream_player as player


def _reader(data):
    pos = {"i": 0}

    def read_fn(n):
        chunk = data[pos["i"]:pos["i"] + n]
        pos["i"] += len(chunk)
        return chunk

    return read_fn


def test_iter_frames_basic_passthrough():
    data = np.array([0.0, 0.25, -0.25, 0.5], dtype="<f4").tobytes()
    out = np.concatenate(list(player.iter_frames(_reader(data), 1.0, 8)))
    assert np.allclose(out, [0.0, 0.25, -0.25, 0.5])


def test_iter_frames_applies_and_clips_gain():
    data = np.array([0.5, -0.5, 1.0], dtype="<f4").tobytes()
    out = np.concatenate(list(player.iter_frames(_reader(data), 4.0, 4)))
    assert out.tolist() == [1.0, -1.0, 1.0]   # 4x gain, clipped to [-1, 1]


def test_iter_frames_drops_trailing_partial_sample():
    data = np.array([0.1, 0.2], dtype="<f4").tobytes() + b"\x00\x00"  # 2 stray bytes
    out = np.concatenate(list(player.iter_frames(_reader(data), 1.0, 64)))
    assert out.shape == (2,)
