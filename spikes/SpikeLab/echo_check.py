#!/usr/bin/env python3
"""EM-015 / EM-016 — check alignment & echo between a dual-track capture (…-mic.wav, …-system.wav).

Usage: echo_check.py <capture-…-mic.wav> [<capture-…-system.wav>]   (numpy only)
Reports: durations (alignment), echo delay (mic vs system cross-correlation),
leakage level (how loud the remote side appears in the mic track), and a verdict.
"""
import struct, sys
import numpy as np

def read_wav(path):
    with open(path, "rb") as f: b = f.read()
    assert b[:4] == b"RIFF" and b[8:12] == b"WAVE", "not a WAV"
    i, fmt, data = 12, None, None
    while i + 8 <= len(b):
        cid, size = b[i:i+4], struct.unpack("<I", b[i+4:i+8])[0]
        body = b[i+8:i+8+size]
        if cid == b"fmt ":
            tag, ch, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == 0xFFFE: tag = struct.unpack("<H", body[24:26])[0]
            fmt = (tag, ch, rate, bits)
        elif cid == b"data": data = body
        i += 8 + size + (size & 1)
    tag, ch, rate, bits = fmt
    if tag == 3 and bits == 32: x = np.frombuffer(data, "<f4")
    elif tag == 1 and bits == 16: x = np.frombuffer(data, "<i2") / 32768.0
    else: raise SystemExit(f"unsupported WAV format {fmt}")
    return x.reshape(-1, ch).mean(axis=1).astype(np.float64), rate

def db(x): return 20 * np.log10(max(x, 1e-9))

def main():
    mic_p = sys.argv[1]
    sys_p = sys.argv[2] if len(sys.argv) > 2 else mic_p.replace("-mic.wav", "-system.wav")
    mic, r1 = read_wav(mic_p); sysa, r2 = read_wav(sys_p)
    assert r1 == r2, f"rate mismatch {r1} vs {r2}"
    rate = r1
    print(f"mic    {len(mic)/rate:7.2f} s  rms {db(np.sqrt(np.mean(mic**2))):6.1f} dBFS  peak {db(np.abs(mic).max()):6.1f}")
    print(f"system {len(sysa)/rate:7.2f} s  rms {db(np.sqrt(np.mean(sysa**2))):6.1f} dBFS  peak {db(np.abs(sysa).max()):6.1f}")
    print(f"length difference: {abs(len(mic)-len(sysa))/rate*1000:.1f} ms  ({'aligned' if abs(len(mic)-len(sysa)) < rate*0.05 else 'NOT aligned'})")
    n = min(len(mic), len(sysa)); m, s = mic[:n], sysa[:n]

    # Downsample to 8 kHz for a fast, robust correlation
    k = rate // 8000; m8 = m[: len(m)//k*k].reshape(-1, k).mean(1); s8 = s[: len(s)//k*k].reshape(-1, k).mean(1)
    N = 1 << int(np.ceil(np.log2(len(m8) + len(s8))))
    xc = np.fft.irfft(np.fft.rfft(m8, N) * np.conj(np.fft.rfft(s8, N)), N)
    maxlag = int(0.6 * 8000)                       # search mic lagging system by 0…600 ms
    seg = xc[:maxlag]
    lag = int(np.argmax(seg))
    norm = np.sqrt(np.sum(m8**2) * np.sum(s8**2)) + 1e-12
    corr = seg[lag] / norm
    # Leakage gain at that lag (least squares)
    sd = np.roll(s8, lag); sd[:lag] = 0
    g = float(np.dot(m8, sd) / (np.dot(sd, sd) + 1e-12))
    active = np.mean(np.abs(s8) > 10 ** (-40 / 20))
    print(f"system active (> -40 dBFS): {active*100:.0f}% of samples")
    print(f"echo: delay {lag/8:.1f} ms, normalised correlation {corr:.3f}, leakage gain {db(abs(g)):.1f} dB")
    if active < 0.05:
        print("VERDICT: not enough remote/system audio to judge echo")
    elif corr > 0.3:
        print(f"VERDICT: ECHO PRESENT — remote audio leaks into the mic ~{lag/8:.0f} ms later (speakers). De-dup/AEC needed.")
    elif corr > 0.1:
        print("VERDICT: weak leakage — likely low-volume speakers or partial pickup")
    else:
        print("VERDICT: no meaningful echo (headphones or very low speaker volume)")

if __name__ == "__main__":
    main()
