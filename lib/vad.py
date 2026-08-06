#!/usr/bin/env python3
"""
VOS voice-activity detection + incremental WAV writer.
Reads raw s16le 16kHz mono PCM on stdin; writes WAV to argv[1] (or "-" for stdout).
Auto-stops after <hangover>s of quiet following real speech (or at max seconds).

Events on stderr (machine-readable for bin/vos + humans):
  VAD_L <pct>          live level 0..100 (every ~250ms of sample time)
  VAD_SPEECH           speech started
  VAD_END <seconds>    recording finished (reason below on stderr)
  VAD_NOSPEECH         exited without speech (rc=2)

Exit: 0 ok / 2 no speech / 3 error
"""
from __future__ import annotations

import math
import os
import struct
import sys

import numpy as np

RATE = 16000
CHUNK = 2048  # samples (~128ms)

THRESH_DB = float(os.environ.get("VOS_VAD_THRESH", "-40"))       # speech floor
HANGOVER_S = float(os.environ.get("VOS_VAD_HANGOVER", "1.1"))    # quiet before stop
MIN_SPEECH_S = float(os.environ.get("VOS_VAD_MIN_SPEECH", "0.35"))
MIN_REC_S = float(os.environ.get("VOS_VAD_MIN_REC", "0.6"))
MAX_S = float(os.environ.get("VOS_VAD_MAX", "45"))


class WavWriter:
    def __init__(self, path):
        self.path = path
        self.fh = None
        self.n = 0
        self.open()

    def open(self):
        if self.path == "-":
            self.fh = sys.stdout.buffer
            self._write_header()
        else:
            self.fh = open(self.path, "wb")
            self._write_header()

    def _write_header(self):
        self.fh.write(b"RIFF")
        self.fh.write(struct.pack("<I", 0xFFFFFFFF))
        self.fh.write(b"WAVEfmt ")
        self.fh.write(struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE * 2, 2, 16))
        self.fh.write(b"data")
        self.fh.write(struct.pack("<I", 0xFFFFFFFF))

    def write(self, samples: np.ndarray):
        self.fh.write(samples.astype("<i2").tobytes())
        self.n += len(samples)

    def close(self):
        if self.fh is None:
            return
        if self.path != "-":
            try:
                self.fh.seek(4)
                self.fh.write(struct.pack("<I", 36 + self.n * 2))
                self.fh.seek(40)
                self.fh.write(struct.pack("<I", self.n * 2))
            except Exception:
                pass
        self.fh.flush()
        self.fh = None

    def abort(self):
        self.fh = None  # drop reference without flushing


def rms_db(x: np.ndarray) -> float:
    if len(x) == 0:
        return -160.0
    rms = float(np.sqrt(np.mean(x.astype(np.float64) ** 2)))
    if rms < 1e-7:
        return -160.0
    return 20.0 * math.log10(rms / 32768.0)


def level_pct(db: float) -> int:
    lo, hi = -62.0, -12.0
    p = (db - lo) / (hi - lo)
    return max(0, min(100, int(round(p * 100))))


def main() -> int:
    out_path = sys.argv[1] if len(sys.argv) > 1 else "-"
    raw = sys.stdin.buffer
    w = WavWriter(out_path)

    state = "waiting"           # waiting -> speaking -> done
    speech_start_s = None
    silence_s = 0.0
    total_s = 0.0
    last_level_emit = -1.0

    try:
        while True:
            buf = raw.read(CHUNK * 2)
            if not buf:
                break
            samples = np.frombuffer(buf, dtype="<i2").astype(np.int16)
            if len(samples) == 0:
                continue
            dur = len(samples) / RATE
            total_s += dur
            db = rms_db(samples)
            pct = level_pct(db)
            if total_s - last_level_emit >= 0.25:
                sys.stderr.write(f"VAD_L {pct}\n")
                sys.stderr.flush()
                last_level_emit = total_s

            if state == "waiting":
                if db > THRESH_DB:
                    speech_start_s = total_s
                    sys.stderr.write(f"VAD_SPEECH at {total_s:.2f}s\n")
                    sys.stderr.flush()
                    state = "speaking"
                    w.write(samples)
                continue

            if state == "speaking":
                w.write(samples)
                if db > THRESH_DB:
                    silence_s = 0.0
                else:
                    silence_s += dur

                had_speech = (total_s - speech_start_s) >= MIN_SPEECH_S
                if silence_s >= HANGOVER_S and had_speech and total_s >= MIN_REC_S:
                    state = "done"
                    break
                if total_s >= MAX_S:
                    state = "done"
                    break
    except KeyboardInterrupt:
        state = "done"
    finally:
        pass

    if state == "done" and speech_start_s is not None and total_s >= MIN_REC_S:
        end_s = total_s
        sys.stderr.write(f"VAD_END {end_s:.2f}\n")
        sys.stderr.flush()
        w.close()
        return 0

    if state == "waiting" or speech_start_s is None:
        sys.stderr.write("VAD_NOSPEECH\n")
        sys.stderr.flush()
        w.abort()
        if out_path != "-" and os.path.exists(out_path):
            try:
                os.remove(out_path)
            except OSError:
                pass
        return 2

    w.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
