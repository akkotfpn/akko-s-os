#!/usr/bin/env python3
"""
gerar_sons.py — identidade sonora do Akko's OS, sintetizada do zero.

Nenhum arquivo de áudio externo: cada som é calculado com síntese aditiva
(somas de parciais senoidais), síntese FM (portadora modulada por outra
senoide) e um reverb de Schroeder (filtros comb + all-pass) escrito à mão.

Gera, em WAV 48 kHz / 24 bits / estéreo:
  boot_chime.wav    acorde espacial que se abre (Cmaj9 → Fmaj9/C)
  shutdown.wav      progressão descendente suave
  notify.wav        sino FM de duas notas
  error.wav         tom grave com leve dissonância
  click.wav         clique curto e seco
  window_open.wav   brilho ascendente rápido

Uso: python3 gerar_sons.py <pasta-de-saída>
Requer só numpy (e a biblioteca padrão).
"""

import os
import sys
import wave

import numpy as np

SR = 48000          # taxa de amostragem
BITS = 24
RNG = np.random.default_rng(1928)   # semente fixa: o build é reproduzível


# ----------------------------------------------------------------- básicos

def t_axis(seconds):
    return np.arange(int(SR * seconds)) / SR


def note(name):
    """'A4' → 440 Hz; aceita sustenido: 'C#5'."""
    names = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3,
             "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}
    pitch, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((names[pitch] + 12 * (octave - 4)) / 12)


def adsr(n, attack, decay, sustain, release):
    """Envelope ADSR com curvas exponenciais suaves (tempos em segundos)."""
    a, d, r = int(attack * SR), int(decay * SR), int(release * SR)
    s = max(n - a - d - r, 0)
    env = np.concatenate([
        1 - np.exp(-5 * np.linspace(0, 1, a, endpoint=False)) if a else np.array([]),
        sustain + (1 - sustain) * np.exp(-4 * np.linspace(0, 1, d, endpoint=False)) if d else np.array([]),
        np.full(s, sustain),
        sustain * np.exp(-5 * np.linspace(0, 1, r)) if r else np.array([]),
    ])
    env = env[:n]
    if len(env) < n:
        env = np.pad(env, (0, n - len(env)))
    if a:   # normaliza o pico do ataque em 1
        env[:a] /= max(env[:a].max(), 1e-9)
    return env


def additive(freq, seconds, partials, detune_cents=0.0, phase_seed=True):
    """Soma de parciais: partials = [(multiplicador, amplitude, decaimento/s)]."""
    t = t_axis(seconds)
    out = np.zeros_like(t)
    for mult, amp, damp in partials:
        f = freq * mult * 2 ** (RNG.uniform(-detune_cents, detune_cents) / 1200)
        phase = RNG.uniform(0, 2 * np.pi) if phase_seed else 0.0
        out += amp * np.sin(2 * np.pi * f * t + phase) * np.exp(-damp * t)
    return out


def fm(carrier, ratio, index, seconds, index_decay=3.0):
    """Síntese FM: o índice cai com o tempo, como num sino (DX7-like)."""
    t = t_axis(seconds)
    mod_freq = carrier * ratio
    idx = index * np.exp(-index_decay * t)
    return np.sin(2 * np.pi * carrier * t + idx * np.sin(2 * np.pi * mod_freq * t))


def one_pole_lowpass(x, cutoff):
    """Passa-baixas de 1 polo (vetorizado por recursão via lfilter manual)."""
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    # laço simples: só usado em sinais curtos (clique)
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def pan(mono, position):
    """Pan de potência constante: position -1 (esq) … +1 (dir)."""
    angle = (position + 1) * np.pi / 4
    return np.stack([mono * np.cos(angle), mono * np.sin(angle)], axis=1)


# ----------------------------------------------------------------- reverb

def _comb(x, delay, feedback, damp):
    """Comb com realimentação amortecida, processado em blocos de 'delay'
    amostras (a recursão só depende de y[n - delay], então cada bloco é
    calculado de uma vez a partir do bloco anterior)."""
    n = len(x)
    y = np.zeros(n + delay)
    prev = np.zeros(delay)
    lp = 0.0
    for start in range(0, n, delay):
        block = x[start:start + delay]
        fb = prev[:len(block)]
        # amortecimento: média móvel leve na realimentação (agudos caem antes)
        fb_damped = (1 - damp) * fb + damp * np.concatenate([[lp], fb[:-1]])
        lp = fb[-1] if len(fb) else lp
        out = block + feedback * fb_damped
        y[start:start + len(block)] = out
        prev = np.pad(out, (0, delay - len(out)))
    return y[:n]


