#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tl-audio-bridge：把天乐推流引擎（PC 本机 9801）的 PCM，转到手机 TLCam 插件的 9801。

链路：
    天乐 tl_push.exe  --(9801, 4字节大端长度 + s16le/48k/2ch)-->  本脚本
    本脚本  --(手机 9801, 16字节头（前4字节大端长度）+ PCM)-->  TLCam.dylib
    TLCam 把 PCM 画进相机的 audio buffer -> 抖音直播采集到真实音频

用法：
    python audio-bridge.py --host 192.168.10.5
    python audio-bridge.py --host 192.168.10.5 --src 127.0.0.1:9801 --port 9801

参数：
    --host   手机 IP（同 WiFi）
    --port   手机 TLCam 的音频端口，默认 9801
    --src    天乐音频源，默认 127.0.0.1:9801
    --usbmux 走 USB（usbmux 转发到手机端口）
"""
import argparse
import socket
import struct
import sys
import time

RATE = 48000
CH = 2
BPS = 2


def log(msg):
    print(time.strftime("[%H:%M:%S] ") + msg, flush=True)


def read_full(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def connect_src(addr, retry=True):
    host, port = addr
    while True:
        try:
            s = socket.create_connection((host, port), timeout=5)
            s.settimeout(None)
            log("tianle audio %s:%d connected" % (host, port))
            return s
        except Exception as e:
            log("wait for tianle: %s" % e)
            if not retry:
                raise
            time.sleep(1.0)


def usbmux_connect(device_port, udid=None):
    c = socket.create_connection(("127.0.0.1", 27015), timeout=5)
    req = {"MessageType": "Connect", "ClientVersionString": "tl-audio-bridge",
           "ProgName": "tl-audio-bridge", "kLibUSBMuxVersion": 3,
           "DeviceID": 0, "PortNumber": socket.htons(device_port)}
    data = b"plist" + struct.pack("<I", len(b""))  # placeholder, replaced below
    import plistlib
    body = plistlib.dumps(req)
    c.sendall(b"plist" + struct.pack("<I", len(body)) + body)
    hdr = read_full(c, 16)
    if not hdr:
        raise RuntimeError("usbmux: no reply")
    ln = struct.unpack("<I", hdr[12:16])[0]
    payload = read_full(c, ln) if ln else b""
    if not payload.startswith(b"bplist") and b"<plist" not in payload[:8]:
        # 旧格式：16 字节头里第 4..8 是结果码
        code = struct.unpack("<I", hdr[4:8])[0]
        raise RuntimeError("usbmux connect failed code=%d" % code)
    import plistlib as pl
    res = pl.loads(payload)
    if int(res.get("Number", 0)) != 0:
        raise RuntimeError("usbmux connect failed Number=%s" % res.get("Number"))
    return c, "usb"


def connect_sink(args):
    last = None
    while True:
        if args.usbmux:
            try:
                c, _ = usbmux_connect(args.port)
                log("phone audio via usbmux -> %d" % args.port)
                return c
            except Exception as e:
                last = e
                log("usbmux failed: %s" % e)
        try:
            c = socket.create_connection((args.host, args.port), timeout=5)
            c.settimeout(None)
            log("phone audio via wifi -> %s:%d" % (args.host, args.port))
            return c
        except Exception as e:
            last = e
            log("wait for phone: %s" % e)
        time.sleep(2.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="192.168.10.5")
    ap.add_argument("--port", type=int, default=9801)
    ap.add_argument("--src", default="127.0.0.1:9801")
    ap.add_argument("--usbmux", action="store_true")
    args = ap.parse_args()

    sh, sp = args.src.split(":")
    src = connect_src((sh, int(sp)))
    sink = connect_sink(args)

    total = 0
    blocks = 0
    t0 = time.time()
    while True:
        hdr = read_full(src, 4)
        if hdr is None:
            log("tianle closed, reconnecting")
            src.close()
            src = connect_src((sh, int(sp)))
            continue
        ln = struct.unpack(">I", hdr)[0]
        if ln < 16 or ln > 65536:
            log("bad pcm len %d, resync" % ln)
            continue
        pcm = read_full(src, ln)
        if pcm is None:
            log("short pcm, reconnecting")
            src.close()
            src = connect_src((sh, int(sp)))
            continue
        out = struct.pack(">I", len(pcm)) + b"\x00" * 12 + pcm
        try:
            sink.sendall(out)
        except Exception as e:
            log("phone closed: %s" % e)
            sink.close()
            sink = connect_sink(args)
            continue
        total += len(pcm)
        blocks += 1
        if blocks % 200 == 0:
            dt = time.time() - t0
            kbps = total / max(dt, 1e-6) / 1024.0
            log("audio %d blocks, %.1f KB, %.1f KB/s" % (blocks, total / 1024.0, kbps))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
