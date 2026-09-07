#!/usr/bin/env python3
"""Build the soft-mallet cue pack from pinned CC0 VCSL recordings.

The script downloads seven real struck-idiophone recordings from one immutable VCSL
commit, verifies every source hash, and then uses ffmpeg only for trimming,
pitching, filtering, sequencing, fades, and PCM encoding. It does not generate
oscillators or noise.
"""

from __future__ import annotations

import argparse
import hashlib
import math
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path


COMMIT = "c1ea7bcc3c7309650ab0da9d15c9cd1fbc4a4c7e"
RAW_ROOT = f"https://raw.githubusercontent.com/sgossner/VCSL/{COMMIT}"
SAMPLE_RATE = 44_100
TERMINAL_SILENCE = 0.060


@dataclass(frozen=True)
class Source:
    path: str
    sha256: str
    active_seconds: float


@dataclass(frozen=True)
class Strike:
    source: str
    start: float
    gain_db: float = 0.0
    semitones: float = 0.0
    length: float | None = None
    fade_in: float = 0.008


@dataclass(frozen=True)
class Cue:
    audible_seconds: float
    strikes: tuple[Strike, ...]
    target_peak_dbfs: float | None = None
    target_lufs: float | None = None
    lowpass_hz: int = 6_500


SOURCES = {
    "C4": Source(
        "Idiophones/Struck Idiophones/Marimba/Marimba_hit_Outrigger_C4_soft_01.wav",
        "4d03d005166e8b366e6a983b7a4a89e0847e1d58a6d34dda35ddf74289cace94",
        0.72,
    ),
    "G4": Source(
        "Idiophones/Struck Idiophones/Marimba/Marimba_hit_Outrigger_G4_soft_01.wav",
        "d3e23f018b091a60d91c3c93b38b605d02a9e26c7cf5830ffb866cfe84130cd0",
        0.54,
    ),
    "F3": Source(
        "Idiophones/Struck Idiophones/Marimba/Marimba_hit_Outrigger_F3_soft_01.wav",
        "6eb7ccf5fa10b1bdaf10f0cc7a50d8c42ef086636a9e88c6527fb3af58e5ee1f",
        0.78,
    ),
    "VibeC5": Source(
        "Idiophones/Struck Idiophones/Vibraphone/Soft Mallets/Vibes_soft_C5_v1_rr1_Main.wav",
        "be995c1164dcbbcf83688d095864a4abd0feaa68b71d1d2e78c35f62461fc03b",
        0.60,
    ),
    "LogHi": Source(
        "Idiophones/Struck Idiophones/Slit Drum/LogDrumHi_MedM_v1_rr1_Sum.wav",
        "6ca70964e7d1dd80daf6c67cff226db6e0cadbff3234944de9055c3ef1d7f4eb",
        0.38,
    ),
    "LogLo": Source(
        "Idiophones/Struck Idiophones/Slit Drum/LogDrumLo_MedM_v1_rr1_Sum.wav",
        "cb77b9a6e7fc560d03b45102632ee0be5d08158cb03f59d63dd6fd2c4443ba4f",
        0.43,
    ),
    "ChimeE4": Source(
        "Idiophones/Struck Idiophones/Hand Chimes/sus_E4_r01_main.wav",
        "7196b23009e1acc8e03591c35e54144487991c75cfe22413e84e0bbfeb478caf",
        0.42,
    ),
}


CUES = {
    # A compact open fifth: motion begins, but the sound does not demand attention.
    "task_start": Cue(
        0.50,
        (Strike("C4", 0.000, -1.0, length=0.42), Strike("G4", 0.120, -3.5, length=0.38)),
        target_peak_dbfs=-7.0,
    ),
    # Two marimba steps hand the cadence to a soft C5 vibraphone landing. The
    # longer third stage separates completion from the two-hit start.
    "stop": Cue(
        0.98,
        (
            Strike("C4", 0.000, 3.0, length=0.46),
            Strike("G4", 0.165, -1.0, length=0.42),
            Strike("VibeC5", 0.360, -6.0, length=0.62, fade_in=0.014),
        ),
        target_lufs=-16.0,
    ),
    # A real slit drum changes both material and envelope. High then low is easy
    # to learn as failure without turning into an alarm or harsh error buzzer.
    "stop_failure": Cue(
        0.68,
        (
            Strike("LogHi", 0.000, -2.0, length=0.38, fade_in=0.012),
            Strike("LogLo", 0.250, 0.0, length=0.43, fade_in=0.014),
        ),
        target_lufs=-16.5,
        lowpass_hz=4_200,
    ),
    # A softened hand-chime doublet provides a non-melodic attention cue whose
    # material and wide spacing cannot be mistaken for the marimba start.
    "notification": Cue(
        0.70,
        (
            Strike("ChimeE4", 0.000, -2.0, length=0.42, fade_in=0.018),
            Strike("ChimeE4", 0.280, -3.5, length=0.42, fade_in=0.018),
        ),
        target_lufs=-17.0,
        lowpass_hz=5_200,
    ),
    # A single low answer is intentionally subordinate to the main completion.
    "subagent_stop": Cue(
        0.46,
        (Strike("F3", 0.000, 0.0, length=0.46, fade_in=0.012),),
        target_lufs=-17.0,
        lowpass_hz=4_800,
    ),
}