def _allpass(x, delay, g):
    n = len(x)
    y = np.zeros(n)
    xd = np.concatenate([np.zeros(delay), x])[:n]   # x[n-D]
    prev = np.zeros(delay)                          # y[n-D] por bloco
    for start in range(0, n, delay):
        end = min(start + delay, n)
        blk = -g * x[start:end] + xd[start:end] + g * prev[:end - start]
        y[start:end] = blk
        prev = np.pad(blk, (0, delay - len(blk)))
    return y


def schroeder_reverb(stereo, wet=0.3, size=1.0):
    """Reverb de Schroeder/Freeverb simplificado, com espalhamento estéreo."""
    combs = [1557, 1617, 1491, 1422, 1277, 1356]
    allpasses = [225, 556, 441]
    out = np.zeros_like(stereo)
    for ch, spread in ((0, 0), (1, 23)):
        x = stereo[:, ch]
        acc = np.zeros_like(x)
        for d in combs:
            acc += _comb(x, int((d + spread) * size), 0.84, 0.2)
        acc /= len(combs)
        for d in allpasses:
            acc = _allpass(acc, d + spread, 0.5)
        out[:, ch] = acc
    return (1 - wet) * stereo + wet * out


# --------------------------------------------------------------- utilidades

def mix_into(buffer, sig, at_seconds):
    start = int(at_seconds * SR)
    end = min(start + len(sig), len(buffer))
    buffer[start:end] += sig[:end - start]


def finalize(stereo, peak_db=-1.0, fade_out=0.05):
    """Fade-out final, remove DC, normaliza o pico em peak_db dBFS."""
    stereo = stereo - stereo.mean(axis=0)
    f = int(fade_out * SR)
    if f:
        stereo[-f:] *= np.linspace(1, 0, f)[:, None]
    peak = np.abs(stereo).max()
    if peak > 0:
        stereo *= 10 ** (peak_db / 20) / peak
    return stereo


