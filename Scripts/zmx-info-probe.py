#!/usr/bin/env python3
"""Hexdump zmx's `ipc.Info` reply, so its layout can be re-derived by hand.

Nothing upstream documents `ipc.Info`, and its offsets are what `ZmxInfo.decode`
is built on. When a new zmx moves a field, `swift run zmxterm --selftest` fails
on the captured payload and this is how you find out what moved.

    Scripts/zmx-info-probe.py <session>...            dump, annotated
    Scripts/zmx-info-probe.py --watch <session>       poll, printing byte diffs
    Scripts/zmx-info-probe.py --base64 <session>      a payload to paste into a test

The method that produced the current table: dump a few sessions and match the
fields you already know from `zmx list` (pid, clients, created, start_dir and
its length, cmd), then `--watch` one session while running `zmx run <s> -d bash
-c 'exit 7'` and see which bytes move. Do that in a `qa*` session of your own —
this only reads, but nothing stops you pointing it at somebody's live agent.

It connects as a passive observer: it sends `.info` and never `.Init`, so the
daemon neither replays the screen nor counts it as a terminal client, and the
`clients` it reports back does not include us.
"""
import os
import socket
import struct
import sys
import time

TAG_INFO = 6
HEADER = 8  # Not 5. See ZmxFrame.headerSize.

# offset: (size, name) — the layout ZmxInfo.decode implements.
FIELDS = [
    (0, 8, "clients"),
    (8, 4, "pid"),
    (12, 2, "command_len"),
    (14, 2, "start_dir_len"),
    (16, 256, "command"),
    (272, 256, "start_dir"),
    (528, 8, "created_at"),
    (536, 8, "task_ended_at"),
    (544, 4, "task_exit_code"),
    (548, 4, "padding"),
]


def socket_dir():
    tmp = os.environ.get("TMPDIR", "/tmp")
    return os.environ.get("ZMX_SOCKET_DIR") or os.path.join(tmp, "zmx-%d" % os.getuid())


def frame(tag, payload=b""):
    return bytes([tag]) + struct.pack("<I", len(payload)) + b"\0\0\0" + payload


def info(session, timeout=2.0):
    """The `.info` payload, or None. Other frames arrive first if the session is
    talking, so read until the reply shows up."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(os.path.join(socket_dir(), session))
        sock.sendall(frame(TAG_INFO))
        buf = b""
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                return None
            buf += chunk
            while len(buf) >= HEADER:
                tag = buf[0]
                length = struct.unpack("<I", buf[1:5])[0]
                if len(buf) - HEADER < length:
                    break
                payload, buf = buf[HEADER:HEADER + length], buf[HEADER + length:]
                if tag == TAG_INFO:
                    return payload
    except (socket.timeout, OSError):
        return None
    finally:
        sock.close()


def show(session, payload):
    print("=== %s  (%d bytes)" % (session, len(payload)))
    for offset, size, name in FIELDS:
        raw = payload[offset:offset + size]
        if size in (2, 4, 8):
            value = int.from_bytes(raw, "little")
            print("  %3d %3d  %-14s %d" % (offset, size, name, value))
        else:
            print("  %3d %3d  %-14s %r" % (offset, size, name, raw.split(b"\0")[0].decode("utf8", "replace")))
    print("  raw head: %s" % " ".join("%02x" % c for c in payload[:16]))
    print("  raw tail: %s" % " ".join("%02x" % c for c in payload[528:]))


def watch(session, interval=1.0):
    print("watching %s — run a task in it and see what moves" % session)
    previous = None
    while True:
        payload = info(session)
        if payload is None:
            print("  gone"); return
        if previous is not None:
            moved = [i for i in range(min(len(previous), len(payload))) if previous[i] != payload[i]]
            for i in moved:
                owner = next((n for o, s, n in FIELDS if o <= i < o + s), "?")
                print("  @%3d %-14s %02x -> %02x" % (i, owner, previous[i], payload[i]))
        previous = payload
        time.sleep(interval)


if __name__ == "__main__":
    arguments = sys.argv[1:]
    if not arguments:
        sys.exit(__doc__)
    if arguments[0] == "--watch":
        watch(arguments[1])
    elif arguments[0] == "--base64":
        import base64
        print(base64.b64encode(info(arguments[1])).decode())
    else:
        for name in arguments:
            payload = info(name)
            if payload is None:
                print("=== %s  no reply" % name)
            else:
                show(name, payload)
