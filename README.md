# 抖音相机帧替换（全能签注入版）

把抖音「摄像头采集到的帧」换成 PC 推过来的画面，**摄像头仍然真实运行**，
所以设备属性、权限、`AVCaptureDevice` 全都是真的，只有像素被替换。

---

## 目录

```
Tweak/Tweak.m              注入的 dylib 源码（ObjC runtime swizzle，不依赖 Substrate）
Tweak/Makefile             Theos 工程（可选）
Tweak/entitlements.plist   重签名用
sender.py                  PC 端：读视频 → JPEG 流 → TCP
.github/workflows/build.yml GitHub Actions：在 macOS 上编译出 arm64 dylib
```

---

## 一、编译 dylib（Windows 上编不了）

iOS 的 arm64 dylib 需要 **Apple 的 iPhoneOS SDK**，Windows 没有。两条路：

### 路线 1：GitHub Actions（推荐，免费）

1. 新建一个仓库，把本目录推上去
2. Actions 会自动跑 `build-dylib`，产物在 **Artifacts → TLCam-dylib**
3. 下载 `TLCam.dylib`

### 路线 2：macOS + Xcode

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -arch arm64 -miphoneos-version-min=15.0 -isysroot "$SDK" \
      -fobjc-arc -O2 -dynamiclib \
      -framework Foundation -framework UIKit -framework AVFoundation \
      -framework CoreVideo -framework CoreImage -framework CoreGraphics \
      -install_name @executable_path/Frameworks/TLCam.dylib \
      Tweak/Tweak.m -o TLCam.dylib
```

---

## 二、注入到抖音（全能签）

前提：**必须是已解密的 IPA**（App Store 原始包是加密的，注入后启动会闪退）。

1. 全能签 → 导入「抖音 已解密 IPA」
2. 选「注入插件 / 注入动态库」→ 选 `TLCam.dylib`
3. 证书：用自己的个人证书（企业签容易掉签）
4. 签名 → 安装
5. 首次启动允许「相机 / 麦克风」

---

## 三、PC 端推流

```bash
python sender.py --file D:\video.mp4 --host 192.168.1.10 --port 9800 --loop
```

- `--host` 改成 iPhone 所在网段里 **PC 的 IP**
- 手机和 PC 必须在同一 WiFi（或用 `iproxy 9800 9800` 走 USB，此时 Tweak 里 `PC_HOST` 填 `127.0.0.1`）
- 输出固定 1080×1920、30fps、JPEG q4（约 200–400KB/帧，WiFi 完全够）

打开抖音 → 拍摄页 → 画面应该变成 PC 推的内容，但**相机指示灯仍然亮**（真机在采集，只是帧被换掉）。

---

## 四、会露馅的地方（重要）

| 检测点 | 这套方案的表现 |
|---|---|
| 相机设备属性（型号/格式/权限） | ✅ 真的 |
| 相机指示灯 / 占用状态 | ✅ 真的（相机确实开着） |
| 帧时间戳连续性 | ✅ 用 host clock 生成，30fps 稳定 |
| 画面 vs IMU 相关性 | ❌ **不匹配**：画面在动，陀螺仪是静止的 |
| 卷帘快门 / 镜头呼吸 / 对焦搜索 | ❌ 没有 |
| 传感器噪声指纹（PRNU） | ❌ PC 渲染帧的噪声谱和 CMOS 不同 |
| 注入痕迹（dyld 镜像列表 / 重签名） | ⚠️ 抖音有检测，命中可能限制开播或封设备 |

后四项里，**IMU 相关性是最致命的**——真实的手机拍屏，画面晃一下陀螺仪一定有数据；
纯注入的画面动、传感器不动，这个矛盾靠软件补不回来（除非同时伪造 IMU，工作量再翻几倍）。

---

## 五、风险

- 抖音对「重签名 + 注入」的检测一直在更新，命中通常是**设备级封禁**
- 企业证书掉签会导致 App 直接打不开
- 建议：**只在小号 + 备用机上验证**，不要在主账号上试

---

## 六、最小验证步骤（先别开播）

1. 注入后打开抖音「拍摄」页，不发布
2. PC 跑 `sender.py`，看画面是否被替换
3. 关掉 sender，画面是否回到真实相机（透传逻辑）
4. 录一段 15 秒，检查帧率是否稳定、有没有花屏
5. 全部通过再考虑开播

## 真机验证步骤（IMU 联动）

1. CI 产出 `TLCam.dylib`，注入已解密抖音 IPA，全能签签名安装（小号 + 备用机）。
2. 手机连 PC，起 `sender.py --file 素材.mp4 --host <PC_IP>`，抖音开直播预览。
3. 看日志（Console.app 过滤 `[TL]`）：
   - `[TL] motion hook active` — hook 装上了
   - `[TL] motion KVC ok` — CMDeviceMotion 可写（若显示 `KVC path mismatch`，看紧邻的 `[TL] ivar` 行，把真实 ivar 名补进 `SetNum` 的键列表）
   - `[TL] imu wx=... flow=(...)` — 每 2 秒一行，晃动手机时 wx/wy 与 flow 应同向变化
4. 录 30 秒「静止 10s → 左右晃 10s → 上下晃 10s」，取 `tl_imu.csv`（`TL_DUMP=1` 时写在 App 沙盒 tmp）跑：

   ```
   python analyze_imu.py tl_imu.csv
   ```

   目标：`corr(|w|, |flow|) > 0.8`，静止段 gyro 均值 < 0.05，`mismatch` 接近 0。

5. 标定焦距：把手机水平匀速转 90°（1.57 rad），用日志里的 wx 积分出 `integrated`，然后
   `g_focalPx *= integrated / 1.57`（或调用 `TLCalibrateFocal(1.57, integrated)`），重编译。
6. 对着真实陀螺仪数据（另一台手机 Simultaneous 录）比对相位差，若陀螺仪明显滞后，把 `Tick` 的 0.01 改成 0.005 并降低光流低通系数（0.3 → 0.45）。

## 推流方式（Wi-Fi / USB 二选一）

```bash
# 1) Wi-Fi：PC 监听，手机连过来
python sender.py --file 素材.mp4 --loop --host 0.0.0.0

