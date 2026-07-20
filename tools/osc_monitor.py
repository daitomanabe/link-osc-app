#!/usr/bin/env python3
"""OSC 受信モニター (依存パッケージなし)。#bundle 対応。

使い方: python3 osc_monitor.py [port]
60fps ストリーム系は 1 秒ごとに集計表示、イベント系は毎回表示する。
"""

import socket
import struct
import sys
import time

STREAMS = ("/fft", "/vol", "/pfft", "/pvol", "/hfft", "/hvol",
           "/novelty", "/chroma", "/hpss")


def parse_osc(data):
    """単一 OSC メッセージ → (address, [args])"""
    def read_str(buf, pos):
        end = buf.index(b"\x00", pos)
        s = buf[pos:end].decode("ascii", "replace")
        return s, (end + 4) & ~3

    addr, pos = read_str(data, 0)
    if not addr.startswith("/"):
        return None, []
    tags, pos = read_str(data, pos)
    args = []
    for t in tags.lstrip(","):
        if t == "f":
            args.append(struct.unpack(">f", data[pos:pos + 4])[0])
            pos += 4
        elif t == "i":
            args.append(struct.unpack(">i", data[pos:pos + 4])[0])
            pos += 4
        elif t == "s":
            s, pos = read_str(data, pos)
            args.append(s)
    return addr, args


def parse_packet(data):
    """OSC メッセージ / #bundle を (addr, args) のリストに展開する (再帰)。"""
    if data[:8] == b"#bundle\x00":
        out = []
        pos = 16  # "#bundle\0" + timetag
        while pos + 4 <= len(data):
            n = struct.unpack(">I", data[pos:pos + 4])[0]
            pos += 4
            out.extend(parse_packet(data[pos:pos + n]))
            pos += n
        return out
    addr, args = parse_osc(data)
    return [(addr, args)] if addr else []


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9001
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    print("listening on udp/%d ..." % port)

    stream = {}
    bundles = 0
    last_vol = 0.0
    last_fft = []
    t0 = time.time()

    while True:
        data, _ = sock.recvfrom(65536)
        if data[:8] == b"#bundle\x00":
            bundles += 1
        for addr, args in parse_packet(data):
            if addr in STREAMS:
                stream[addr] = stream.get(addr, 0) + 1
                if addr == "/fft":
                    last_fft = args
                elif addr == "/vol":
                    last_vol = args[0] if args else 0.0
            else:
                print("%s %s" % (addr, args))

        now = time.time()
        if now - t0 >= 1.0:
            peak = max(last_fft) if last_fft else 0.0
            rates = " ".join("%s:%d" % (k.lstrip("/"), v)
                             for k, v in sorted(stream.items()))
            extra = (" | bundles:%d" % bundles) if bundles else ""
            print("fft peak %.3f | vol %.4f | msg/s %s%s"
                  % (peak, last_vol, rates, extra))
            stream = {}
            bundles = 0
            t0 = now


if __name__ == "__main__":
    main()
