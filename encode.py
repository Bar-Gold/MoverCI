#!/usr/bin/env python3
"""
encode.py  –  Pack any file into a PNG image (stdlib only).

Usage:
    python encode.py <input_file> [output.png]

Layout inside the PNG
─────────────────────
Row 0  (header row):  width = max(8, ceil(data_len/3))
  pixels 0-3  → magic b"FILE" + 4 zero-bytes (12 bytes → 4 RGB pixels)
  pixels 4-7  → 8-byte little-endian uint64 = original file length
  pixels 8+   → filename bytes (UTF-8), zero-padded to fill the row

Rows 1+  (data rows):
  Each RGB pixel stores 3 consecutive bytes of the file.
  The last pixel of the last row is zero-padded if needed.
"""

import sys
import os
import struct
import zlib
import math


# ── PNG primitives (pure stdlib) ─────────────────────────────────────────────

def _chunk(tag: bytes, data: bytes) -> bytes:
    """Build one PNG chunk: length + tag + data + CRC."""
    length = struct.pack(">I", len(data))
    crc    = struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return length + tag + data + crc


def _write_png(path: str, width: int, height: int, rows: list[bytes]) -> None:
    """Write a 24-bit RGB PNG to *path* from a list of raw (unfiltered) rows."""
    # PNG signature
    sig = b"\x89PNG\r\n\x1a\n"

    # IHDR
    ihdr_data = struct.pack(">IIBBBBB",
        width, height,
        8,   # bit depth
        2,   # colour type: RGB
        0, 0, 0)
    ihdr = _chunk(b"IHDR", ihdr_data)

    # IDAT  – each row is prefixed with filter byte 0x00 (None)
    raw = b"".join(b"\x00" + row for row in rows)
    compressed = zlib.compress(raw, 9)
    idat = _chunk(b"IDAT", compressed)

    # IEND
    iend = _chunk(b"IEND", b"")

    with open(path, "wb") as f:
        f.write(sig + ihdr + idat + iend)


# ── Encode ────────────────────────────────────────────────────────────────────

def encode(input_path: str, output_path: str) -> None:
    with open(input_path, "rb") as f:
        file_data = f.read()

    filename_bytes = os.path.basename(input_path).encode("utf-8")
    file_len       = len(file_data)

    # Width = max(8, pixels needed for one full row of data)
    # We need ceil(file_len / 3) pixels for data rows, but the header row
    # must be at least 8 pixels wide to hold magic+length+some filename.
    data_pixels = math.ceil(file_len / 3) if file_len > 0 else 1
    width       = max(8, data_pixels)      # header row gets same width

    # ── Build header row ──────────────────────────────────────────────────
    # magic (4 bytes) | file_len as uint64 LE (8 bytes) | filename bytes
    # Total = 12 + len(filename_bytes), padded to width*3 bytes
    header_payload = b"FILE\x00\x00\x00\x00" \
                   + struct.pack("<Q", file_len) \
                   + filename_bytes
    header_row = header_payload[:width * 3].ljust(width * 3, b"\x00")

    # ── Build data rows ───────────────────────────────────────────────────
    # Pad file_data so it divides evenly into 3-byte pixels
    padded = file_data.ljust(width * 3 * math.ceil(data_pixels / width), b"\x00")
    # Chop into rows of width*3 bytes
    row_size  = width * 3
    data_rows = [padded[i:i + row_size].ljust(row_size, b"\x00")
                 for i in range(0, len(padded), row_size)]

    all_rows = [header_row] + data_rows
    height   = len(all_rows)

    _write_png(output_path, width, height, all_rows)

    print(f"Encoded  : {input_path!r}")
    print(f"Output   : {output_path!r}")
    print(f"File size: {file_len:,} bytes")
    print(f"Image    : {width}×{height} px  ({width*height*3:,} bytes raw)")


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python encode.py <input_file> [output.png]")
        sys.exit(1)

    inp = sys.argv[1]
    if not os.path.isfile(inp):
        print(f"Error: file not found: {inp!r}")
        sys.exit(1)

    out = sys.argv[2] if len(sys.argv) >= 3 else os.path.splitext(inp)[0] + "_encoded.png"
    encode(inp, out)
