"""Sealed media, the app's format (presence_app/lib/crypto/seal_format.dart,
presence_streamer/internal/seal): a header, then the media in chunks, each
AES-256-GCM.

  4  magic: "PSE" and the format version, 1
  1  the key ID's length, n (1 to 64)
  n  the key ID: the device whose key sealed it (ASCII)
  4  the chunk size, big-endian
  7  a random nonce prefix

Each chunk is up to the chunk size of media and its 16-byte tag; a chunk's
nonce is the prefix, its index (4 bytes, big-endian) and 1 for the last
chunk, 0 otherwise; the header is every chunk's additional data.
"""

import os
import re
import struct

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"PSE\x01"
CHUNK_SIZE = 256 * 1024
TAG = 16
PREFIX = 7
KEY_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


class Broken(Exception):
    """Sealed media that doesn't open: not sealed, changed, cut off, or
    another key."""


def _nonce(header: bytes, index: int, last: bool) -> bytes:
    return header[-PREFIX:] + struct.pack(">I", index) + (b"\x01" if last else b"\x00")


def read_header(f) -> tuple[bytes, str, int]:
    """The header at the start of the file f: (its bytes, key ID, chunk size)."""
    start = f.read(5)
    if len(start) < 5 or start[:4] != MAGIC or not 1 <= start[4] <= 64:
        raise Broken("not sealed media")
    rest = f.read(start[4] + 4 + PREFIX)
    if len(rest) != start[4] + 4 + PREFIX:
        raise Broken("cut off")
    try:
        key_id = rest[: start[4]].decode("ascii")
    except UnicodeDecodeError:
        raise Broken("not a key ID") from None
    if not KEY_ID.match(key_id):
        raise Broken("not a key ID")
    (size,) = struct.unpack(">I", rest[start[4] : start[4] + 4])
    if not 1024 <= size <= 16 * 1024 * 1024:
        raise Broken("not a chunk size")
    return start + rest, key_id, size


def open_file(src: str, dst: str, key: bytes) -> None:
    """Opens the sealed file src into dst, a chunk at a time."""
    aead = AESGCM(key)
    with open(src, "rb") as f, open(dst, "wb") as out:
        header, _, size = read_header(f)
        full = size + TAG
        cur = f.read(full)
        index = 0
        while True:
            nxt = f.read(full) if len(cur) == full else b""
            last = not nxt
            if len(cur) < TAG:
                raise Broken("cut off")
            try:
                out.write(aead.decrypt(_nonce(header, index, last), cur, header))
            except Exception:
                raise Broken("doesn't open") from None
            if last:
                return
            cur, index = nxt, index + 1


def seal_bytes(media: bytes, key: bytes, key_id: str, prefix: bytes | None = None) -> bytes:
    """media sealed with key, the key of device key_id."""
    if not KEY_ID.match(key_id):
        raise ValueError("not a safe key ID")
    prefix = os.urandom(PREFIX) if prefix is None else prefix
    header = MAGIC + bytes([len(key_id)]) + key_id.encode() + struct.pack(">I", CHUNK_SIZE) + prefix
    aead = AESGCM(key)
    count = max(1, -(-len(media) // CHUNK_SIZE))
    parts = [header]
    for i in range(count):
        chunk = media[i * CHUNK_SIZE : (i + 1) * CHUNK_SIZE]
        parts.append(aead.encrypt(_nonce(header, i, i == count - 1), chunk, header))
    return b"".join(parts)
