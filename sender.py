#!/usr/bin/env python3
# sender.py — 把一段视频以 JPEG 流的形式推给 iPhone 上的注入插件
#
# 用法:
#   python sender.py --file D:\video.mp4 --host 192.168.1.10 --port 9800
#   python sender.py --file video.mp4 --loop            # 循环播放
#   python sender.py --camera                           # 实时采集（摄像头/采集卡）
#   python sender.py --list                             # 列出本机采集设备
#
# 依赖: ffmpeg (本仓库自带 _sdk/ffmpeg...\bin\ffmpeg.exe，或系统 PATH)

import argparse
import plistlib
import socket
import struct
import subprocess
import sys
import time

SOI = b"\xff\xd8"
EOI = b"\xff\xd9"



# ---------------- usbmux（USB 直连，不依赖 Wi-Fi） ----------------
USBMUX_ADDR = ("127.0.0.1", 27015)


def _plist_send(sock, obj):
    body = plistlib.dumps(obj)
    sock.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, 1) + body)


def _plist_recv(sock):
    hdr = b""
    while len(hdr) < 16:
        c = sock.recv(16 - len(hdr))
        if not c:
            return None
        hdr += c
    total = struct.unpack("<I", hdr[:4])[0]
    rest = b""
    while len(rest) < total - 16:
        c = sock.recv(total - 16 - len(rest))
        if not c:
            return None
        rest += c
    try:
        return plistlib.loads(rest)
    except Exception:
        return None


def usbmux_connect(device_port, udid=None):
    """连到 iPhone 上某个端口，返回 socket；失败抛异常"""
    d = socket.create_connection(USBMUX_ADDR, timeout=5)
    _plist_send(d, {"MessageType": "ListDevices", "ClientVersionString": "sender.py",
                    "ProgName": "sender.py", "kLibUSBMuxVersion": 3})
    r = _plist_recv(d)
    devs = (r or {}).get("DeviceList", [])
    if not devs:
        d.close()
        raise RuntimeError("usbmuxd 没有发现设备（数据线接了吗？）")
    dev = None
    for x in devs:
        props = x.get("Properties", {})
        if udid and props.get("SerialNumber") != udid:
            continue
        dev = x
        break
    if dev is None:
        d.close()
        raise RuntimeError("没找到指定 udid 的设备")
    dev_id = dev.get("DeviceID")
    d.close()

    c = socket.create_connection(USBMUX_ADDR, timeout=5)
    _plist_send(c, {"MessageType": "Connect", "ClientVersionString": "sender.py",
                    "ProgName": "sender.py", "kLibUSBMuxVersion": 3,
                    "DeviceID": dev_id, "PortNumber": device_port & 0xFFFF})
    r = _plist_recv(c)
    if not r or r.get("MessageType") != "Result" or r.get("Number") != 0:
        num = (r or {}).get("Number")
        c.close()
        raise RuntimeError(f"连接设备端口 {device_port} 失败，Number={num}")
    c.settimeout(None)
    return c



# ---------------- 音频通道（当作手机麦克风的声音） ----------------
AUDIO_RATE = 48000
AUDIO_CH = 2
AUDIO_BLOCK = 1024          # 每块采样数（≈21ms）
AUDIO_BYTES = AUDIO_BLOCK * AUDIO_CH * 2


def audio_iter(ffmpeg, path, loop, start, camera_device=None):
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error"]
    if loop and not camera_device:
        cmd += ["-stream_loop", "-1"]
    if start and not camera_device:
        cmd += ["-ss", str(start)]
    if camera_device:
        cmd += ["-f", "dshow", "-i", f"audio={camera_device}"]
    else:
        cmd += ["-i", path]
    cmd += ["-vn", "-f", "s16le", "-ar", str(AUDIO_RATE), "-ac", str(AUDIO_CH), "pipe:1"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    try:
        while True:
            b = p.stdout.read(AUDIO_BYTES)
            if not b or len(b) < AUDIO_BYTES:
                break
            yield b
    finally:
        try:
            p.kill()
        except Exception:
            pass


def audio_server(port, ffmpeg, path, loop, start, camera_device=None, usbmux=False, udid=None):
    srv = None
    if not usbmux:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", port))
        srv.listen(1)
        print(f"[audio] listening 0.0.0.0:{port}")
    while True:
        if usbmux:
            try:
                conn = usbmux_connect(port, udid)
            except Exception as e:
                print(f"[audio] {e}")
                return
        else:
            conn, _ = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print("[audio] connected")
        t0 = time.time()
        n = 0
        try:
            for blk in audio_iter(ffmpeg, path, loop, start, camera_device):
                conn.sendall(len(blk).to_bytes(4, "big") + blk)
                n += 1
                # 按实时节奏发，避免一次性灌满
                target = t0 + n * (AUDIO_BLOCK / AUDIO_RATE)
                dt = target - time.time()
                if dt > 0:
                    time.sleep(dt)
        except (BrokenPipeError, ConnectionResetError):
            print("\n[audio] peer closed")
        finally:
            conn.close()
        if not loop:
            print("[audio] finished")
            return

def find_ffmpeg(explicit):
    if explicit:
        return explicit
    return "ffmpeg"


def list_devices(ffmpeg):
    cmd = [ffmpeg, "-hide_banner", "-list_devices", "true", "-f", "dshow", "-i", "dummy"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, errors="ignore").stderr
    except FileNotFoundError:
        print("找不到 ffmpeg，用 --ffmpeg 指定路径")
        return
    print(out)
    print("用法: python sender.py --camera --device \"设备名\"")


def camera_cmd(ffmpeg, device, w, h, fps, rtbuf, q):
    fmt = "mjpeg" if device.lower().find("camera") >= 0 or device.lower().find("webcam") >= 0 else "auto"
    # 采集卡常见为 rawvideo/yuyv，dshow 自带转换；设备不支持时去掉 -input_format
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-rtbufsize", rtbuf,
           "-f", "dshow", "-i", f"video={device}",
           "-vf", f"scale={w}:{h}:force_original_aspect_ratio=decrease,"
                  f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:black",
           "-r", str(fps), "-q:v", "4", "-f", "mjpeg", "pipe:1"]
    return cmd


