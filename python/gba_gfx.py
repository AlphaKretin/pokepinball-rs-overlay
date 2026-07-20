"""Decode raw GBA 4bpp tile graphics + BGR555 palettes straight out of the
ROM, for the few graphics that pret/pokepinballrs hasn't split into PNGs
itself yet (still a raw `.incbin "baserom.gba", ...` blob in its data files,
unlike e.g. `graphics/mon_portraits/*.png`, which the decomp project already
ships pre-split).

No third-party dependencies (no Pillow) -- this repo has none today, and a
minimal indexed-color PNG writer is a small enough amount of code that it's
not worth adding one just for this.

See docs/graphics-extraction.md for how the tile-arrangement format used
here (2x2-tile metatiles) was determined, and why a naive raster-order read
doesn't work.
"""

import struct
import zlib

ROM_BASE_ADDR = 0x08000000
TILE_SIZE_PX = 8
BYTES_PER_TILE = 32  # 8x8 px at 4 bits/px


def rom_offset(addr):
    """Convert a GBA ROM address (0x08xxxxxx) to a byte offset into the ROM file."""
    return addr - ROM_BASE_ADDR


def load_rom(path):
    with open(path, "rb") as f:
        return f.read()


def bgr555_to_rgb(color):
    """GBA colors are BGR555: 5 bits each of blue/green/red, packed low-to-high, in a u16."""
    r = (color & 0x1F) * 255 // 31
    g = ((color >> 5) & 0x1F) * 255 // 31
    b = ((color >> 10) & 0x1F) * 255 // 31
    return (r, g, b)


def read_palette(rom, addr, num_colors=16):
    off = rom_offset(addr)
    colors = []
    for i in range(num_colors):
        c = struct.unpack_from("<H", rom, off + i * 2)[0]
        colors.append(bgr555_to_rgb(c))
    return colors


def decode_tile_4bpp(data, tile_index):
    """Return an 8x8 (row-major) grid of palette indices for one tile.

    4bpp GBA tiles pack two pixels per byte, low nibble first (left pixel).
    """
    base = tile_index * BYTES_PER_TILE
    tile = [[0] * TILE_SIZE_PX for _ in range(TILE_SIZE_PX)]
    for row in range(TILE_SIZE_PX):
        row_base = base + row * (TILE_SIZE_PX // 2)
        for col_byte in range(TILE_SIZE_PX // 2):
            b = data[row_base + col_byte]
            tile[row][col_byte * 2] = b & 0xF
            tile[row][col_byte * 2 + 1] = (b >> 4) & 0xF
    return tile


def assemble_metatile_image(data, meta_wide, meta_tall, mwidth, mheight):
    """Assemble a full image from tiles stored in pret's "gfx-config" metatile
    order: the image is a meta_wide x meta_tall grid of metatiles, each
    metatile is mwidth x mheight tiles (row-major within the metatile), and
    metatiles themselves are stored row-major. This is the same layout pret's
    own mon_portraits_gfx.json describes (mwidth=2, mheight=2, width=6 tiles
    -> meta_wide=3, meta_tall=2 for a 48x32 portrait) -- see
    docs/graphics-extraction.md for how this was confirmed against a known
    image (Treecko's portrait) before trusting it on unverified graphics.
    """
    tiles_wide = meta_wide * mwidth
    tiles_tall = meta_tall * mheight
    w, h = tiles_wide * TILE_SIZE_PX, tiles_tall * TILE_SIZE_PX
    img = [[0] * w for _ in range(h)]
    idx = 0
    for my in range(meta_tall):
        for mx in range(meta_wide):
            for ty in range(mheight):
                for tx in range(mwidth):
                    tile = decode_tile_4bpp(data, idx)
                    px, py = (mx * mwidth + tx) * TILE_SIZE_PX, (my * mheight + ty) * TILE_SIZE_PX
                    for r in range(TILE_SIZE_PX):
                        for c in range(TILE_SIZE_PX):
                            img[py + r][px + c] = tile[r][c]
                    idx += 1
    return img


def save_png_rgb(img, palette, path):
    """Write a palette-indexed image (list of rows of palette indices) as a
    plain 8-bit RGB truecolor PNG -- no indexed-color PNG chunk, just resolve
    through `palette` up front, since these images are tiny (a few KB at
    most) and a truecolor PNG needs no PLTE-chunk bookkeeping.
    """
    h, w = len(img), len(img[0])

    def chunk(tag, chunk_data):
        c = tag + chunk_data
        return struct.pack(">I", len(chunk_data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)  # 8-bit RGB truecolor
    raw = bytearray()
    for row in img:
        raw.append(0)  # no per-scanline filter
        for idx in row:
            raw += bytes(palette[idx])
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))
