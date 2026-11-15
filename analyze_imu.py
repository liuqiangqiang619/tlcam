#!/usr/bin/env python3
# analyze_imu.py — 分析 dylib 导出的 tl_imu.csv，检查“画面运动 vs 合成陀螺仪”是否自洽
#
# CSV 列: t,wx,wy,wz,dx,dy
# 用法: python analyze_imu.py tl_imu.csv
#
# 想看的是：
#   1) 角速度幅值 与 光流幅值 的相关系数（应 > 0.8）
#   2) 静止段（flow≈0）时角速度是否接近 0（不能一直抖）
#   3) 有没有长时间“画面动但陀螺仪不动”的区间（会露馅）

import sys
import math


def load(path):
    rows = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        header = f.readline()
        for line in f:
            p = line.strip().split(",")
            if len(p) != 6:
                continue
            try:
                rows.append(tuple(float(x) for x in p))
            except ValueError:
                continue
    return rows


def corr(a, b):
    n = min(len(a), len(b))
    if n < 10:
        return 0.0
    ma = sum(a[:n]) / n
    mb = sum(b[:n]) / n
    sa = math.sqrt(sum((x - ma) ** 2 for x in a[:n]))
    sb = math.sqrt(sum((x - mb) ** 2 for x in b[:n]))
    if sa < 1e-9 or sb < 1e-9:
        return 0.0
    return sum((a[i] - ma) * (b[i] - mb) for i in range(n)) / (sa * sb)


def main():
    if len(sys.argv) < 2:
        print("usage: python analyze_imu.py tl_imu.csv")
        return
    rows = load(sys.argv[1])
    if not rows:
        print("no data")
        return

    gyro = [math.sqrt(r[1] ** 2 + r[2] ** 2 + r[3] ** 2) for r in rows]
    flow = [math.sqrt(r[4] ** 2 + r[5] ** 2) for r in rows]
    dx = [r[4] for r in rows]
    dy = [r[5] for r in rows]
    wx = [r[1] for r in rows]
    wy = [r[2] for r in rows]

    print(f"samples: {len(rows)}")
    print(f"gyro |w|  mean={sum(gyro)/len(gyro):.4f} rad/s  max={max(gyro):.4f}")
    print(f"flow |d|  mean={sum(flow)/len(flow):.2f} px     max={max(flow):.2f}")
    print()
    print(f"corr(|w|, |flow|) = {corr(gyro, flow):.3f}   (>0.8 算通过)")
    print(f"corr(wx, dx)      = {corr(wx, dx):.3f}")
    print(f"corr(wy, dy)      = {corr(wy, dy):.3f}")

    # 静止段检查：flow < 0.3px 时 gyro 应 < 0.05 rad/s
    still = [gyro[i] for i in range(len(rows)) if flow[i] < 0.3]
    if still:
        print(f"\nstill frames: {len(still)}  gyro mean={sum(still)/len(still):.4f} (应 < 0.05)")

    # 露馅检查：画面动但陀螺仪不动
    bad = [i for i in range(len(rows)) if flow[i] > 2.0 and gyro[i] < 0.02]
    print(f"mismatch frames (flow>2px 且 gyro<0.02): {len(bad)}")


if __name__ == "__main__":
    main()
