#!/usr/bin/env python3
"""Render the CC0 resonant-bowl reference pack from deterministic synthesis.

The pack is inspired by the rounded bloom and long decay of a softly struck
singing bowl, without using a recording or copying a particular performance.
It uses only mathematical oscillators, inharmonic partials, a restrained strike
transient, and a short room return.  The event grammar comes from timing,
register, repetition, and damping rather than from unrelated sound effects.
"""

from __future__ import annotations

import math
import struct
import sys
import wave
from dataclasses import dataclass
from pathlib import Path


SAMPLE_RATE = 44_100
TAU = math.tau


@dataclass(frozen=True)
class Tone:
    start: float
    duration: float
    midi: float
    amplitude: float
    decay: float
    damping: float = 1.0
    strike_gain: float = 0.10
    bloom_cents: float = 7.0
    seed: int = 1
    fade_out: float = 0.040


@dataclass(frozen=True)
class Event:
    duration: float
    tones: tuple[Tone, ...]
    peak_db: float
    natural_release: float = 0.0
    terminal_silence: float = 0.0


# Singing bowls do not sound like an ideal harmonic oscillator.  These gentle
# inharmonic ratios keep the body rounded while giving the ear enough material
# information to distinguish it from a plain sine or a digital chime.
PARTIALS = (
    (0.50, 0.045, 0.86),
    (1.00, 0.92, 1.00),
    (1.004, 0.28, 0.88),
    (2.01, 0.23, 0.70),
    (2.71, 0.12, 0.52),
    (3.94, 0.060, 0.36),
    (5.35, 0.022, 0.20),
)


EVENTS = {
    # The calm long-tail profile keeps the first 320ms clear as the event onset,
    # then gives the bowl body a continuous natural release. The final 60ms is
    # an explicit digital-silence guard so the encoded file cannot end with a
    # residual tail or a boundary click. This is the curated exception
    # documented in docs/pack-standard.md.
    "task_start": Event(
        1.150,
        (
            # This primary tone is faded only once at event level. A second
            # per-tone fade made the earlier short version feel clipped.
            Tone(0.000, 1.150, 60.0, 0.72, 0.68, strike_gain=0.045, bloom_cents=9.0, seed=11, fade_out=0.0),
            Tone(0.220, 0.620, 67.0, 0.24, 0.42, damping=1.12, strike_gain=0.025, bloom_cents=5.0, seed=17),
        ),
        -6.5,
        natural_release=0.260,
        terminal_silence=0.060,
    ),
    # A full, single ring is the calmest and longest event in the set.
    "stop": Event(
        1.840,
        (Tone(0.000, 1.800, 62.0, 0.86, 0.92, strike_gain=0.095, seed=21),),
        -2.5,
    ),
    # A damped descending three-touch phrase makes interruption recognizable
    # without resorting to a harsh alarm or a dissonant buzzer.
    "stop_failure": Event(
        1.420,
        (
            Tone(0.000, 0.430, 69.0, 0.53, 0.34, damping=1.25, strike_gain=0.055, bloom_cents=3.0, seed=31),
            Tone(0.190, 0.650, 65.0, 0.47, 0.44, damping=1.30, strike_gain=0.050, bloom_cents=1.0, seed=37),
            Tone(0.390, 1.000, 62.0, 0.48, 0.60, damping=1.18, strike_gain=0.045, bloom_cents=-3.0, seed=41),
        ),
        -3.5,
    ),
    # Two separated touches are easy to recognize as a notification and leave
    # enough space for each resonance to be heard as its own event.
    "notification": Event(
        1.380,
        (
            Tone(0.000, 0.570, 67.0, 0.62, 0.42, damping=1.10, strike_gain=0.070, seed=51),
            Tone(0.390, 0.940, 67.0, 0.53, 0.54, damping=1.05, strike_gain=0.060, seed=59),
        ),
        -4.0,
    ),
    # A small, low acknowledgement remains shorter than completion, but has a
    # real body and tail instead of behaving like a dry click.
    "subagent_stop": Event(
        0.740,
        (Tone(0.000, 0.700, 55.0, 0.60, 0.42, damping=1.10, strike_gain=0.065, seed=71),),
        -5.5,
    ),
}


def midi_to_hz(midi: float) -> float:
    return 440.0 * (2.0 ** ((midi - 69.0) / 12.0))


def smoothstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def next_noise(state: int) -> tuple[int, float]:
    state = (1664525 * state + 1013904223) & 0xFFFFFFFF
    return state, (state / 2147483647.5) - 1.0


