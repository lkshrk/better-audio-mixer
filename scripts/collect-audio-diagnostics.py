#!/usr/bin/env python3
"""Collect read-only JSONL audio telemetry from an already-running BAM app."""
import argparse
import json
import os
import socket
import sys
import time


def read_frame(connection, pending, deadline):
    while time.monotonic() < deadline:
        while b"\n" in pending:
            line, _, tail = pending.partition(b"\n")
            pending[:] = tail
            frame = json.loads(line)
            if frame.get("t") == "error":
                raise RuntimeError(f"BAM rejected request: {frame.get('code', 'unknown')}")
            return frame
        connection.settimeout(max(0.001, deadline - time.monotonic()))
        chunk = connection.recv(65536)
        if not chunk:
            raise RuntimeError("BAM disconnected")
        pending.extend(chunk)
        if len(pending) > 1024 * 1024:
            raise RuntimeError("BAM frame exceeds 1 MiB")
    raise TimeoutError("BAM response deadline reached")


def read_type(connection, pending, kind, deadline):
    try:
        while time.monotonic() < deadline:
            frame = read_frame(connection, pending, deadline)
            if frame.get("t") == kind:
                return frame
    except TimeoutError:
        pass
    raise TimeoutError(f"No {kind} response; the installed BAM may need updating")


def drain_until(connection, pending, deadline):
    # BAM also pushes meters on this socket. Keep consuming them between requests
    # so measurement does not block its shared control-server send queue.
    try:
        while time.monotonic() < deadline:
            read_frame(connection, pending, deadline)
    except TimeoutError:
        return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default=os.path.expanduser("~/Library/Application Support/me.harke.bam/control.sock"))
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args()
    if not 1 <= args.samples <= 86400 or not 0.1 <= args.interval <= 60:
        parser.error("samples must be 1..86400 and interval 0.1..60 seconds")
    pending = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(3)
        connection.connect(args.socket)
        connection.sendall(b'{"t":"hello","v":1,"client":"audio-diagnostics"}\n')
        read_type(connection, pending, "hello-ack", time.monotonic() + 3)
        for index in range(args.samples):
            connection.sendall(b'{"t":"diagnostics"}\n')
            frame = read_type(connection, pending, "diagnostics", time.monotonic() + 3)
            print(json.dumps({"observedAt": time.time(), "audio": frame.get("audio")}, allow_nan=False), flush=True)
            if index + 1 < args.samples:
                drain_until(connection, pending, time.monotonic() + args.interval)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as error:
        print(f"audio diagnostics: {error}", file=sys.stderr)
        sys.exit(1)
