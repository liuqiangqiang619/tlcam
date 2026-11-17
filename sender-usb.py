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
import tempfile
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


WIFI_HOST = os.environ.get("TL_PHONE", "192.168.10.5")


def _local_ips():
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.append(s.getsockname()[0])
        s.close()
    except Exception:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except Exception:
        pass
    return ips


def _override_host():
    try:
        p = os.path.join(tempfile.gettempdir(), "tl_phone_override.txt")
        if os.path.exists(p):
            v = open(p).read().strip()
            if v:
                return v
    except Exception:
        pass
    return ""


def discover_phone(port, timeout=0.35):
    """扫本机 /24 网段找开着 port 的手机（插件监听端口）。"""
    ov = _override_host()
    if ov:
        return ov
    cache = os.path.join(tempfile.gettempdir(), "tl_phone_%d.txt" % port)
    try:
        if os.path.exists(cache) and time.time() - os.path.getmtime(cache) < 12 * 3600:
            ip = open(cache).read().strip()
            if ip:
                return ip
    except Exception:
        pass
    for base in _local_ips():
        prefix = base.rsplit(".", 1)[0]
        found = []

        def probe(i):
            try:
                c = socket.create_connection((prefix + "." + str(i), port), timeout=timeout)
                c.close()
                found.append(prefix + "." + str(i))
            except Exception:
                pass

        threads = [threading.Thread(target=probe, args=(i,), daemon=True) for i in range(2, 255)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout + 0.2)
        if found:
            ip = found[0]
            try:
                open(cache, "w").write(ip)
            except Exception:
                pass
            return ip
    return None


def connect_sink(args, kind, port, direct):
    if direct:
        host, p = direct.split(":")
        s = socket.create_connection((host, int(p)), timeout=5)
        print(f"[usb] {kind} direct {host}:{p}")
    else:
        s = None
        err = None
        # 1) 先试 usbmux（iOS 常拒绝转发到 App 自建端口，失败属正常）
        try:
            print(f"[usb] {kind} usbmux -> device port {port} ...")
            s = usbmux_connect(port, args.udid)
            print(f"[usb] {kind} connected via usbmux")
        except Exception as e:
            err = e
            print(f"[usb] {kind} usbmux failed: {e}")
        # 2) 退回 Wi-Fi（手机侧插件监听的是本机网卡，usbmux 转发到 127.0.0.1 会被拒）
        if s is None:
            host = getattr(args, "host", None) or _override_host() or WIFI_HOST
            s = None
            if host:
                try:
                    print(f"[usb] {kind} wifi -> {host}:{port} ...")
                    s = socket.create_connection((host, port), timeout=3)
                    print(f"[usb] {kind} connected via wifi {host}")
                except Exception as e:
                    print(f"[usb] {kind} wifi {host} failed: {e}")
                    s = None
            if s is None:
                found = discover_phone(port)
                if not found:
                    raise RuntimeError("no phone found on LAN (port %d)" % port)
                print(f"[usb] {kind} discovered phone {found}:{port}")
                s = socket.create_connection((found, port), timeout=3)
                print(f"[usb] {kind} connected via wifi {found}")
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


def ts():
    return time.strftime("%H:%M:%S")


def audio_pump(args, sink):
    host, port = args.audio_src.split(":")
    while True:
        try:
            src = socket.create_connection((host, int(port)), timeout=5)
            src.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            print(f"[usb] {ts()} audio src {host}:{port}", flush=True)
            aseq = 0
            total = 0
            t0 = time.time()
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
                total += n
                now = time.time()
                if now - t0 >= 3.0:
                    print(f"[usb] {ts()} audio {total} bytes {(total / (now - t0) / 1024):.1f} KB/s", flush=True)
                    total = 0
                    t0 = now
        except Exception as e:
            print(f"[usb] {ts()} audio retry:", e, flush=True)
        time.sleep(1.0)


def audio_worker(args):
    """音频连接放到独立线程：视频先通，音频自己慢慢重试，不阻塞主流程。"""
    while True:
        try:
            asink = connect_sink(args, "audio", args.audio_port, args.audio_direct)
            print(f"[usb] {ts()} audio sink ready", flush=True)
            audio_pump(args, asink)
        except Exception as e:
            print(f"[usb] {ts()} wait for device (audio):", e, flush=True)
        time.sleep(2.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="127.0.0.1:9800", help="tl_push 视频端口")
    ap.add_argument("--audio-src", default="127.0.0.1:9801", help="tl_push 音频端口")
    ap.add_argument("--port", type=int, default=9800, help="手机视频监听端口")
    ap.add_argument("--audio-port", type=int, default=9801, help="手机音频监听端口")
    ap.add_argument("--direct", help="视频不走 usbmux，直连 host:port（自测）")
    ap.add_argument("--audio-direct", help="音频不走 usbmux，直连 host:port（自测）")
    ap.add_argument("--udid", default=None)
    ap.add_argument("--host", default=None, help="phone IP for wifi fallback (default 192.168.10.5)")
    ap.add_argument("--no-audio", action="store_true")
    args = ap.parse_args()

    print("[usb] sender build 2026-11-16 23:50 (audio-thread)", flush=True)
    if not args.no_audio:
        threading.Thread(target=audio_worker, args=(args,), daemon=True).start()
    vsink = None
    while vsink is None:
        try:
            vsink = connect_sink(args, "video", args.port, args.direct)
        except Exception as e:
            msg = str(e)
            if "10061" in msg or "refused" in msg.lower():
                msg += "  << 手机端口没监听：抖音要停在「直连」页并保持「片源预览」弹窗"
            elif "10060" in msg or "timed out" in msg.lower():
                msg += "  << 连不上手机：检查是否同一 Wi-Fi，或在自检里手动填手机 IP"
            elif "usbmuxd" in msg:
                msg += "  << 没有 USB 设备；已尝试 Wi-Fi 兜底"
            print("[usb] wait for device:", msg, flush=True)
            time.sleep(2.0)
    threading.Thread(target=video_pump, args=(args, vsink), daemon=True).start()
    print(f"[usb] {ts()} video sink ready", flush=True)

    try:
        while True:
            time.sleep(1.0)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
