"""A 1:1 crop from a RAW without decoding the whole frame.

The server's full decode (rawpy/LibRaw `postprocess`) reconstructs colour for all 42 MP of an ARW,
about 1-2.5 s, when a crop needs a few percent of it. This reads the sensor data (~0.26 s, mostly the
file), then does LibRaw's own steps on the crop's area only:

  black level and white balance (LibRaw `scale_colors`, highlight mode 0: multipliers over the
  smallest, clipped) -> demosaic (Malvar-He-Cutler, a sharp linear method, in place of LibRaw's AHD)
  -> camera to sRGB (`rgb_cam`, as `convert_to_rgb`) -> brightness and gamma (LibRaw's auto-bright:
  the top 1% of each channel clips, measured on a sample of the whole frame, then its BT.709 curve
  with rawpy's default gamma 2.222 / 4.5).

so the crop matches the full decode's look. The crop box is worked out exactly as `/m/api/crop`
does it, in the upright frame, and mapped onto the sensor through the file's orientation.
"""
from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import convolve

MARGIN = 8              # sensor pixels around the crop, so the demosaic has neighbours at the edges
SAMPLE_STEP = 16        # 2x2 sensor blocks sampled every this many pixels for the auto-bright estimate
GAMMA = (1 / 2.222, 4.5)


def crop_box(W: int, H: int, x: float, y: float, w: int, h: int) -> tuple[int, int, int, int]:
    """(left, top, w, h) in the upright frame: the same sums as `/m/api/crop`."""
    w, h = min(w, W), min(h, H)
    cx = min(max(x, 0.0), 1.0) * W
    cy = min(max(y, 0.0), 1.0) * H
    left = int(min(max(cx - w / 2, 0), W - w))
    top = int(min(max(cy - h / 2, 0), H - h))
    return left, top, w, h


def _gamma_curve(white: float) -> np.ndarray:
    """LibRaw's `gamma_curve(pwr, ts, mode=2, imax)`: 16-bit linear in, 8-bit out."""
    pwr, ts = GAMMA
    g = [pwr, ts, 0.0, 0.0, 0.0]
    bnd = [0.0, 0.0]
    bnd[1 if g[1] >= 1 else 0] = 1.0
    if g[1] and (g[1] - 1) * (g[0] - 1) <= 0:
        for _ in range(48):
            g[2] = (bnd[0] + bnd[1]) / 2
            bnd[1 if ((g[2] / g[1]) ** -g[0] - 1) / g[0] - 1 / g[2] > -1 else 0] = g[2]
        g[3] = g[2] / g[1]
        g[4] = g[2] * (1 / g[0] - 1)
    imax = max(white, 1.0)
    r = np.arange(0x10000, dtype=np.float64) / imax
    curve = np.where(r < g[3], r * g[1], np.power(np.maximum(r, 1e-12), g[0]) * (1 + g[4]) - g[4])
    curve = np.where(r < 1, curve * 0x10000, 0xffff)
    return (np.clip(curve, 0, 0xffff).astype(np.uint32) >> 8).astype(np.uint8)


_XYZ_RGB = np.array([[0.412453, 0.357580, 0.180423],
                     [0.212671, 0.715160, 0.072169],
                     [0.019334, 0.119193, 0.950227]])


def _rgb_cam(cam_xyz: np.ndarray) -> np.ndarray:
    """LibRaw's `cam_xyz_coeff`: camera RGB to sRGB, from the file's XYZ-to-camera matrix (rows
    normalised to sum to one, then inverted). rawpy's `color_matrix` is only filled in by a full
    `postprocess`, so it is worked out here the way LibRaw does."""
    cam_rgb = cam_xyz @ _XYZ_RGB
    cam_rgb = cam_rgb / cam_rgb.sum(axis=1, keepdims=True)
    return np.linalg.pinv(cam_rgb)