def add_tone(samples: list[float], tone: Tone) -> None:
    start_index = max(0, int(round(tone.start * SAMPLE_RATE)))
    tone_length = max(1, int(round(tone.duration * SAMPLE_RATE)))
    base_frequency = midi_to_hz(tone.midi)
    phases = [0.0] * len(PARTIALS)
    noise_state = tone.seed
    smoothed_noise = 0.0

    for offset in range(tone_length):
        index = start_index + offset
        if index >= len(samples):
            break
        time = offset / SAMPLE_RATE

        # The first few milliseconds bloom slightly high and settle down. This
        # gives the sound a struck, physical onset rather than a static synth.
        cents = tone.bloom_cents * math.exp(-time / 0.065)
        frequency = base_frequency * (2.0 ** (cents / 1200.0))
        body = 0.0
        for partial_index, (ratio, weight, decay_ratio) in enumerate(PARTIALS):
            partial_frequency = frequency * ratio
            phases[partial_index] += TAU * partial_frequency / SAMPLE_RATE
            partial_decay = max(0.035, tone.decay * decay_ratio / tone.damping)
            body += weight * math.sin(phases[partial_index]) * math.exp(-time / partial_decay)

        attack = 1.0 - math.exp(-time / 0.011)
        strike_envelope = (1.0 - math.exp(-time / 0.0012)) * math.exp(-time / 0.017)
        noise_state, raw_noise = next_noise(noise_state)
        # One-pole smoothing makes the synthetic mallet contact soft enough for
        # laptop speakers and avoids a click at the file boundary.
        smoothed_noise += 0.16 * (raw_noise - smoothed_noise)
        strike = tone.strike_gain * strike_envelope * (
            0.72 * smoothed_noise + 0.28 * math.sin(phases[3])
        )
        samples[index] += tone.amplitude * (attack * body + strike)

    if tone.fade_out > 0.0:
        fade_length = max(1, int(round(tone.fade_out * SAMPLE_RATE)))
        fade_start = max(start_index, start_index + tone_length - fade_length)
        for index in range(fade_start, min(start_index + tone_length, len(samples))):
            samples[index] *= 1.0 - smoothstep((index - fade_start) / fade_length)


def render_event(event: Event) -> list[float]:
    sample_count = int(round(event.duration * SAMPLE_RATE))
    samples = [0.0] * sample_count
    for tone in event.tones:
        add_tone(samples, tone)

    # A quiet, short room return keeps the tone from feeling pasted onto the
    # timeline while preserving the clarity of the event rhythm.
    dry = samples[:]
    for delay_seconds, gain in ((0.021, 0.032), (0.043, 0.018), (0.081, 0.009)):
        delay = int(round(delay_seconds * SAMPLE_RATE))
        for index in range(delay, sample_count):
            samples[index] += dry[index - delay] * gain

    fade_in = max(1, int(round(0.008 * SAMPLE_RATE)))
    fade_out = max(1, int(round(0.030 * SAMPLE_RATE)))
    for index in range(min(fade_in, sample_count)):
        samples[index] *= smoothstep(index / fade_in)
    if event.natural_release > 0.0:
        terminal_silence = min(
            max(0, sample_count - fade_in - 1),
            int(round(event.terminal_silence * SAMPLE_RATE)),
        )
        release_end = max(fade_in + 1, sample_count - terminal_silence)
        release_length = max(1, int(round(event.natural_release * SAMPLE_RATE)))
        release_start = max(fade_in, release_end - release_length)
        release_span = max(1, release_end - release_start)
        for index in range(release_start, release_end):
            # Include the final release sample in the curve. Its gain is
            # exactly zero, so the following silence guard has no hard edge.
            progress = (index - release_start) / max(1, release_span - 1)
            samples[index] *= 1.0 - smoothstep(progress)
        for index in range(release_end, sample_count):
            samples[index] = 0.0
    else:
        fade_start = max(0, sample_count - fade_out)
        for index in range(fade_start, sample_count):
            samples[index] *= 1.0 - smoothstep((index - fade_start) / fade_out)

    peak = max(abs(sample) for sample in samples) or 1.0
    target_peak = 10.0 ** (event.peak_db / 20.0)
    scale = target_peak / peak
    return [max(-0.999, min(0.999, sample * scale)) for sample in samples]


def write_pcm16(path: Path, samples: list[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = b"".join(struct.pack("<h", int(round(sample * 32767.0))) for sample in samples)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(pcm)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} OUTPUT_DIRECTORY", file=sys.stderr)
        return 2

    output = Path(sys.argv[1])
    for event_id, event in EVENTS.items():
        write_pcm16(output / f"{event_id}.wav", render_event(event))
    print(f"rendered resonant-bowl / {len(EVENTS)} events")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
