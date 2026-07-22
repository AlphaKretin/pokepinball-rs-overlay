"""Simulate common color-vision-deficiency transforms on the overlay's
color palette and report which pairs become hard to distinguish.

Not run automatically by anything -- a manual dev tool. Update the `colors`
dict below to match whatever's currently in overlay/Draw.lua (border/marker
constants) before running, and re-run whenever those colors change to
sanity-check the new choices.

Usage: python scripts/check_colorblind_palette.py
"""

import numpy as np

# Keep this in sync with overlay/Draw.lua's BORDER_COLOR_*/*_MARKER_COLOR
# constants.
colors = {
    "Uncaught (black)": 0x000000,
    "Caught (orange)": 0xFF9500,
    "Pending evo (magenta)": 0xFF2D95,
    "Line complete (green)": 0x34C759,
    "Blocked (purple)": 0xAF52DE,
    "Rare marker (gold)": 0xFFD700,
    "2-arrow marker (blue)": 0x2E9BFF,
    "3-arrow marker (red)": 0xFF3B30,
}


def hex_to_rgb(h):
    return np.array([(h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF], dtype=float) / 255.0


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * (c ** (1 / 2.4)) - 0.055)


# Machado, Oliveira & Fernandes 2009 matrices (severity 1.0), applied in
# linear RGB.
M = {
    "protanopia": np.array([
        [0.152286, 1.052583, -0.204868],
        [0.114503, 0.786281, 0.099216],
        [-0.003882, -0.048116, 1.051998]]),
    "deuteranopia": np.array([
        [0.367322, 0.860646, -0.227968],
        [0.280085, 0.672501, 0.047413],
        [-0.011820, 0.042940, 0.968881]]),
    "tritanopia": np.array([
        [1.255528, -0.076749, -0.178779],
        [-0.078411, 0.930809, 0.147602],
        [0.004733, 0.691367, 0.303900]]),
}


def simulate(hexval, kind):
    rgb = hex_to_rgb(hexval)
    lin = srgb_to_linear(rgb)
    sim_lin = M[kind] @ lin
    return linear_to_srgb(sim_lin)


def main():
    names = list(colors.keys())
    for kind in M:
        print(f"\n=== {kind} ===")
        sim = {n: simulate(colors[n], kind) * 255 for n in names}
        for n in names:
            r, g, b = sim[n]
            print(f"{n:28s} -> #{int(round(r)):02X}{int(round(g)):02X}{int(round(b)):02X}")
        print("-- closest pairs (Euclidean in simulated sRGB 0-255) --")
        dists = []
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                a, b = sim[names[i]], sim[names[j]]
                dists.append((np.linalg.norm(a - b), names[i], names[j]))
        dists.sort()
        for d, a, b in dists[:8]:
            print(f"{d:6.1f}  {a}  <->  {b}")


if __name__ == "__main__":
    main()
