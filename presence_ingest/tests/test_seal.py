import os
import struct

import pytest

from ingest import seal

FIXTURE = os.path.join(os.path.dirname(__file__), "..", "..", "presence_streamer", "testdata", "sealed-fixture.bin")
KEY = bytes(range(32))
MEDIA = bytes(i * 31 % 251 for i in range(300000))


def test_seals_as_the_streamer_does():
    # The Go streamer's fixture: the same key, key ID, nonce prefix and media.
    with open(FIXTURE, "rb") as f:
        fixture = f.read()
    assert seal.seal_bytes(MEDIA, KEY, "streamer_test_device", prefix=bytes(range(1, 8))) == fixture


def test_opens_the_streamers_media(tmp_path):
    out = tmp_path / "plain"
    seal.open_file(FIXTURE, str(out), KEY)
    assert out.read_bytes() == MEDIA


@pytest.mark.parametrize("size", [0, 1, seal.CHUNK_SIZE - 1, seal.CHUNK_SIZE, seal.CHUNK_SIZE + 1, 3 * seal.CHUNK_SIZE])
def test_round_trip(tmp_path, size):
    media = os.urandom(size)
    src, dst = tmp_path / "s", tmp_path / "d"
    src.write_bytes(seal.seal_bytes(media, KEY, "a_b_c"))
    seal.open_file(str(src), str(dst), KEY)
    assert dst.read_bytes() == media


def test_broken_does_not_open(tmp_path):
    good = seal.seal_bytes(os.urandom(2 * seal.CHUNK_SIZE + 5), KEY, "a_b_c")
    header = 4 + 1 + 5 + 4 + 7
    cases = {
        "other key": (good, bytes(32)),
        "changed": (good[:100] + bytes([good[100] ^ 1]) + good[101:], KEY),
        "cut at a chunk": (good[: header + seal.CHUNK_SIZE + seal.TAG], KEY),
        "not sealed": (b"plain video", KEY),
        "bad chunk size": (good[:10] + struct.pack(">I", 7) + good[14:], KEY),
    }
    for name, (data, key) in cases.items():
        src = tmp_path / name
        src.write_bytes(data)
        with pytest.raises(seal.Broken):
            seal.open_file(str(src), str(tmp_path / "out"), key)