def run(command: list[str], *, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_sources(cache: Path) -> dict[str, Path]:
    cache.mkdir(parents=True, exist_ok=True)
    fetched: dict[str, Path] = {}
    for note, source in SOURCES.items():
        destination = cache / f"{note}.wav"
        if not destination.exists() or sha256(destination) != source.sha256:
            url = f"{RAW_ROOT}/{urllib.parse.quote(source.path)}"
            request = urllib.request.Request(url, headers={"User-Agent": "Claudio-sound-pack-builder/1"})
            with urllib.request.urlopen(request) as response, destination.open("wb") as output:
                shutil.copyfileobj(response, output)
        actual = sha256(destination)
        if actual != source.sha256:
            raise RuntimeError(f"source hash mismatch for {note}: expected {source.sha256}, got {actual}")
        fetched[note] = destination
    return fetched


def render_intermediate(cue: Cue, sources: dict[str, Path], destination: Path) -> None:
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    filters: list[str] = []
    mix_inputs: list[str] = []

    for index, strike in enumerate(cue.strikes):
        source = SOURCES[strike.source]
        length = strike.length or source.active_seconds
        command.extend(["-i", str(sources[strike.source])])
        pitch = ""
        if strike.semitones:
            ratio = 2.0 ** (strike.semitones / 12.0)
            pitch = f",asetrate={SAMPLE_RATE * ratio:.8f},aresample={SAMPLE_RATE}"
        fade_seconds = min(0.18, max(0.08, length * 0.32))
        fade_start = max(0.0, length - fade_seconds)
        delay_ms = round(strike.start * 1000)
        filters.append(
            f"[{index}:a]aresample={SAMPLE_RATE},"
            "pan=mono|c0=0.5*c0+0.5*c1"
            f"{pitch},highpass=f=70,lowpass=f={cue.lowpass_hz},"
            f"atrim=duration={length:.6f},asetpts=PTS-STARTPTS,"
            f"afade=t=in:st=0:d={strike.fade_in:.6f},"
            f"afade=t=out:st={fade_start:.6f}:d={fade_seconds:.6f},"
            f"volume={strike.gain_db:.3f}dB,adelay={delay_ms}:all=1,"
            f"apad=whole_dur={cue.audible_seconds:.6f},"
            f"atrim=duration={cue.audible_seconds:.6f}[s{index}]"
        )
        mix_inputs.append(f"[s{index}]")

    final_fade = min(0.22, cue.audible_seconds * 0.24)
    final_fade_start = cue.audible_seconds - final_fade
    filters.append(
        "".join(mix_inputs)
        + f"amix=inputs={len(mix_inputs)}:normalize=0:duration=longest:dropout_transition=0,"
        + f"atrim=duration={cue.audible_seconds:.6f},"
        + "afade=t=in:st=0:d=0.008,"
        + f"afade=t=out:st={final_fade_start:.6f}:d={final_fade:.6f},"
        + f"apad=pad_dur={TERMINAL_SILENCE:.6f},"
        + f"atrim=duration={cue.audible_seconds + TERMINAL_SILENCE:.6f},"
        + "asetpts=N/SR/TB[out]"
    )
    command.extend(
        [
            "-filter_complex",
            ";".join(filters),
            "-map",
            "[out]",
            "-ar",
            str(SAMPLE_RATE),
            "-ac",
            "1",
            "-c:a",
            "pcm_f32le",
            str(destination),
        ]
    )
    run(command)


def measured_peak_dbfs(path: Path) -> float:
    result = run(
        [
            "ffmpeg",
            "-hide_banner",
            "-i",
            str(path),
            "-af",
            "volumedetect",
            "-f",
            "null",
            "-",
        ],
        capture=True,
    )
    match = re.search(r"max_volume:\s*(-?(?:inf|\d+(?:\.\d+)?)) dB", result.stderr, re.IGNORECASE)
    if not match or match.group(1).lower() == "-inf":
        raise RuntimeError(f"could not measure a non-silent peak for {path}")
    return float(match.group(1))


def measured_integrated_lufs(path: Path) -> float:
    result = run(
        [
            "ffmpeg",
            "-hide_banner",
            "-nostats",
            "-i",
            str(path),
            "-filter_complex",
            "ebur128=peak=true",
            "-f",
            "null",
            "-",
        ],
        capture=True,
    )
    matches = re.findall(r"I:\s*(-?(?:inf|\d+(?:\.\d+)?))\s+LUFS", result.stderr, re.IGNORECASE)
    if not matches or matches[-1].lower() == "-inf":
        raise RuntimeError(f"could not measure integrated loudness for {path}")
    return float(matches[-1])


def normalize_and_write(source: Path, destination: Path, cue: Cue) -> None:
    if cue.target_lufs is not None:
        gain_db = cue.target_lufs - measured_integrated_lufs(source)
    elif cue.target_peak_dbfs is not None:
        gain_db = cue.target_peak_dbfs - measured_peak_dbfs(source)
    else:
        raise RuntimeError(f"cue has no normalization target: {destination.stem}")
    run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(source),
            "-af",
            f"volume={gain_db:.4f}dB",
            "-ar",
            str(SAMPLE_RATE),
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(destination),
        ]
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--cache-directory", type=Path)
    args = parser.parse_args()

    if shutil.which("ffmpeg") is None:
        parser.error("ffmpeg is required")

    args.output_directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="claudio-soft-mallet-") as temporary:
        temporary_path = Path(temporary)
        cache = args.cache_directory or temporary_path / "sources"
        sources = fetch_sources(cache)
        for event, cue in CUES.items():
            intermediate = temporary_path / f"{event}-float.wav"
            render_intermediate(cue, sources, intermediate)
            normalize_and_write(intermediate, args.output_directory / f"{event}.wav", cue)

    print(f"rendered soft-mallet: {len(CUES)} real-recording cues")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