def write_wav(path, stereo):
    """WAV PCM 24 bits com dither triangular (TPDF)."""
    scale = 2 ** (BITS - 1) - 1
    dither = (RNG.random(stereo.shape) - RNG.random(stereo.shape)) / scale
    ints = np.clip(np.round((stereo + dither) * scale), -scale - 1, scale).astype(np.int32)
    raw = ints.reshape(-1)
    as_bytes = np.stack([(raw >> s) & 0xFF for s in (0, 8, 16)], axis=1).astype(np.uint8)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(BITS // 8)
        w.setframerate(SR)
        w.writeframes(as_bytes.tobytes())


# ------------------------------------------------------------------- sons

PAD = [(1, 1.0, 0.25), (2, 0.35, 0.5), (3, 0.12, 0.9), (4, 0.06, 1.3), (6, 0.02, 2.0)]


def boot_chime():
    """Cmaj9 que se abre nota a nota (graves → agudos), espalhado no estéreo,
    seguido de Fmaj9/C que 'respira' por cima. Brilho FM no topo."""
    total = 5.2
    buf = np.zeros((int(SR * total), 2))
    voicing = [("C3", -0.1), ("G3", 0.2), ("E4", -0.45), ("B4", 0.5), ("D5", -0.7), ("G5", 0.75)]
    for i, (n, p) in enumerate(voicing):
        dur = total - i * 0.12
        tone = additive(note(n), dur, PAD, detune_cents=6)
        tone *= adsr(len(tone), 0.9 + 0.1 * i, 1.2, 0.55, 1.8)
        mix_into(buf, pan(tone * 0.18, p), i * 0.12)
    # segundo acorde (Fmaj9 sobre C): só as notas que mudam
    for i, (n, p) in enumerate([("A4", 0.3), ("C5", -0.3), ("F5", 0.6), ("A5", -0.6)]):
        tone = additive(note(n), 2.9, PAD, detune_cents=5)
        tone *= adsr(len(tone), 0.7, 0.6, 0.5, 1.5)
        mix_into(buf, pan(tone * 0.11, p), 1.9 + i * 0.08)
    # brilho: dois sinos FM agudos, um de cada lado
    for at, n, p in ((0.6, "E6", -0.5), (1.15, "B6", 0.5)):
        bell = fm(note(n), 3.5, 2.2, 2.4, 2.8) * adsr(int(2.4 * SR), 0.004, 0.5, 0.15, 1.6)
        mix_into(buf, pan(bell * 0.06, p), at)
    return finalize(schroeder_reverb(buf, wet=0.42, size=1.15), peak_db=-1.5, fade_out=0.6)


def shutdown():
    """Progressão descendente e calma: Fmaj7 → Dm9 → Bbmaj7 → F(add9) grave."""
    chords = [
        (["F4", "A4", "C5", "E5"], 0.00),
        (["D4", "F4", "A4", "E5"], 0.55),
        (["A#3", "D4", "F4", "A4"], 1.10),
        (["F3", "C4", "G4", "A4"], 1.65),
    ]
    total = 3.6
    buf = np.zeros((int(SR * total), 2))
    for ci, (notes, at) in enumerate(chords):
        dur = 1.0 if ci < 3 else total - at
        for k, n in enumerate(notes):
            tone = additive(note(n), dur, PAD, detune_cents=4)
            rel = 0.6 if ci < 3 else 1.4
            tone *= adsr(len(tone), 0.08, 0.3, 0.6, rel)
            mix_into(buf, pan(tone * 0.13, (k - 1.5) / 2.5), at)
    return finalize(schroeder_reverb(buf, wet=0.38, size=1.05), peak_db=-2.0, fade_out=0.5)


def notify():
    """Sino FM de duas notas ascendentes (E6 → B6)."""
    total = 0.9
    buf = np.zeros((int(SR * total), 2))
    for at, n, p in ((0.0, "E6", -0.15), (0.11, "B6", 0.15)):
        dur = total - at
        bell = fm(note(n), 2.0, 1.6, dur, 6.0) * adsr(int(dur * SR), 0.003, 0.25, 0.0, 0.0)
        bell *= np.exp(-5.5 * t_axis(dur))
        mix_into(buf, pan(bell * 0.5, p), at)
    return finalize(schroeder_reverb(buf, wet=0.18, size=0.5), peak_db=-3.0, fade_out=0.15)


def error():
    """Duas batidas graves descendentes com leve batimento (dissonância)."""
    total = 0.62
    buf = np.zeros((int(SR * total), 2))
    for at, f in ((0.0, note("A3")), (0.17, note("F3"))):
        dur = 0.38
        tone = fm(f, 1.0, 1.4, dur, 9.0) + 0.6 * fm(f * 1.012, 1.0, 1.0, dur, 9.0)
        tone *= adsr(len(tone), 0.004, 0.12, 0.25, 0.18)
        mix_into(buf, pan(tone * 0.4, 0.0), at)
    return finalize(buf, peak_db=-3.0, fade_out=0.04)


def click():
    """Transiente curto: ruído filtrado + senoide aguda, ~35 ms."""
    dur = 0.035
    n = int(dur * SR)
    noise = one_pole_lowpass(RNG.standard_normal(n), 3500)
    tick = np.sin(2 * np.pi * 2400 * t_axis(dur))
    sig = (0.6 * noise + 0.5 * tick) * np.exp(-140 * t_axis(dur))
    return finalize(pan(sig, 0.0), peak_db=-6.0, fade_out=0.005)


def window_open():
    """Brilho ascendente: varredura de 900 → 2200 Hz com parcial uma oitava acima."""
    dur = 0.24
    t = t_axis(dur)
    f = 900 + (2200 - 900) * (t / dur) ** 0.7
    phase = 2 * np.pi * np.cumsum(f) / SR
    sig = 0.7 * np.sin(phase) + 0.25 * np.sin(2 * phase)
    sig *= adsr(len(sig), 0.012, 0.05, 0.5, 0.15)
    stereo = np.stack([sig * (1 - t / dur * 0.5), sig * (0.5 + t / dur * 0.5)], axis=1)
    return finalize(schroeder_reverb(stereo, wet=0.15, size=0.4), peak_db=-8.0, fade_out=0.03)


SOUNDS = {
    "boot_chime": boot_chime,
    "shutdown": shutdown,
    "notify": notify,
    "error": error,
    "click": click,
    "window_open": window_open,
}


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, fn in SOUNDS.items():
        audio = fn()
        assert np.isfinite(audio).all(), f"{name}: amostras inválidas"
        path = os.path.join(out, f"{name}.wav")
        write_wav(path, audio)
        print(f"{name:12} {len(audio) / SR:5.2f} s  pico {20 * np.log10(np.abs(audio).max()):6.1f} dBFS  -> {path}")


if __name__ == "__main__":
    main()