def frame_iter_camera(ffmpeg, device, w, h, fps, rtbuf, q):
    p = subprocess.Popen(camera_cmd(ffmpeg, device, w, h, fps, rtbuf, q),
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    yield from _read_jpeg(p)


def frame_iter(ffmpeg, path, w, h, fps, loop, start, q):
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error"]
    if loop:
        cmd += ["-stream_loop", "-1"]
    if start:
        cmd += ["-ss", str(start)]
    cmd += [
        "-re", "-i", path,
        "-vf", f"scale={w}:{h}:force_original_aspect_ratio=decrease,"
               f"pad={w}:{h}:(ow-iw)/2:(oh-ih)/2:black",
        "-r", str(fps), "-q:v", str(q), "-pix_fmt", "yuvj420p", "-f", "mjpeg", "pipe:1",
    ]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    yield from _read_jpeg(p)


def _read_jpeg(p):
    buf = b""
    try:
        while True:
            chunk = p.stdout.read(65536)
            if not chunk:
                break
            buf += chunk
            while True:
                s = buf.find(SOI)
                if s < 0:
                    buf = buf[-2:]
                    break
                e = buf.find(EOI, s + 2)
                if e < 0:
                    buf = buf[s:]
                    break
                yield buf[s:e + 2]
                buf = buf[e + 2:]
    finally:
        try:
            p.kill()
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default=None)
    ap.add_argument("--camera", action="store_true", help="实时采集模式")
    ap.add_argument("--device", default="", help="dshow 设备名，如 \"USB Video\"")
    ap.add_argument("--list", action="store_true", help="列出采集设备")
    ap.add_argument("--rtbuf", default="100M")
    ap.add_argument("--q", type=int, default=8, help="JPEG 质量 2-10，越大画质越好/带宽越高")
    ap.add_argument("--host", default="192.168.1.10")
    ap.add_argument("--usbmux", action="store_true", help="走 USB 直连（usbmuxd），不需 Wi-Fi")
    ap.add_argument("--udid", default=None)
    ap.add_argument("--audio", action="store_true", help="同时推音频（伪装手机麦克风）")
    ap.add_argument("--audio-port", type=int, default=9801)
    ap.add_argument("--audio-device", default=None, help="直接采集声卡/麦克风")
    ap.add_argument("--port", type=int, default=9800)
    ap.add_argument("--width", type=int, default=720)
    ap.add_argument("--height", type=int, default=1280)
    ap.add_argument("--fps", type=int, default=24)
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--ffmpeg", default=None)
    args = ap.parse_args()

    ff = find_ffmpeg(args.ffmpeg)
    if args.list:
        list_devices(ff)
        return
    if not args.file and not args.camera:
        print("需要 --file 或 --camera")
        return
    if args.camera and not args.device:
        print("用 --device 指定设备名（先 --list 看）")
        return
    if args.audio:
        if args.usbmux:
            print("[audio] usbmux 不支持反向连接，音频走 Wi-Fi 监听")
        import threading
        threading.Thread(target=audio_server,
                         args=(args.audio_port, ff, args.file, args.loop, args.start,
                               args.audio_device, False, args.udid),
                         daemon=True).start()

    srv = None
    if not args.usbmux:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("0.0.0.0", args.port))
        srv.listen(1)
        print(f"[sender] listening 0.0.0.0:{args.port}, waiting iPhone ...")

    while True:
        if args.usbmux:
            print(f"[sender] usbmux -> device port {args.port} ...")
            try:
                conn = usbmux_connect(args.port, args.udid)
            except Exception as e:
                print(f"[sender] {e}")
                time.sleep(2)
                return
            addr = ("usb", 0)
        else:
            conn, addr = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f"[sender] connected {addr[0] if args.usbmux else addr[0]}")
        t0 = time.time()
        n = 0
        try:
            it = (frame_iter_camera(ff, args.device, args.width, args.height, args.fps, args.rtbuf, args.q)
                  if args.camera else
                  frame_iter(ff, args.file, args.width, args.height, args.fps, args.loop, args.start, args.q))
            for jpg in it:
                conn.sendall(len(jpg).to_bytes(4, "big") + jpg)
                n += 1
                if n % 30 == 0:
                    el = time.time() - t0
                    print(f"\r[sender] {n} frames  {n/el:.1f} fps  {len(jpg)/1024:.0f} KB/frame", end="")
        except (BrokenPipeError, ConnectionResetError):
            print("\n[sender] peer closed")
        finally:
            conn.close()
        if args.camera:
            print("\n[sender] camera stream ended")
            return
        if not args.loop:
            print("\n[sender] file finished (use --loop to keep pushing)")
            return


if __name__ == "__main__":
    main()
