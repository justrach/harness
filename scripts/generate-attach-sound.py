#!/usr/bin/env python3
"""Generate the attach cue: a file landing in the composer.

A soft low thump that drops in pitch as the file lands, then two quick rising
bell notes (E5, B5). Standard-library-only, deterministic stereo PCM, quiet
like the Appshot cue; no external samples.
"""
from pathlib import Path
import math
import struct
import wave

RATE = 48000
MASTER = .6
DURATION = .42
# Partials of a soft bell: (ratio, level, damping).
BELL = [(1, 1, 1), (2, .09, .5), (3, .02, .3)]
# Thump: onset, start Hz, end Hz, amplitude, length.
THUMP = (.004, 210.0, 120.0, .11, .070)
# Notes: onset, Hz, amplitude, decay.
NOTES = [(.048, 659.25, .034, .090), (.112, 987.77, .030, .140)]


def sample(t):
    start, f0, f1, amplitude, length = THUMP
    value = 0.0
    u = t - start
    if 0 <= u < length:
        # Pitch glides down exponentially; phase is the integral of frequency.
        k = math.log(f1 / f0) / length
        phase = 2 * math.pi * f0 * (math.exp(k * u) - 1) / k
        envelope = (1 - math.exp(-u / .003)) * math.exp(-u / (length * .35))
        value += amplitude * envelope * math.sin(phase)
    for onset, frequency, amplitude, decay in NOTES:
        u = t - onset
        if u < 0:
            continue
        for ratio, level, damping in BELL:
            envelope = (1 - math.exp(-u / .004)) * math.exp(-u / (decay * damping))
            value += amplitude * level * envelope * math.sin(2 * math.pi * frequency * ratio * u)
    return value


def render():
    count = round(DURATION * RATE)
    dry = [sample(i / RATE) for i in range(count)]
    frames = []
    for i, value in enumerate(dry):
        channels = []
        # A slightly different early reflection per side gives it width.
        for delay in [.019, .027]:
            k = i - round(delay * RATE)
            reflection = .05 * dry[k] if k >= 0 else 0
            fade = min(1, (count - i) / (.050 * RATE))
            channels.append((value + reflection) * MASTER * fade)
        frames.append(channels)
    peak = max(abs(v) for frame in frames for v in frame)
    assert peak < .13
    return frames, peak


def write(path, frames):
    with wave.open(str(path), 'wb') as f:
        f.setnchannels(2); f.setsampwidth(2); f.setframerate(RATE)
        f.writeframes(b''.join(struct.pack('<hh', *(round(v * 32767) for v in frame)) for frame in frames))


if __name__ == '__main__':
    frames, peak = render()
    output = Path(__file__).resolve().parents[1] / 'crates/ui/assets/sounds/attach.wav'
    write(output, frames)
    print(f'{output}: {len(frames) / RATE:.2f}s, stereo, peak {20 * math.log10(peak):.1f} dBFS')
