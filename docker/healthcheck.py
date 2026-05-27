#!/usr/bin/env python3
"""Steam A2S_INFO healthcheck for Starrupture dedicated server.

Sends a UDP A2S_INFO query to HEALTHCHECK_HOST:SERVER_QUERY_PORT and
exits 0 if the server replies with an `I` (info) or `A` (challenge)
packet within HEALTHCHECK_TIMEOUT seconds. Exit 1 otherwise.

Pure stdlib, no fork/exec: ~5 ms to run.
"""
from __future__ import annotations

import os
import socket
import sys

HOST = os.environ.get("HEALTHCHECK_HOST", "127.0.0.1")
PORT = int(os.environ.get("SERVER_QUERY_PORT", "27015"))
TIMEOUT = float(os.environ.get("HEALTHCHECK_TIMEOUT", "3"))

A2S_INFO = b"\xff\xff\xff\xffTSource Engine Query\x00"


def probe() -> int:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.settimeout(TIMEOUT)
            sock.sendto(A2S_INFO, (HOST, PORT))
            data, _ = sock.recvfrom(2048)
    except (socket.timeout, OSError) as exc:
        print(f"healthcheck: FAIL {HOST}:{PORT} ({exc})", file=sys.stderr)
        return 1

    if len(data) >= 5 and data[:4] == b"\xff\xff\xff\xff" and data[4:5] in (b"I", b"A"):
        return 0

    print(f"healthcheck: unexpected reply prefix {data[:8]!r}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(probe())