# 2) USB：走 usbmuxd（iTunes/Apple Mobile Device Service 在跑即可，不需要 iproxy）
python sender.py --usbmux --port 9800 --file 素材.mp4 --loop

# 3) 实时采集（摄像头 / 采集卡）
python sender.py --list --ffmpeg "D:\TianLePlayer\_sdk\ffmpeg-master-latest-win64-lgpl-shared\bin\ffmpeg.exe"
python sender.py --camera --device "Logitech HD Webcam C270" --usbmux --port 9800
python sender.py --camera --device "USB Video" --width 1080 --height 1920 --fps 30 --q 6
```

注意事项：

- `--usbmux` 直接连设备端口（默认 9800，要和 dylib 里 `ReceiverThread` 的端口一致）
- 默认 720×1280 / 24fps / q8 ≈ 18 Mbps；`--q` 越小画质越好带宽越高（2–10）
- 手机没插线时 `usbmux_connect` 会报「usbmuxd 没有发现设备」
- USB 链路比 Wi-Fi 稳，建议正式直播用 USB

## 图像层面的“相机不完美”（CameraImperfections）

每帧渲染前对 CIImage 做三层处理（`Tweak.m`，函数 `CameraImperfections`）：

1. **镜头畸变**：`CIBumpDistortion`，中心 0.035 强度、半径 0.72×宽 → 近似桶形
2. **卷帘快门**：按上一帧光流 `dx/dy` 算整帧剪切（`shear = -dx*0.00045`，钳 ±1%），叠加 7.1Hz 微抖动 → 快速横移时画面“斜一下”
3. **对焦呼吸**：0.77Hz + 2.31Hz 双正弦缩放（±0.3%），先放大 1.5% 防止剪切后露边
4. 最后 0.35px 高斯，软化边缘

强度都在函数开头几行，按机型/镜头改数值即可。
