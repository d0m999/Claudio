#!/usr/bin/env python3
"""Render a CC0 Claude cue-pack candidate from a deterministic soft synth.

The pack borrows a product decision, not a proprietary sound: one coherent synth
voice, a shared event grammar, and conservative tails for frequent cues.
No recordings, samples, network calls, or third-party libraries are used.
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
class Style:
    harmonics: tuple[tuple[int, float], ...]
    detune_cents: float
    body_ratio: float
    body_gain: float
    attack: float
    release: float
    decay: float
    sparkle_gain: float


@dataclass(frozen=True)
class Note:
    start: float
    duration: float
    midi: float
    amplitude: float
    glide_cents: float = 0.0


@dataclass(frozen=True)
class Event:
    duration: float
    notes: tuple[Note, ...]
    peak_db: float


STYLES = {
    # A lower, muted voice for people who keep the app running all day. The
    # low body and slower envelope make it feel present without shouting.
    "night-console": Style(
        harmonics=((1, 1.0), (2, 0.065), (3, 0.065), (5, 0.010)),
        detune_cents=-1.0,
        body_ratio=0.5,
        body_gain=0.075,
        attack=0.030,
        release=0.120,
        decay=0.180,
        sparkle_gain=0.003,
    ),
}


PACK_EVENTS = {
    "night-console": {
        "task_start": Event(0.280, (Note(0.000, 0.100, 55.0, 0.61, 7.0), Note(0.115, 0.165, 59.0, 0.65, 4.0)), -7.2),
        "stop": Event(0.720, (Note(0.000, 0.150, 55.0, 0.56, 4.0), Note(0.160, 0.190, 59.0, 0.59, 2.0), Note(0.385, 0.310, 62.0, 0.66, 1.0)), -0.8),
        "stop_failure": Event(0.700, (Note(0.000, 0.150, 62.0, 0.52, -3.0), Note(0.160, 0.190, 58.0, 0.50, -5.0), Note(0.375, 0.300, 55.0, 0.48, -8.0)), -0.8),
        "notification": Event(0.690, (Note(0.000, 0.115, 59.0, 0.56, 5.0), Note(0.330, 0.115, 59.0, 0.49, 5.0)), -0.8),
        "subagent_stop": Event(0.205, (Note(0.000, 0.160, 50.0, 0.45, 3.0),), -0.8),
    },
}


def midi_to_hz(midi: float) -> float:
    return 440.0 * (2.0 ** ((midi - 69.0) / 12.0))


def smoothstep(value: float) -> float:
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def envelope(time: float, duration: float, style: Style) -> float:
    attack = min(style.attack, duration * 0.30)
    release = min(style.release, duration * 0.42)
    if time < attack:
        return math.sin((time / attack) * math.pi / 2.0) ** 2
    if time > duration - release:
        return 1.0 - smoothstep((time - (duration - release)) / release)
    return 0.90 + 0.10 * math.exp(-(time - attack) / style.decay)


def add_note(samples: list[float], note: Note, style: Style) -> None:
    start_index = max(0, int(round(note.start * SAMPLE_RATE)))
    note_length = max(1, int(round(note.duration * SAMPLE_RATE)))
    base_frequency = midi_to_hz(note.midi)
    phase = 0.0
    detuned_phase = 0.0
    body_phase = 0.0

    for offset in range(note_length):
        index = start_index + offset
        if index >= len(samples):
            break
        time = offset / SAMPLE_RATE
        cents = note.glide_cents * math.exp(-time / 0.050)
        frequency = base_frequency * (2.0 ** (cents / 1200.0))
        phase += TAU * frequency / SAMPLE_RATE
        detuned_frequency = frequency * (2.0 ** (style.detune_cents / 1200.0))
        detuned_phase += TAU * detuned_frequency / SAMPLE_RATE
        body_phase += TAU * (frequency * style.body_ratio) / SAMPLE_RATE

        voice = sum(weight * math.sin(phase * harmonic) for harmonic, weight in style.harmonics)
        voice += 0.025 * math.sin(detuned_phase)
        body = style.body_gain * math.sin(body_phase) * math.exp(-time / 0.16)
        sparkle = style.sparkle_gain * math.sin(phase * 2.0) * math.exp(-time / 0.028)
        samples[index] += note.amplitude * envelope(time, note.duration, style) * (voice + body + sparkle)


def render_event(event: Event, style: Style) -> list[float]:
    sample_count = int(round(event.duration * SAMPLE_RATE))
    samples = [0.0] * sample_count
    for note in event.notes:
        add_note(samples, note, style)

    fade_in = max(1, int(round(0.008 * SAMPLE_RATE)))
    fade_out = max(1, int(round(0.030 * SAMPLE_RATE)))
    for index in range(min(fade_in, sample_count)):
        samples[index] *= smoothstep(index / fade_in)
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

    output_root = Path(sys.argv[1])
    for pack_id, events in PACK_EVENTS.items():
        style = STYLES[pack_id]
        for event_id, event in events.items():
            write_pcm16(output_root / pack_id / f"{event_id}.wav", render_event(event, style))
    print(f"rendered {len(PACK_EVENTS)} packs / {sum(len(events) for events in PACK_EVENTS.values())} events")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
