#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sender-usb.py —— 把天乐合成好的 H264 + PCM 通过 USB(usbmux) 送给手机上的 TLCam

数据来源（tl_push 的 TL_CAMOUT）：
    9800: 12 字节头 {type=1, flags, len u16 BE, seq u32 BE, pts u32 BE} + 一个 H264 NAL
    9801: 4 字节长度(u32 BE) + PCM s16le 48k 立体声

目标：手机上的 TLCam 监听同样的两个端口（经 usbmux 由 PC 主动连进去）

用法：
    python sender-usb.py                       # 经 usbmux 连手机 9800/9801
    python sender-usb.py --direct 127.0.0.1:9899 --audio-direct 127.0.0.1:9898  # 本机自测
    python sender-usb.py --no-audio
"""
import argparse
import os
import socket
import struct
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from sender import usbmux_connect  # noqa: E402

HDR = struct.Struct(">IIIBBH")    # len, seq, pts, type, flags, rsv
TYPE_VIDEO = 1
TYPE_AUDIO = 2


def recvn(sock, n):
    out = b""
    while len(out) < n:
        b = sock.recv(n - len(out))
        if not b:
            return None
        out += b
    return out


def connect_sink(args, kind, port, direct):
    if direct:
        host, p = direct.split(":")
        s = socket.create_connection((host, int(p)), timeout=5)
        print(f"[usb] {kind} direct {host}:{p}")
    else:
        print(f"[usb] {kind} usbmux -> device port {port} ...")
        s = usbmux_connect(port, args.udid)
        print(f"[usb] {kind} connected via usbmux")
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def video_pump(args, sink):
    host, port = args.src.split(":")
    while True:
        try:
            src = socket.create_connection((host, int(port)), timeout=5)
            src.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            print(f"[usb] video src {host}:{port}")
            n = 0
            t0 = time.time()
            while True:
                h = recvn(src, 16)
                if not h:
                    break
                ln, seq, pts, t, fl, rsv = HDR.unpack(h)
                if ln < 1 or ln > 4 * 1024 * 1024:
                    break
                d = recvn(src, ln)
                if not d:
                    break
                sink.sendall(HDR.pack(ln, seq, pts, t, fl, 0))
                sink.sendall(d)
                n += 1
                now = time.time()
                if now - t0 >= 3.0:
                    print(f"[usb] video {n} nals {(n / (now - t0)):.1f}/s typ={d[0] & 0x1F}")
                    n = 0
                    t0 = now
        except Exception as e:
            print("[usb] video retry:", e)
        time.sleep(1.0)


def audio_pump(args, sink):
    host, port = args.audio_src.split(":")
    while True:
        try:
            src = socket.create_connection((host, int(port)), timeout=5)
            src.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            print(f"[usb] audio src {host}:{port}")
            aseq = 0
            while True:
                h = recvn(src, 4)
                if not h:
                    break
                n = struct.unpack(">I", h)[0]
                if n == 0 or n > 65536:
                    break
                if n < 16:
                    recvn(src, n)
                    continue
                d = recvn(src, n)
                if not d:
                    break
                sink.sendall(HDR.pack(n, aseq & 0xFFFFFFFF, 0, TYPE_AUDIO, 0, 0))
                sink.sendall(d)
                aseq += 1
        except Exception as e:
            print("[usb] audio retry:", e)
        time.sleep(1.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="127.0.0.1:9800", help="tl_push 视频端口")
    ap.add_argument("--audio-src", default="127.0.0.1:9801", help="tl_push 音频端口")
    ap.add_argument("--port", type=int, default=9800, help="手机视频监听端口")
    ap.add_argument("--audio-port", type=int, default=9801, help="手机音频监听端口")
    ap.add_argument("--direct", help="视频不走 usbmux，直连 host:port（自测）")
    ap.add_argument("--audio-direct", help="音频不走 usbmux，直连 host:port（自测）")
    ap.add_argument("--udid", default=None)
    ap.add_argument("--no-audio", action="store_true")
    args = ap.parse_args()

    vsink = None
    while vsink is None:
        try:
            vsink = connect_sink(args, "video", args.port, args.direct)
        except Exception as e:
            print("[usb] wait for device:", e, flush=True)
            time.sleep(2.0)
    threading.Thread(target=video_pump, args=(args, vsink), daemon=True).start()

    if not args.no_audio:
        asink = None
        while asink is None:
            try:
                asink = connect_sink(args, "audio", args.audio_port, args.audio_direct)
            except Exception as e:
                print("[usb] wait for device (audio):", e, flush=True)
                time.sleep(2.0)
        threading.Thread(target=audio_pump, args=(args, asink), daemon=True).start()

    try:
        while True:
            time.sleep(1.0)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