# Malvar-He-Cutler kernels (2004), divided by 8.
_K_G_AT_RB = np.array([[0, 0, -1, 0, 0], [0, 0, 2, 0, 0], [-1, 2, 4, 2, -1], [0, 0, 2, 0, 0], [0, 0, -1, 0, 0]], float) / 8
_K_ROW = np.array([[0, 0, .5, 0, 0], [0, -1, 0, -1, 0], [-1, 4, 5, 4, -1], [0, -1, 0, -1, 0], [0, 0, .5, 0, 0]], float) / 8
_K_COL = _K_ROW.T
_K_DIAG = np.array([[0, 0, -1.5, 0, 0], [0, 2, 0, 2, 0], [-1.5, 0, 6, 0, -1.5], [0, 2, 0, 2, 0], [0, 0, -1.5, 0, 0]], float) / 8


def _demosaic(cfa: np.ndarray, colors: np.ndarray) -> np.ndarray:
    """Malvar-He-Cutler on a mosaic whose colour per pixel is `colors` (0 R, 1 G, 2 B)."""
    R, G, B = (colors == 0), (colors == 1), (colors == 2)
    # rows/columns that hold red (or blue) photosites, for the G-site cases
    r_row = np.any(R, axis=1)[:, None] & np.ones_like(R)
    r_col = np.any(R, axis=0)[None, :] & np.ones_like(R)
    b_row = np.any(B, axis=1)[:, None] & np.ones_like(B)
    b_col = np.any(B, axis=0)[None, :] & np.ones_like(B)
    g_rb = convolve(cfa, _K_G_AT_RB, mode="mirror")
    row = convolve(cfa, _K_ROW, mode="mirror")
    col = convolve(cfa, _K_COL, mode="mirror")
    diag = convolve(cfa, _K_DIAG, mode="mirror")
    out = np.empty(cfa.shape + (3,), np.float32)
    out[..., 0] = np.where(R, cfa, np.where(G & r_row, row, np.where(G & r_col, col, diag)))
    out[..., 1] = np.where(G, cfa, g_rb)
    out[..., 2] = np.where(B, cfa, np.where(G & b_row, row, np.where(G & b_col, col, diag)))
    return out


def _upright_to_sensor(flip: int, W: int, H: int, left: int, top: int, w: int, h: int, SW: int, SH: int):
    """The sensor rectangle (x0, y0, x1, y1) under an upright box, and how to turn it upright."""
    if flip == 3:          # 180°
        return SW - (left + w), SH - (top + h), SW - left, SH - top, 2
    if flip == 6:          # sensor turned 90° clockwise to be upright: upright (ox, oy) = (SH-1-sy, sx)
        return top, SH - (left + w), top + h, SH - left, 3
    if flip == 5:          # 90° anticlockwise: upright (ox, oy) = (sy, SW-1-sx)
        return SW - (top + h), left, SW - top, left + w, 1
    return left, top, left + w, top + h, 0


