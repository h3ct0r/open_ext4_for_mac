#!/usr/bin/env bash
# Regenerate the AES-XTS known-answer table in tools/cryptotest.c.
#
# The vectors come from OpenSSL, reached through python-cryptography in a
# container, rather than being transcribed from a specification by hand. A
# hand-copied vector tests the transcription; if it is wrong, the
# implementation is then "verified" against our own mistake.
#
# Only needed when adding cases. Prints the C table to stdout; paste it into
# tools/cryptotest.c.
set -euo pipefail

docker info >/dev/null 2>&1 || { echo "docker is not running" >&2; exit 1; }

docker run --rm python:3.12-slim bash -c '
pip install -q cryptography 2>/dev/null
python3 - <<PY
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
import binascii, hashlib

def xts(key, tweak, data, enc=True):
    c = Cipher(algorithms.AES(key), modes.XTS(tweak))
    op = c.encryptor() if enc else c.decryptor()
    return op.update(data) + op.finalize()

def plain64(n):
    # dm-crypt plain64: the sector index, little-endian, zero padded to 16 bytes
    return n.to_bytes(8, "little") + b"\x00" * 8

k128 = bytes(range(32))
k256 = bytes(range(64))
for name, key, sect, size in [
    ("aes128, sector 0",         k128, 0,            512),
    ("aes128, sector 1",         k128, 1,            512),
    ("aes256, sector 0",         k256, 0,            512),
    ("aes256, sector 1",         k256, 1,            512),
    ("aes256, sector 42",        k256, 42,           512),
    ("aes256, 40-bit sector",    k256, 0x0123456789, 512),
    ("aes256, 4096-byte sector", k256, 8,            4096),
]:
    # Must match the generator in cryptotest.c.
    pt = bytes((i * 7 + 13) & 0xFF for i in range(size))
    ct = xts(key, plain64(sect), pt, True)
    assert xts(key, plain64(sect), ct, False) == pt, "round trip failed"
    print("    { \"%s\"," % name)
    print("      \"%s\"," % binascii.hexlify(key).decode())
    print("      %uULL, %u," % (sect, size))
    print("      \"%s\" }," % hashlib.sha256(ct).hexdigest())
PY' 2>/dev/null | grep -v '^WARNING\|^\[notice'
