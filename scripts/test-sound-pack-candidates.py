#!/usr/bin/env python3
"""Regression checks for curated sound-pack generators and committed candidates."""

from __future__ import annotations

import hashlib
import importlib.util
import math
import re
import struct
import subprocess
import sys
import unittest
from pathlib import Path
from types import ModuleType


ROOT = Path(__file__).resolve().parent.parent
TAIL_LIMIT_SECONDS = 0.080
sys.dont_write_bytecode = True


def load_script(name: str, relative_path: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {relative_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def trailing_silence_seconds(path: Path) -> float:
    duration = duration_seconds(path)
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-i",
            str(path),
            "-af",
            "silencedetect=noise=-50dB:duration=0.02",
            "-f",
            "null",
            "-",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    starts = re.findall(r"silence_start:\s*([0-9.]+)", result.stderr)
    if not starts:
        return 0.0
    return duration - float(starts[-1])


def duration_seconds(path: Path) -> float:
    return float(
        subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    )


def decoded_peak_dbfs(path: Path) -> float:
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-i",
            str(path),
            "-af",
            "astats=measure_overall=Peak_level:measure_perchannel=0",
            "-f",
            "null",
            "-",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    matches = re.findall(r"Peak level dB:\s*(-?[0-9.]+)", result.stderr)
    if not matches:
        raise AssertionError(f"could not measure decoded peak for {path}")
    return float(matches[-1])


def decoded_lufs(path: Path) -> float:
    result = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-i",
            str(path),
            "-af",
            "loudnorm=print_format=json",
            "-f",
            "null",
            "-",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    matches = re.findall(r'"input_i"\s*:\s*"(-?[0-9.]+)"', result.stderr)
    if not matches:
        raise AssertionError(f"could not measure integrated loudness for {path}")
    return float(matches[-1])


def decoded_f32_samples(path: Path) -> tuple[float, ...]:
    pcm = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-f",
            "f32le",
            "-acodec",
            "pcm_f32le",
            "-ac",
            "1",
            "-ar",
            "44100",
            "-",
        ],
        check=True,
        capture_output=True,
    ).stdout
    return struct.unpack(f"<{len(pcm) // 4}f", pcm)


class SoundPackCandidateRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.resonant = load_script(
            "generate_resonant_bowl", "scripts/generate-resonant-bowl.py"
        )
        cls.night = load_script(
            "generate_claude_default_packs",
            "scripts/generate-claude-default-packs.py",
        )

    def test_resonant_overlapping_tone_boundary_is_continuous(self) -> None:
        event = self.resonant.EVENTS["task_start"]
        samples = self.resonant.render_event(event)
        second_tone = event.tones[1]
        boundary = round(
            (second_tone.start + second_tone.duration) * self.resonant.SAMPLE_RATE
        )
        jump = abs(samples[boundary] - samples[boundary - 1])
        self.assertLess(
            jump,
            0.02,
            f"overlapping Tone boundary jumped by {jump:.6f} full-scale",
        )

    def test_resonant_lifecycle_events_share_peak_target(self) -> None:
        lifecycle_ids = ["stop", "stop_failure", "notification", "subagent_stop"]
        peak_targets = {self.resonant.EVENTS[event_id].peak_db for event_id in lifecycle_ids}
        self.assertEqual(len(peak_targets), 1, peak_targets)
        for event_id in lifecycle_ids:
            samples = self.resonant.render_event(self.resonant.EVENTS[event_id])
            peak = max(abs(sample) for sample in samples)
            peak_dbfs = 20.0 * math.log10(peak)
            self.assertAlmostEqual(
                peak_dbfs,
                next(iter(peak_targets)),
                places=5,
                msg=event_id,
            )

    def test_resonant_long_tail_reaches_zero_before_guard(self) -> None:
        event = self.resonant.EVENTS["task_start"]
        samples = self.resonant.render_event(event)
        guard_length = round(event.terminal_silence * self.resonant.SAMPLE_RATE)
        guard_start = len(samples) - guard_length
        self.assertEqual(max(abs(sample) for sample in samples[guard_start:]), 0.0)
        self.assertLess(abs(samples[guard_start] - samples[guard_start - 1]), 1.0e-8)

    def test_resonant_distribution_has_no_old_boundary_jump(self) -> None:
        samples = decoded_f32_samples(ROOT / "packs/resonant-bowl/task_start.mp3")
        window_start = round(0.79 * self.resonant.SAMPLE_RATE)
        window_end = round(0.86 * self.resonant.SAMPLE_RATE)
        jump = max(
            abs(samples[index] - samples[index - 1])
            for index in range(window_start, window_end)
        )
        self.assertLess(
            jump,
            0.02,
            f"distribution boundary jumped by {jump:.6f} full-scale",
        )

    def test_night_notification_generator_has_no_long_silent_tail(self) -> None:
        event = self.night.PACK_EVENTS["night-console"]["notification"]
        samples = self.night.render_event(event, self.night.STYLES["night-console"])
        threshold = 10.0 ** (-50.0 / 20.0)
        last_audible = max(
            index for index, sample in enumerate(samples) if abs(sample) >= threshold
        )
        tail = (len(samples) - last_audible - 1) / self.night.SAMPLE_RATE
        self.assertLessEqual(tail, TAIL_LIMIT_SECONDS, f"tail={tail:.6f}s")

    def test_reviewed_distribution_tails_meet_pack_standard(self) -> None:
        paths = [
            ROOT / "packs/night-console/notification.mp3",
            ROOT / "packs/resonant-bowl/task_start.mp3",
            ROOT / "packs/soft-mallet/notification.wav",
            ROOT / "packs/soft-mallet/stop.wav",
            ROOT / "packs/soft-mallet/stop_failure.wav",
            ROOT / "packs/soft-mallet/task_start.wav",
        ]
        failures = {}
        for path in paths:
            tail = trailing_silence_seconds(path)
            if tail > TAIL_LIMIT_SECONDS + 0.0005:
                failures[str(path.relative_to(ROOT))] = tail
        self.assertEqual(failures, {})

    def test_resonant_distribution_lifecycle_peaks_use_one_method(self) -> None:
        for event_id in ["stop", "stop_failure", "notification", "subagent_stop"]:
            path = ROOT / f"packs/resonant-bowl/{event_id}.mp3"
            peak = decoded_peak_dbfs(path)
            self.assertGreaterEqual(peak, -1.3, event_id)
            self.assertLessEqual(peak, -1.0, event_id)

    def test_changed_distribution_duration_and_true_peak(self) -> None:
        paths = [
            ROOT / "packs/night-console/notification.mp3",
            *sorted((ROOT / "packs/resonant-bowl").glob("*.mp3")),
            *sorted((ROOT / "packs/soft-mallet").glob("*.wav")),
        ]
        for path in paths:
            self.assertLessEqual(duration_seconds(path), 2.02, path.name)
            self.assertLessEqual(decoded_peak_dbfs(path), -1.0, path.name)

    def test_soft_mallet_lifecycle_distribution_uses_lufs_method(self) -> None:
        for event_id in ["stop", "stop_failure", "notification", "subagent_stop"]:
            loudness = decoded_lufs(ROOT / f"packs/soft-mallet/{event_id}.wav")
            self.assertGreaterEqual(loudness, -17.0, event_id)
            self.assertLessEqual(loudness, -15.0, event_id)

    def test_ledger_contains_current_changed_artifact_hashes(self) -> None:
        ledger = (ROOT / "packs/LICENSES.md").read_text(encoding="utf-8")
        paths = [
            ROOT / "packs/night-console/notification.mp3",
            *sorted((ROOT / "packs/resonant-bowl").glob("*.mp3")),
            *sorted((ROOT / "packs/soft-mallet").glob("*.wav")),
            ROOT / "scripts/generate-claude-default-packs.py",
            ROOT / "scripts/generate-resonant-bowl.py",
            ROOT / "scripts/generate-soft-mallet.py",
        ]
        for path in paths:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            self.assertIn(digest, ledger, str(path.relative_to(ROOT)))


if __name__ == "__main__":
    unittest.main()