def decode_region(path: str | Path, x: float, y: float, w: int, h: int) -> tuple[Image.Image, tuple]:
    """The crop `/m/api/crop?x&y&w&h` would make from the full decode, made from the crop's area.
    Returns (image, (left, top, w, h, W, H)) in the upright frame, as `X-Crop-Box` reports it."""
    import rawpy
    with rawpy.imread(str(path)) as raw:
        mosaic = raw.raw_image_visible                       # reads and unpacks the file
        SH, SW = mosaic.shape
        flip = raw.sizes.flip
        W, H = (SH, SW) if flip in (5, 6) else (SW, SH)
        left, top, w, h = crop_box(W, H, x, y, w, h)
        x0, y0, x1, y1, turns = _upright_to_sensor(flip, W, H, left, top, w, h, SW, SH)
        # the area plus a margin, starting on an even pixel so the colour pattern stays in phase
        ax0, ay0 = max(0, (x0 - MARGIN) & ~1), max(0, (y0 - MARGIN) & ~1)
        ax1, ay1 = min(SW, x1 + MARGIN), min(SH, y1 + MARGIN)
        pattern = raw.raw_pattern                              # 2x2 indices into color_desc
        desc = raw.color_desc.decode()                         # e.g. RGBG
        if pattern is None or pattern.shape != (2, 2) or sorted(set(desc)) != ["B", "G", "R"]:
            raise ValueError(f"not a 2x2 RGB Bayer sensor ({desc})")   # X-Trans and others: decode whole
        black = np.array(raw.black_level_per_channel, np.float32)
        white_level = float(raw.white_level)
        cam_mul = np.array(raw.camera_whitebalance, np.float64)
        rgb_cam = _rgb_cam(np.array(raw.rgb_xyz_matrix, np.float64)[:3, :3])
        area = mosaic[ay0:ay1, ax0:ax1].astype(np.float32)
        sample = mosaic[0:SH - 1:SAMPLE_STEP, :][:, 0:SW - 1:SAMPLE_STEP].astype(np.float32), \
            mosaic[1::SAMPLE_STEP, :][:, 0:SW - 1:SAMPLE_STEP].astype(np.float32), \
            mosaic[0:SH - 1:SAMPLE_STEP, :][:, 1::SAMPLE_STEP].astype(np.float32), \
            mosaic[1::SAMPLE_STEP, :][:, 1::SAMPLE_STEP].astype(np.float32)

    # LibRaw scale_colors, highlight mode 0: multipliers over the smallest, black off, clipped
    if cam_mul[3] == 0:
        cam_mul[3] = cam_mul[1]
    pre_mul = cam_mul / cam_mul.min()
    idx_of = {c: [i for i, d in enumerate(desc) if d == c] for c in "RGB"}

    def channel_of(index: int) -> int:
        return "RGB".index(desc[index])

    def scale(v: np.ndarray, cfa_index: np.ndarray | int) -> np.ndarray:
        blk = black[cfa_index]
        mul = pre_mul[cfa_index].astype(np.float32)
        return np.clip((v - blk) * mul * (65535.0 / (white_level - black.max())), 0, 65535)

    # the colour index of each photosite in the area
    py = (np.arange(ay0, ay1) % 2)[:, None]
    px = (np.arange(ax0, ax1) % 2)[None, :]
    cfa_index = pattern[py, px]
    cfa = scale(area, cfa_index)
    colors = np.array([channel_of(i) for i in range(len(desc))])[cfa_index]
    rgb = _demosaic(cfa, colors)
    rgb = np.clip(rgb.reshape(-1, 3) @ rgb_cam.T, 0, 65535).reshape(rgb.shape)

    # auto-bright from a sample of the whole frame: 2x2 blocks as (R, G, B), the same conversion
    blocks = {}
    for (dy, dx), arr in zip(((0, 0), (1, 0), (0, 1), (1, 1)), sample):
        blocks[(dy, dx)] = arr
    hh = min(a.shape[0] for a in sample)
    ww = min(a.shape[1] for a in sample)
    chans = {0: [], 1: [], 2: []}
    for (dy, dx), arr in blocks.items():
        i = int(pattern[dy, dx])
        chans[channel_of(i)].append(scale(arr[:hh, :ww], i))
    s_rgb = np.stack([np.mean(chans[c], axis=0) for c in range(3)], axis=-1).reshape(-1, 3)
    s_rgb = np.clip(s_rgb @ rgb_cam.T, 0, 65535)
    # LibRaw: per channel, the level where the brightest 1% begins (in steps of 8); the largest wins
    white = 0
    for c in range(3):
        level = int(np.percentile(s_rgb[:, c], 99.0)) >> 3
        white = max(white, max(level, 32))
    curve = _gamma_curve(white << 3)
    out8 = curve[np.clip(rgb, 0, 65535).astype(np.uint16)]

    # cut the box out of the area and turn it upright
    sx0, sy0 = x0 - ax0, y0 - ay0
    box = out8[sy0:sy0 + (y1 - y0), sx0:sx0 + (x1 - x0)]
    if turns:
        box = np.rot90(box, turns)
    return Image.fromarray(np.ascontiguousarray(box)), (left, top, w, h, W, H)
