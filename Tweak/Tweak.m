// Tweak.m — 把 AVCaptureVideoDataOutput 的帧替换成 PC 推来的画面
// 编译：Theos（macOS）或 GitHub Actions macOS runner，产物 Tweak.dylib (arm64)
// 注入：全能签 → 已解密抖音 IPA → 注入本 dylib → 重签名安装
//
// 设计要点：
//  1) 摄像头仍然真实运行（Device/Format/权限全部为真），只把“帧”换掉
//  2) 用 ObjC runtime 交换方法，不依赖 CydiaSubstrate（免越狱重签环境可用）
//  3) 没有收到 PC 帧时，原样透传相机帧（方便排查）

#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <Vision/Vision.h>
#import <pthread.h>
#import <string.h>
#import <dispatch/dispatch.h>
#import <netinet/tcp.h>
#import <stdlib.h>
#import <time.h>
#import <VideoToolbox/VideoToolbox.h>

// 由 IMUSynth.m 提供
extern void TLUpdateMotionFromFlow(double dxPix, double dyPix, double dt);
extern void TLGetMotionState(double* wx, double* wy, double* dx, double* dy);

// ---------------- 配置 ----------------
#define PC_HOST   "192.168.10.2"   // 改成你 PC 的局域网 IP（或用 iproxy 时填 127.0.0.1）
#define PC_PORT   9800
#define OUT_W     1080
#define OUT_H     1920
#define OUT_FPS   30

static id              g_realDelegate = nil;
static id              g_realAudioDelegate = nil;
static dispatch_queue_t g_realQueue   = nil;
static id              g_proxy        = nil;

#define TL_ENABLE_AUDIO 1
#define TL_ENABLE_IMU   0

static CVPixelBufferRef g_latest = NULL;      // 最新一帧（420f）
static uint64_t         g_latestSeq = 0;      // 帧序号，用来判断“有没有新帧”
static uint64_t         g_sentSeq = 0;
static CIImage* CameraImperfections(CIImage* in, double dx, double dy);

static pthread_mutex_t  g_lock = PTHREAD_MUTEX_INITIALIZER;

static CIContext*       g_ci = nil;
static CVPixelBufferPoolRef g_pool = NULL;

// ---------------- 解码：JPEG -> 420f CVPixelBuffer ----------------
static void EnsurePool(void) {
    if (g_pool) return;
    NSDictionary* attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey:  @(OUT_W),
        (id)kCVPixelBufferHeightKey: @(OUT_H),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &g_pool);
}

static CVPixelBufferRef DecodeJPEG(const void* data, size_t len) {
    CFDataRef cf = CFDataCreate(kCFAllocatorDefault, (const UInt8*)data, (CFIndex)len);
    if (!cf) return NULL;
    CGImageSourceRef src = CGImageSourceCreateWithData(cf, NULL);
    CFRelease(cf);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return NULL;

    EnsurePool();
    if (!g_pool) { CGImageRelease(img); return NULL; }

    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, g_pool, &pb) != kCVReturnSuccess || !pb) {
        CGImageRelease(img);
        return NULL;
    }
    if (!g_ci) g_ci = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
    CIImage* ci = [CIImage imageWithCGImage:img];
    // 等比铺满 1080x1920（PC 端已按 9:16 出图，这里只做兜底缩放）
    CGFloat sx = (CGFloat)OUT_W / ci.extent.size.width;
    CGFloat sy = (CGFloat)OUT_H / ci.extent.size.height;
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    double mwx = 0, mwy = 0, mdx = 0, mdy = 0;
    TLGetMotionState(&mwx, &mwy, &mdx, &mdy);
    #if TL_ENABLE_IMPERFECT
        ci = CameraImperfections(ci, mdx, mdy);
#endif
    [g_ci render:ci toCVPixelBuffer:pb bounds:CGRectMake(0, 0, OUT_W, OUT_H) colorSpace:CGColorSpaceCreateDeviceRGB()];
    CGImageRelease(img);
    return pb;
}


// ---------------- 相机不完美：卷帘快门 + 镜头畸变 + 对焦呼吸 ----------------
// 输入是已经缩放到 1080x1920 的图；dx/dy 是上一帧光流（全分辨率像素）
static CIImage* CameraImperfections(CIImage* img, double dx, double dy) {
    double t = CACurrentMediaTime();
    CGFloat W = img.extent.size.width, H = img.extent.size.height;

    // 卷帘：水平运动越快，上下行错位越明显（方向随运动反向）
    double shear  = -dx * 0.00045 + 0.0012 * sin(t * 7.1);
    shear = fmax(-0.010, fmin(0.010, shear));
    double vshear = -dy * 0.00015 + 0.0006 * sin(t * 5.3 + 0.7);
    vshear = fmax(-0.004, fmin(0.004, vshear));

    // 对焦呼吸：极慢的缩放脉动 + 一点点随机
    double breath = 1.0 + 0.0032 * sin(t * 0.77) + 0.0013 * sin(t * 2.31 + 1.2) + 0.0006 * sin(t * 11.7);

    CIImage* o = img;

    // 桶形畸变（近似）：CIBumpDistortion 正 scale 向外鼓
    CIFilter* bump = [CIFilter filterWithName:@"CIBumpDistortion"];
    if (bump) {
        [bump setValue:o forKey:kCIInputImageKey];
        [bump setValue:[CIVector vectorWithX:W * 0.5 Y:H * 0.5] forKey:@"inputCenter"];
        [bump setValue:@(W * 0.72) forKey:@"inputRadius"];
        [bump setValue:@(0.035) forKey:@"inputScale"];
        if (bump.outputImage) o = bump.outputImage;
    }

    // 先放大 1.5%，保证剪切后四边不露黑
    CGAffineTransform tr = CGAffineTransformMakeTranslation(-W * 0.5, -H * 0.5);
    tr = CGAffineTransformConcat(tr, CGAffineTransformMake(1.0, vshear, shear, 1.0, 0, 0));
    tr = CGAffineTransformConcat(tr, CGAffineTransformMakeScale(breath * 1.015, breath * 1.015));
    tr = CGAffineTransformConcat(tr, CGAffineTransformMakeTranslation(W * 0.5, H * 0.5));
    o = [o imageByApplyingTransform:tr];

    // 边缘轻微色散/软化：一次小半径高斯，模拟镜头边缘
    CIFilter* blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    if (blur) {
        [blur setValue:o forKey:kCIInputImageKey];
        [blur setValue:@(0.18) forKey:@"inputRadius"];
        if (blur.outputImage) o = blur.outputImage;
    }
    return o;
}

// ---------------- USB 直连：手机监听 9800，PC 主动连（经 usbmux）----------------
// 传输：12 字节头 {type u8, flags u8, len u16 BE, seq u32 BE, pts u32 BE} + 一个完整 NAL
static VTDecompressionSessionRef g_vt = NULL;
static CMVideoFormatDescriptionRef g_vtFmt = NULL;
static NSData* g_sps = nil;
static NSData* g_pps = nil;
static int g_vtFrames = 0;

static BOOL ReadFull(int s, void* buf, size_t n);

static void VTReset(void) {
    if (g_vt) { VTDecompressionSessionInvalidate(g_vt); CFRelease(g_vt); g_vt = NULL; }
    if (g_vtFmt) { CFRelease(g_vtFmt); g_vtFmt = NULL; }
}

static uint64_t nowMs_(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)(ts.tv_nsec / 1000000);
}
static uint64_t g_feedMs[128];
static volatile int g_feedIdx = 0, g_outIdx = 0;
static volatile int g_fedFrames = 0;
static long long g_lagMax = 0, g_lagSum = 0; static int g_lagN = 0;
static void VTDecCallback(void* refCon, void* srcFrame, OSStatus status,
                          VTDecodeInfoFlags flags, CVImageBufferRef image,
                          CMTime pts, CMTime dur) {
    if (status != noErr || !image) return;
    CVPixelBufferRef pb = (CVPixelBufferRef)CVBufferRetain(image);
    pthread_mutex_lock(&g_lock);
    if (g_latest) CVPixelBufferRelease(g_latest);
    g_latest = pb;
    g_latestSeq++;
    pthread_mutex_unlock(&g_lock);
    g_vtFrames++;
    {
        int oi = g_outIdx % 128;
        uint64_t fed = g_feedMs[oi];
        if (fed) {
            long long lag = (long long)(nowMs_() - fed);
            if (lag >= 0 && lag < 5000) { g_lagSum += lag; g_lagN++; if (lag > g_lagMax) g_lagMax = lag; }
        }
        g_outIdx++;
    }
}

static void VTEnsureSession(void) {
    if (g_vt) return;
    if (g_sps.length < 4 || g_pps.length < 4) return;
    const uint8_t* ps[2] = { (const uint8_t*)g_sps.bytes, (const uint8_t*)g_pps.bytes };
    size_t pl[2] = { g_sps.length, g_pps.length };
    if (CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, ps, pl, 4, &g_vtFmt) != noErr) {
        NSLog(@"[TL] h264 fmt desc failed sps=%zu pps=%zu", g_sps.length, g_pps.length);
        return;
    }
    NSDictionary* dst = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    VTDecompressionOutputCallbackRecord cb = {0};
    cb.decompressionOutputCallback = VTDecCallback;
    cb.decompressionOutputRefCon = NULL;
    OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, g_vtFmt, NULL,
                                               (__bridge CFDictionaryRef)dst, &cb, &g_vt);
    if (st != noErr) {
        NSLog(@"[TL] vt session failed %d", (int)st);
        g_vt = NULL;
        return;
    }
    VTSessionSetProperty((VTSessionRef)g_vt, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    NSLog(@"[TL] h264 decoder ready %dx%d realtime=1", (int)CMVideoFormatDescriptionGetDimensions(g_vtFmt).width,
          (int)CMVideoFormatDescriptionGetDimensions(g_vtFmt).height);
}

// ---------------- 真实采集时间戳 ----------------
// 真机摄像头的 PTS 来自硬件时钟，帧间隔在 1/30 秒附近抖动、偶发相位跳变，
// 绝不会像文件回放那样每帧都是精确的 33.3333ms。
// 原版给的是 CMTimeInvalid（等于把时间戳这条破绽白送出去），这里改成带抖动的真时钟。
static double   g_ptsLast    = 0;
static double   g_ptsBias    = 0;
static double   g_ptsBase    = -1;
static uint64_t g_ptsJumpAt  = 0;

static CMTime NextFramePTS(void) {
    double   raw = CACurrentMediaTime();
    if (g_ptsBase < 0) {           // 每路连接以首帧为 0 点，PTS 从 0 起算（会话语义）
        g_ptsBase   = raw;
        g_ptsLast   = 0;
        g_ptsBias   = 0;
        g_ptsJumpAt = 0;
    }
    double   now = raw - g_ptsBase;
    uint64_t ms  = nowMs_();
    if (ms >= g_ptsJumpAt) {
        // 每 0.9~2.4 秒一次"重对时"：模拟 AE/AF 微调造成的相位跳变（±4.2ms）
        g_ptsBias   = ((double)(rand() % 2001) / 1000.0 - 1.0) * 0.0042;
        g_ptsJumpAt = ms + 900 + (uint32_t)(rand() % 1500);
    } else {
        // 帧间随机游走：真实抖动时序是相关的，不是独立白噪声
        g_ptsBias = g_ptsBias * 0.90 + ((double)(rand() % 2001) / 1000.0 - 1.0) * 0.0007;
    }
    double pts = now + g_ptsBias;
    if (pts <= g_ptsLast) pts = g_ptsLast + 0.0004;   // 保证严格单调，至少前进 0.4ms
    g_ptsLast = pts;
    return CMTimeMakeWithSeconds(pts, 1000000);       // 微秒时基，足够表达亚毫秒抖动
}

static void VTFeedNAL(const uint8_t* p, size_t n) {
    if (n < 4) return;                 // PPS 只有 4 字节，之前卡在 <5 被丢掉
    int type = p[0] & 0x1f;
    if (type == 7) { g_sps = [NSData dataWithBytes:p length:n]; VTReset(); VTEnsureSession(); return; }
    if (type == 8) { g_pps = [NSData dataWithBytes:p length:n]; VTReset(); VTEnsureSession(); return; }
    if (type != 1 && type != 5) return;
    if (!g_vt) VTEnsureSession();
    if (!g_vt) return;

    size_t total = n + 4;
    uint8_t* buf = (uint8_t*)malloc(total);
    if (!buf) return;
    uint32_t be = htonl((uint32_t)n);
    memcpy(buf, &be, 4);
    memcpy(buf + 4, p, n);

    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, buf, total, kCFAllocatorMalloc,
                                           NULL, 0, total, 0, &bb) != noErr) { free(buf); return; }
    CMSampleBufferRef sb = NULL;
    size_t sz = total;
    CMSampleTimingInfo t = { CMTimeMake(1, 30), NextFramePTS(), kCMTimeInvalid };
    if (CMSampleBufferCreateReady(kCFAllocatorDefault, bb, g_vtFmt, 1, 1, &t, 1, &sz, &sb) == noErr && sb) {
        g_feedMs[g_feedIdx % 128] = nowMs_();
        g_feedIdx++; g_fedFrames++;
        VTDecompressionSessionDecodeFrame(g_vt, sb, 0, NULL, 0);
        CFRelease(sb);
    }
    CFRelease(bb);
}

static void* USBVideoThread(void* arg) {
    @autoreleasepool {
        while (1) {
            int ls = socket(AF_INET, SOCK_STREAM, 0);
            if (ls < 0) { usleep(1000 * 1000); continue; }
            int one = 1;
            setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            struct sockaddr_in a = {0};
            a.sin_family = AF_INET;
            a.sin_port = htons(PC_PORT);
            a.sin_addr.s_addr = INADDR_ANY;
            if (bind(ls, (struct sockaddr*)&a, sizeof(a)) != 0) {
                NSLog(@"[TL] bind %d failed", PC_PORT);
                close(ls);
                usleep(1000 * 1000);
                continue;
            }
            listen(ls, 8);
            NSLog(@"[TL] usb video listen %d", PC_PORT);
            while (1) {
                int c = accept(ls, NULL, NULL);
                if (c < 0) { usleep(200 * 1000); continue; }
                int nd = 1;
                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof(nd));
                setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &nd, sizeof(nd));
                struct timeval tv = { 3, 0 };
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                NSLog(@"[TL] usb video connected");
                g_ptsBase = -1;   // 新连接：PTS 基准归零，重新开始抖动序列
                srand((unsigned)time(NULL) ^ (unsigned)getpid());   // 每次开播抖动序列都不同
                unsigned long long bytes = 0; int nals = 0; int vidErr = 0;
                CFAbsoluteTime tStat = CFAbsoluteTimeGetCurrent();
                while (1) {
                    uint8_t h[16];
                    if (!ReadFull(c, h, 16)) { vidErr = 1; break; }
                    uint32_t len = ((uint32_t)h[0] << 24) | ((uint32_t)h[1] << 16) | ((uint32_t)h[2] << 8) | (uint32_t)h[3];
                    if (len < 4 || len > 4 * 1024 * 1024) { NSLog(@"[TL] bad nal len %u", len); vidErr = 2; break; }
                    uint8_t* d = (uint8_t*)malloc(len);
                    if (!d) { vidErr = 3; break; }
                    if (!ReadFull(c, d, len)) { free(d); vidErr = 4; break; }
                    bytes += len; nals++;
                    @try { VTFeedNAL(d, len); } @catch (NSException* e) { NSLog(@"[TL] nal exception %@", e); }
                    free(d);
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (now - tStat >= 2.0) {
                        NSLog(@"[TL] vid rx bytes=%llu nals=%d vtFrames=%d lag=%lldms backlog=%d sps=%d pps=%d", bytes, nals, (int)g_vtFrames,
                              (g_lagN ? (long long)(g_lagSum / g_lagN) : 0), (int)(g_fedFrames - g_outIdx), (int)g_sps.length, (int)g_pps.length);
                        g_lagSum = 0; g_lagN = 0;
                        tStat = now;
                    }
                }
                close(c);
                NSLog(@"[TL] usb video closed bytes=%llu nals=%d vtFrames=%d err=%d", bytes, nals, (int)g_vtFrames, vidErr);
            }
        }
    }
    return NULL;
}

// ---------------- 接收线程：TCP 收 JPEG ----------------
static int ConnectPC(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(PC_PORT);
    a.sin_addr.s_addr = inet_addr(PC_HOST);
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) != 0) { close(s); return -1; }
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return s;
}

static BOOL ReadFull(int s, void* buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(s, (char*)buf + got, n - got, 0);
        if (r <= 0) return NO;
        got += (size_t)r;
    }
    return YES;
}

static void* ReceiverThread(void* arg) {
    @autoreleasepool {
        int s = -1;
        while (1) {
            if (s < 0) {
                s = ConnectPC();
                if (s < 0) { usleep(500 * 1000); continue; }
                NSLog(@"[TL] connected to %s:%d", PC_HOST, PC_PORT);
            }
            uint32_t beLen = 0;
            if (!ReadFull(s, &beLen, 4)) { close(s); s = -1; continue; }
            uint32_t len = ntohl(beLen);
            if (len < 128 || len > 8 * 1024 * 1024) { close(s); s = -1; continue; }
            NSMutableData* d = [NSMutableData dataWithLength:len];
            if (!ReadFull(s, d.mutableBytes, len)) { close(s); s = -1; continue; }

            CVPixelBufferRef pb = DecodeJPEG(d.bytes, len);
            if (!pb) continue;
            pthread_mutex_lock(&g_lock);
            if (g_latest) CVPixelBufferRelease(g_latest);
            g_latest = pb;              // 交给代理方法消费
            g_latestSeq++;
            pthread_mutex_unlock(&g_lock);
        }
    }
    return NULL;
}

// ---------------- 光流：估算相邻帧平均位移 ----------------
#define FLOW_W 270
#define FLOW_H 480

static CVPixelBufferRef g_prevFlow = NULL;
static CFTimeInterval     g_prevFlowT = 0;
static dispatch_queue_t   g_flowQ = NULL;
static CIContext*         g_flowCI = nil;

static CVPixelBufferRef DownscaleForFlow(CVPixelBufferRef src) {
    if (!g_flowCI) g_flowCI = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
    NSDictionary* attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey:  @(FLOW_W),
        (id)kCVPixelBufferHeightKey: @(FLOW_H),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, FLOW_W, FLOW_H,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst)
        return NULL;
    CIImage* ci = [CIImage imageWithCVPixelBuffer:src];
    CGFloat sx = (CGFloat)FLOW_W / ci.extent.size.width;
    CGFloat sy = (CGFloat)FLOW_H / ci.extent.size.height;
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    [g_flowCI render:ci toCVPixelBuffer:dst bounds:CGRectMake(0, 0, FLOW_W, FLOW_H)
          colorSpace:CGColorSpaceCreateDeviceRGB()];
    return dst;
}

static void ProcessFlow(CVPixelBufferRef cur) {
    if (!cur) return;
    CVPixelBufferRef small = DownscaleForFlow(cur);
    if (!small) return;

    if (g_prevFlow) {
        VNGenerateOpticalFlowRequest* req =
            [[VNGenerateOpticalFlowRequest alloc] initWithTargetedCVPixelBuffer:small options:@{}];
        req.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float;
        req.computationAccuracy = VNGenerateOpticalFlowRequestComputationAccuracyLow;

        VNImageRequestHandler* h = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:g_prevFlow options:@{}];
        NSError* err = nil;
        [h performRequests:@[req] error:&err];
        VNPixelBufferObservation* obs = req.results.firstObject;

        CFTimeInterval now = CACurrentMediaTime();
        double dt = g_prevFlowT > 0 ? (now - g_prevFlowT) : (1.0 / 30.0);
        g_prevFlowT = now;

        if (obs.pixelBuffer) {
            CVPixelBufferRef f = obs.pixelBuffer;
            CVPixelBufferLockBaseAddress(f, kCVPixelBufferLock_ReadOnly);
            size_t bpr = CVPixelBufferGetBytesPerRow(f);
            size_t w = CVPixelBufferGetWidth(f), hh = CVPixelBufferGetHeight(f);
            uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(f);
            double sdx = 0, sdy = 0; int cnt = 0;
            for (size_t y = 0; y < hh; y += 8) {
                float* row = (float*)(base + y * bpr);
                for (size_t x = 0; x < w; x += 8) {
                    sdx += row[x * 2];
                    sdy += row[x * 2 + 1];
                    cnt++;
                }
            }
            CVPixelBufferUnlockBaseAddress(f, kCVPixelBufferLock_ReadOnly);
            if (cnt > 0) {
                // 小图位移 → 原图位移
                double k = (double)OUT_W / (double)w;
                TLUpdateMotionFromFlow(sdx / cnt * k, sdy / cnt * k, dt);
            }
        }
    }

    if (g_prevFlow) CVPixelBufferRelease(g_prevFlow);
    g_prevFlow = small;   // 保留到下一帧
    CVPixelBufferRetain(g_prevFlow);
}

static void ScheduleFlow(CVPixelBufferRef cur) {
    if (!g_flowQ) g_flowQ = dispatch_queue_create("tl.flow", DISPATCH_QUEUE_SERIAL);
    CVPixelBufferRetain(cur);
    dispatch_async(g_flowQ, ^{
        @autoreleasepool {
            ProcessFlow(cur);
            CVPixelBufferRelease(cur);
        }
    });
}


// ---------------- 音频：把 PC 的 PCM 伪装成手机麦克风 ----------------
#import <AudioToolbox/AudioToolbox.h>

#define ARING_BYTES (48000 * 2 * 2 * 2)   // 约 2 秒
static uint8_t  g_abuf[ARING_BYTES];
static size_t   g_ard = 0, g_awr = 0;
static pthread_mutex_t g_alock = PTHREAD_MUTEX_INITIALIZER;
static int      g_audioPort = 9801;
static int      g_audioGot = 0;
static int      g_audioEver = 0;

static void AudioPush(const uint8_t* d, size_t n) {
    pthread_mutex_lock(&g_alock);
    for (size_t i = 0; i < n; ++i) {
        g_abuf[g_awr] = d[i];
        g_awr = (g_awr + 1) % ARING_BYTES;
        if (g_awr == g_ard) g_ard = (g_ard + 1) % ARING_BYTES;   // 覆盖旧数据
    }
    g_audioGot++;
    g_audioEver = 1;
    pthread_mutex_unlock(&g_alock);
}

static size_t AudioPop(void* out, size_t need) {
    size_t got = 0;
    pthread_mutex_lock(&g_alock);
    while (got < need && g_ard != g_awr) {
        ((uint8_t*)out)[got++] = g_abuf[g_ard];
        g_ard = (g_ard + 1) % ARING_BYTES;
    }
    pthread_mutex_unlock(&g_alock);
    return got;
}

static int ConnectPC2(int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = inet_addr(PC_HOST);
    if (connect(s, (struct sockaddr*)&a, sizeof(a)) != 0) { close(s); return -1; }
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    return s;
}

static void* AudioThread(void* arg) {
    @autoreleasepool {
        while (1) {
            int ls = socket(AF_INET, SOCK_STREAM, 0);
            if (ls < 0) { usleep(1000 * 1000); continue; }
            int one = 1;
            setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            struct sockaddr_in a = {0};
            a.sin_family = AF_INET;
            a.sin_port = htons(g_audioPort);
            a.sin_addr.s_addr = INADDR_ANY;
            if (bind(ls, (struct sockaddr*)&a, sizeof(a)) != 0) {
                close(ls); usleep(1000 * 1000); continue;
            }
            listen(ls, 8);
            NSLog(@"[TL] usb audio listen %d", g_audioPort);
            while (1) {
                int c = accept(ls, NULL, NULL);
                if (c < 0) { usleep(200 * 1000); continue; }
                int nd = 1;
                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof(nd));
                setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &nd, sizeof(nd));
                struct timeval tv = { 3, 0 };
                setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
                NSLog(@"[TL] usb audio connected");
                unsigned long long abytes = 0; int blocks = 0; int audErr = 0;
                CFAbsoluteTime atStat = CFAbsoluteTimeGetCurrent();
                while (1) {
                    uint8_t h[16];
                    if (!ReadFull(c, h, 16)) { audErr = 1; break; }
                    uint32_t len = ((uint32_t)h[0] << 24) | ((uint32_t)h[1] << 16) | ((uint32_t)h[2] << 8) | (uint32_t)h[3];
                    if (len < 16 || len > 65536) { NSLog(@"[TL] bad pcm len %u", len); audErr = 2; break; }
                    uint8_t* d = (uint8_t*)malloc(len);
                    if (!d) { audErr = 3; break; }
                    if (!ReadFull(c, d, len)) { free(d); audErr = 4; break; }
                    AudioPush(d, len);
                    free(d);
                    abytes += len; blocks++;
                    CFAbsoluteTime anow = CFAbsoluteTimeGetCurrent();
                    if (anow - atStat >= 2.0) {
                        NSLog(@"[TL] aud rx bytes=%llu blocks=%d", abytes, blocks);
                        atStat = anow;
                    }
                }
                close(c);
                NSLog(@"[TL] usb audio closed bytes=%llu blocks=%d err=%d", abytes, blocks, audErr);
            }
        }
    }
    return NULL;
}

// 用 ring 里的 PCM 造一个 CMSampleBuffer
static CMSampleBufferRef MakeAudioBuffer(size_t frames) {
    size_t bytes = frames * 2 * 2;
    void* pcm = malloc(bytes);
    size_t got = AudioPop(pcm, bytes);
    if (got < bytes) { free(pcm); return NULL; }

    AudioStreamBasicDescription asbd = {0};
    asbd.mSampleRate = 48000;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    asbd.mFramesPerPacket = 1;
    asbd.mChannelsPerFrame = 2;
    asbd.mBitsPerChannel = 16;
    asbd.mBytesPerFrame = 4;
    asbd.mBytesPerPacket = 4;

    CMFormatDescriptionRef fmt = NULL;
    if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, NULL, 0, NULL, NULL, &fmt) != noErr) {
        free(pcm);
        return NULL;
    }
    CMBlockBufferRef bb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, pcm, bytes, kCFAllocatorDefault,
                                          NULL, 0, bytes, 0, &bb) != kCMBlockBufferNoErr) {
        free(pcm); CFRelease(fmt); return NULL;
    }
    CMSampleBufferRef sb = NULL;
    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());
    CMSampleTimingInfo timing = { CMTimeMake(1, 48000), pts, pts };
    OSStatus st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, fmt, (CMItemCount)frames, 1, &timing, 0, NULL, &sb);
    CFRelease(bb);
    CFRelease(fmt);
    if (st != noErr) return NULL;
    return sb;
}

// 把 PC 的 PCM 写进相机自己的 audio buffer（不新建 sample buffer，最不容易崩）
static uint64_t g_paintOk = 0, g_paintFail = 0, g_audioUnder = 0;

static BOOL PaintAudioIntoBuffer(CMSampleBufferRef sb) {
    if (!sb) return NO;
    if (!g_audioEver) return NO;                         // 还没有收到过 PC 音频
    CMFormatDescriptionRef fdesc = CMSampleBufferGetFormatDescription(sb);
    if (!fdesc) return NO;
    const AudioStreamBasicDescription* asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fdesc);
    if (!asbd || asbd->mSampleRate < 8000 || asbd->mBytesPerFrame == 0) return NO;

    size_t ablSize = 0;
    if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, &ablSize, NULL, 0, NULL, NULL, 0, NULL) != noErr || ablSize == 0)
        return NO;
    AudioBufferList* abl = (AudioBufferList*)malloc(ablSize);
    if (!abl) return NO;
    CMBlockBufferRef bb = NULL;
    OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sb, &ablSize, abl, ablSize, NULL, NULL,
        kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &bb);
    BOOL ok = NO;
    if (st == noErr && abl->mNumberBuffers > 0) {
        BOOL isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        BOOL nonInt  = (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
        UInt32 chTotal = asbd->mChannelsPerFrame ? asbd->mChannelsPerFrame : 1;
        UInt32 chInBuf = nonInt ? 1 : chTotal;
        UInt32 bps = asbd->mBitsPerChannel / 8;
        AudioBuffer* b0 = &abl->mBuffers[0];
        if (bps && b0->mData && chInBuf) {
            UInt32 frames = (UInt32)(b0->mDataByteSize / (bps * chInBuf));
            if (frames > 0 && frames <= 16384) {
                size_t need = (size_t)frames * 4;
                int16_t* src = (int16_t*)malloc(need);
                if (src) {
                    size_t got = AudioPop(src, need);
                    size_t have = got / 4;
                    if (have < frames) g_audioUnder += (frames - have);
                    {
                        for (UInt32 f = 0; f < frames; ++f) {
                            float l = 0.0f, r = 0.0f;
                            if (f < have) { l = src[f * 2] / 32768.0f; r = src[f * 2 + 1] / 32768.0f; }
                            if (nonInt) {
                                for (UInt32 bi = 0; bi < abl->mNumberBuffers; ++bi) {
                                    AudioBuffer* b = &abl->mBuffers[bi];
                                    if (!b->mData || (f + 1) * bps > b->mDataByteSize) continue;
                                    float v = (bi == 0) ? l : (chTotal > 1 ? r : (l + r) * 0.5f);
                                    if (isFloat) ((float*)b->mData)[f] = v;
                                    else ((int16_t*)b->mData)[f] = (int16_t)(v * 32767.0f);
                                }
                            } else {
                                AudioBuffer* b = &abl->mBuffers[0];
                                if (b->mData && (f + 1) * bps * chInBuf <= b->mDataByteSize) {
                                    if (isFloat) {
                                        float* p = (float*)b->mData;
                                        p[f * 2] = l;
                                        if (chTotal > 1) p[f * 2 + 1] = r;
                                    } else {
                                        int16_t* p = (int16_t*)b->mData;
                                        p[f * 2] = (int16_t)(l * 32767.0f);
                                        if (chTotal > 1) p[f * 2 + 1] = (int16_t)(r * 32767.0f);
                                    }
                                }
                            }
                        }
                        ok = YES;
                    }
                    free(src);
                }
            }
        }
    }
    if (bb) CFRelease(bb);
    free(abl);
    if (ok) { if ((++g_paintOk % 200) == 1) NSLog(@"[TL] audio painted=%llu under=%llu", g_paintOk, g_audioUnder); }
    else { if ((++g_paintFail % 200) == 1) NSLog(@"[TL] audio paint skip=%llu", g_paintFail); }
    return ok;
}

@interface TLAudioProxy : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate>
@end

@implementation TLAudioProxy
- (void)captureOutput:(AVCaptureOutput*)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection*)connection {
#if !TL_ENABLE_AUDIO
    if (g_realAudioDelegate) [g_realAudioDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    return;
#endif
    @try {
        if (PaintAudioIntoBuffer(sampleBuffer)) {
            if (g_realAudioDelegate) [g_realAudioDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            return;
        }
    } @catch (NSException* e) {
        NSLog(@"[TL] audio paint exception %@", e);
    }
    if (g_realAudioDelegate) [g_realAudioDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
}
@end


// ---------------- 备用路径：AVAudioEngine 的麦克风 tap ----------------
// 有些抖音版本不用 AVCaptureAudioDataOutput，而是 AVAudioEngine.inputNode installTapOnBus:
static void (*orig_tap)(id, SEL, AVAudioNodeBus, AVAudioFrameCount, AVAudioFormat*, AVAudioNodeTapBlock) = NULL;
static AVAudioFormat* g_tapFmt = nil;

// 把 ring 里的 s16 PCM 填进 float32 的 AVAudioPCMBuffer
static void FillTapBuffer(AVAudioPCMBuffer* b) {
    if (!b) return;
    AVAudioFrameCount frames = b.frameLength;
    if (frames == 0) return;
    float* L = b.floatChannelData ? b.floatChannelData[0] : NULL;
    float* R = (b.format.channelCount > 1 && b.floatChannelData) ? b.floatChannelData[1] : L;
    if (!L) return;
    int16_t tmp[2048 * 2];
    size_t need = (size_t)frames * 2 * 2;
    if (need > sizeof(tmp)) need = sizeof(tmp);
    size_t got = AudioPop(tmp, need);
    size_t n = got / 4;                      // 每帧 4 字节
    for (size_t i = 0; i < frames; ++i) {
        float l = 0.f, r = 0.f;
        if (i < n) { l = tmp[i * 2] / 32768.0f; r = tmp[i * 2 + 1] / 32768.0f; }
        L[i] = l;
        if (R) R[i] = r;
    }
}

static void my_tap(id self, SEL _cmd, AVAudioNodeBus bus, AVAudioFrameCount bufSize,
                   AVAudioFormat* fmt, AVAudioNodeTapBlock block) {
    g_tapFmt = fmt;
    NSLog(@"[TL] audio tap install bus=%u fmt=%.0fHz ch=%u", (unsigned)bus,
          fmt ? fmt.sampleRate : 0, fmt ? (unsigned)fmt.channelCount : 0);
    AVAudioNodeTapBlock wrap = ^(AVAudioPCMBuffer* buffer, AVAudioTime* when) {
        if (buffer && buffer.format.commonFormat == AVAudioPCMFormatFloat32) {
            FillTapBuffer(buffer);
        }
        if (block) block(buffer, when);
    };
    if (orig_tap) orig_tap(self, _cmd, bus, bufSize, fmt, wrap);
}

// ---------------- 代理：把 PC 帧交给抖音 ----------------
// ---- PC 帧尺寸与相机不一致时，用 CoreImage 缩放到相机尺寸 ----
static CIContext* g_ciCtx = nil;
static CVPixelBufferPoolRef g_scalePool = NULL;
static size_t g_scalePoolW = 0, g_scalePoolH = 0;


// 把 src 直接写进 dst 的像素内存（支持 420 双平面 与 BGRA 单平面）
static BOOL CopyIntoPixelBuffer(CVPixelBufferRef dst, CVPixelBufferRef src) {
    if (!dst || !src) return NO;
    size_t dn = CVPixelBufferGetPlaneCount(dst), sn = CVPixelBufferGetPlaneCount(src);
    if (dn != sn) return NO;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(dst, 0);
        return NO;
    }
    BOOL ok = YES;
    if (dn == 0) {
        size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
        size_t sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src);
        size_t bpp = 4;
        OSType fd = CVPixelBufferGetPixelFormatType(dst);
        if (fd == kCVPixelFormatType_32BGRA || fd == kCVPixelFormatType_32ARGB) bpp = 4;
        if (dw != sw || dh != sh) ok = NO;
        uint8_t* dp = (uint8_t*)CVPixelBufferGetBaseAddress(dst);
        const uint8_t* sp = (const uint8_t*)CVPixelBufferGetBaseAddress(src);
        size_t ds = CVPixelBufferGetBytesPerRow(dst), ss = CVPixelBufferGetBytesPerRow(src);
        if (!dp || !sp) ok = NO;
        size_t rowBytes = ds < ss ? ds : ss;
        for (size_t y = 0; ok && y < dh; y++) memcpy(dp + y * ds, sp + y * ss, rowBytes);
    } else {
        for (size_t pl = 0; pl < dn && ok; pl++) {
            size_t dw = CVPixelBufferGetWidthOfPlane(dst, pl), dh = CVPixelBufferGetHeightOfPlane(dst, pl);
            size_t sw = CVPixelBufferGetWidthOfPlane(src, pl), sh = CVPixelBufferGetHeightOfPlane(src, pl);
            if (dw != sw || dh != sh) { ok = NO; break; }
            uint8_t* dp = (uint8_t*)CVPixelBufferGetBaseAddressOfPlane(dst, pl);
            const uint8_t* sp = (const uint8_t*)CVPixelBufferGetBaseAddressOfPlane(src, pl);
            size_t ds = CVPixelBufferGetBytesPerRowOfPlane(dst, pl);
            size_t ss = CVPixelBufferGetBytesPerRowOfPlane(src, pl);
            if (!dp || !sp) { ok = NO; break; }
            size_t rowBytes = ds < ss ? ds : ss;
            for (size_t y = 0; y < dh; y++) memcpy(dp + y * ds, sp + y * ss, rowBytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(dst, 0);
    return ok;
}

// 按目标 buffer 的尺寸+像素格式渲染一张临时图（给 BGRA / 尺寸不一致时用）
static CVPixelBufferRef ConvertToMatch(CVPixelBufferRef src, CVPixelBufferRef like) {
    size_t w = CVPixelBufferGetWidth(like), h = CVPixelBufferGetHeight(like);
    OSType fmt = CVPixelBufferGetPixelFormatType(like);
    NSDictionary* attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    static CVPixelBufferPoolRef pool = NULL;
    static size_t pw = 0, ph = 0; static OSType pf = 0;
    if (!pool || pw != w || ph != h || pf != fmt) {
        if (pool) { CVPixelBufferPoolRelease(pool); pool = NULL; }
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &pool);
        pw = w; ph = h; pf = fmt;
    }
    CVPixelBufferRef dst = NULL;
    if (!pool || CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &dst) != kCVReturnSuccess || !dst) return NULL;
    if (!g_ciCtx) g_ciCtx = [CIContext contextWithOptions:nil];
    CIImage* ci = [CIImage imageWithCVPixelBuffer:src];
    CGFloat sx = (CGFloat)w / CVPixelBufferGetWidth(src);
    CGFloat sy = (CGFloat)h / CVPixelBufferGetHeight(src);
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    [g_ciCtx render:ci toCVPixelBuffer:dst bounds:CGRectMake(0, 0, w, h)
         colorSpace:CGColorSpaceCreateDeviceRGB()];
    return dst;
}

static CVPixelBufferRef ScaleBuffer(CVPixelBufferRef src, size_t tw, size_t th) {
    if (!g_ciCtx) g_ciCtx = [CIContext contextWithOptions:nil];
    if (!g_scalePool || g_scalePoolW != tw || g_scalePoolH != th) {
        if (g_scalePool) { CVPixelBufferPoolRelease(g_scalePool); g_scalePool = NULL; }
        NSDictionary* attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(tw),
            (id)kCVPixelBufferHeightKey: @(th),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &g_scalePool);
        g_scalePoolW = tw; g_scalePoolH = th;
    }
    if (!g_scalePool) return NULL;
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, g_scalePool, &dst) != kCVReturnSuccess || !dst) return NULL;
    CIImage* ci = [CIImage imageWithCVPixelBuffer:src];
    CGFloat sx = (CGFloat)tw / CVPixelBufferGetWidth(src);
    CGFloat sy = (CGFloat)th / CVPixelBufferGetHeight(src);
    CIImage* sc = [ci imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
    [g_ciCtx render:sc toCVPixelBuffer:dst bounds:CGRectMake(0, 0, tw, th) colorSpace:CGColorSpaceCreateDeviceRGB()];
    return dst;
}

@interface TLProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation TLProxy
- (BOOL)respondsToSelector:(SEL)aSelector {
    if ([super respondsToSelector:aSelector]) return YES;
    id d = g_realDelegate;
    return d && [d respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
    id d = g_realDelegate;
    return (d && [d respondsToSelector:aSelector]) ? d : nil;
}
- (void)captureOutput:(AVCaptureOutput*)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection*)connection {
    CVPixelBufferRef inPB = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferRef use = NULL;
    @try {
    pthread_mutex_lock(&g_lock);
    BOOL dimOk = YES;
    if (inPB && g_latest) {
        dimOk = (CVPixelBufferGetWidth(inPB) == CVPixelBufferGetWidth(g_latest) &&
                 CVPixelBufferGetHeight(inPB) == CVPixelBufferGetHeight(g_latest));
    }
    if (g_latest) {
        // 每一帧都用最近一帧 PC 画面（哪怕没有新帧），否则相机的原始帧会漏出去 -> 画面闪烁
        use = CVPixelBufferRetain(g_latest);
        g_sentSeq = g_latestSeq;
    }
    static int camDimLogged = 0;
    if (!camDimLogged && inPB) {
        camDimLogged = 1;
        NSLog(@"[TL] cam buffer %zux%zu fmt=%u (pc frame %zux%zu)",
              CVPixelBufferGetWidth(inPB), CVPixelBufferGetHeight(inPB),
              (unsigned)CVPixelBufferGetPixelFormatType(inPB),
              use ? CVPixelBufferGetWidth(use) : 0, use ? CVPixelBufferGetHeight(use) : 0);
    }
    size_t inW = inPB ? CVPixelBufferGetWidth(inPB) : 0;
    size_t inH = inPB ? CVPixelBufferGetHeight(inPB) : 0;
    pthread_mutex_unlock(&g_lock);

    if (use && !dimOk && inW && inH) {
        CVPixelBufferRef scaled = ScaleBuffer(use, inW, inH);
        CVPixelBufferRelease(use);
        use = scaled;   // 可能为 NULL -> 下面透传
    }

    // 首选：原地写进相机自己的 buffer，再把原始 sample buffer 原样转发（最不容易崩）
    // 首选：把 PC 帧画进相机自己的 buffer，再原样转发原始 sample buffer
    if (use && inPB) {
        CVPixelBufferRef tmp = NULL;
        if (CVPixelBufferGetWidth(use) == CVPixelBufferGetWidth(inPB) &&
            CVPixelBufferGetHeight(use) == CVPixelBufferGetHeight(inPB) &&
            CVPixelBufferGetPixelFormatType(use) == CVPixelBufferGetPixelFormatType(inPB)) {
            tmp = CVPixelBufferRetain(use);   // 已经是目标尺寸+格式，省掉一次 CI 渲染
        } else {
            tmp = ConvertToMatch(use, inPB);  // 尺寸/格式对齐到相机 buffer
        }
        BOOL painted = tmp ? CopyIntoPixelBuffer(inPB, tmp) : NO;
        if (tmp) CVPixelBufferRelease(tmp);
        static int failLog = 0;
        if (!painted && (failLog++ % 120) == 0)
            NSLog(@"[TL] paint failed dst=%zux%zu fmt=%u planes=%zu tmp=%d",
                  CVPixelBufferGetWidth(inPB), CVPixelBufferGetHeight(inPB),
                  CVPixelBufferGetPixelFormatType(inPB), CVPixelBufferGetPlaneCount(inPB), tmp != NULL);
        if (painted) {
            if (g_realDelegate && [g_realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
                [g_realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
            CVPixelBufferRelease(use); use = NULL;
            return;
        }
    }

    if (!use) {                       // 还没有 PC 帧 → 透传相机
        if (g_realDelegate && [g_realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) [g_realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        return;
    }

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, use, &fmt) == noErr) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if (!CMTIME_IS_VALID(pts)) pts = CMClockGetTime(CMClockGetHostTimeClock());
        CMTime dur = CMSampleBufferGetDuration(sampleBuffer);
        if (!CMTIME_IS_VALID(dur) || CMTimeGetSeconds(dur) <= 0) dur = CMTimeMake(1, OUT_FPS);
        CMSampleTimingInfo timing = { dur, pts, pts };
        CMSampleBufferRef sb = NULL;
        if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, use, fmt, &timing, &sb) == noErr) {
            if (g_realDelegate && [g_realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)])
                [g_realDelegate captureOutput:output didOutputSampleBuffer:sb fromConnection:connection];
            CFRelease(sb);
        }
        CFRelease(fmt);
    }
#if TL_ENABLE_FLOW
    ScheduleFlow(use);
#endif
    CVPixelBufferRelease(use); use = NULL;
    } @catch (NSException* e) {
        if (use) { CVPixelBufferRelease(use); use = NULL; }
        if (g_realDelegate && [g_realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) [g_realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        NSLog(@"[TL] proxy exception %@", e);
    }
}
@end

// ---------------- 交换 setSampleBufferDelegate:queue: ----------------
static void (*orig_setDelegate)(id, SEL, id, dispatch_queue_t) = NULL;

/* 每个类各自的原始实现：AVCaptureVideoDataOutput 与 AVCaptureAudioDataOutput 实现不同，
   共用一个 orig 会调错，重复 hook 还会把 orig 设成 hook 自己 → 无限递归爆栈。 */
static Class g_sdCls[4]; static IMP g_sdImp[4]; static int g_sdN = 0;
static void my_setDelegate(id, SEL, id, dispatch_queue_t);
static void TLHookSetDelegate(Class c) {
    if (!c) return;
    for (int i = 0; i < g_sdN; i++) if (g_sdCls[i] == c) return;
    Method m = class_getInstanceMethod(c, @selector(setSampleBufferDelegate:queue:));
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (old == (IMP)my_setDelegate) return;      /* 已经是我们的，不重复 */
    method_setImplementation(m, (IMP)my_setDelegate);
    if (g_sdN < 4) { g_sdCls[g_sdN] = c; g_sdImp[g_sdN] = old; g_sdN++; }
}
static IMP TLOrigSetDelegate(id self) {
    Class c = object_getClass(self);
    for (int i = 0; i < g_sdN; i++) if (g_sdCls[i] == c) return g_sdImp[i];
    return NULL;
}

static TLAudioProxy* g_ap = nil;
static int g_apSet = 0;


/* ---- paint inside Aweme's own delegate, without swapping the delegate ---- */
static void PaintIfAudio(id self, SEL _cmd, id output, CMSampleBufferRef sb, id conn);

static Class g_hookedCls[8]; static IMP g_hookedImp[8]; static int g_hookedN = 0;

static IMP TLHookDelegateClass(Class c) {
    for (int i = 0; i < g_hookedN; i++) if (g_hookedCls[i] == c) return g_hookedImp[i];
    if (g_hookedN >= 8 || !c) return NULL;
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NULL;
    IMP old = method_getImplementation(m);
    if (old == (IMP)PaintIfAudio) return NULL;      /* 已 hook 过，避免自递归 */
    method_setImplementation(m, (IMP)PaintIfAudio);
    g_hookedCls[g_hookedN] = c; g_hookedImp[g_hookedN] = old; g_hookedN++;
    return old;
}

static void PaintIfAudio(id self, SEL _cmd, id output, CMSampleBufferRef sb, id conn) {
    @try {
        Class aud = NSClassFromString(@"AVCaptureAudioDataOutput");
        if (aud && [output isKindOfClass:aud] && sb && g_audioGot) {
            PaintAudioIntoBuffer(sb);
        }
    } @catch (NSException* e) {}
    IMP fwd = NULL;
    for (int i = 0; i < g_hookedN; i++)
        if ([self isKindOfClass:g_hookedCls[i]]) fwd = g_hookedImp[i];   /* 取最派生的一次 */
    if (fwd) ((void(*)(id,SEL,id,CMSampleBufferRef,id))fwd)(self, _cmd, output, sb, conn);
}
static void my_setDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
  @try {
    BOOL isAudio = [self isKindOfClass:NSClassFromString(@"AVCaptureAudioDataOutput")];
    if (!delegate || !queue) {              // 解绑 / 销毁路径：原样透传，绝不替换
        @try { IMP o = TLOrigSetDelegate(self); if (o) ((void(*)(id,SEL,id,dispatch_queue_t))o)(self, _cmd, delegate, queue); } @catch (NSException* e) {}
        return;
    }
    if (delegate == (id)g_proxy || delegate == (id)g_ap) return;   // 幂等：已经是我们的代理
    if (isAudio) {
        g_realAudioDelegate = delegate;
        IMP old = TLHookDelegateClass([delegate class]);
        NSLog(@"[TL] setDelegate audio cls=%@ hooked=%d", NSStringFromClass([delegate class]), old ? 1 : 0);
        /* 采集已经在跑时再调原函数，AVFoundation 会抛 NSInvalidArgumentException 直接 abort。
           所以：output 还没有 delegate（新会话）才由我们装代理；已有别人的 delegate 就只记录，
           保持现有代理继续跑，绝不重复设置。 */
        id cur = nil;
        @try { cur = [self valueForKey:@"sampleBufferDelegate"]; } @catch (NSException* e) {}
        if (!g_ap) g_ap = [TLAudioProxy new];
        if (cur == nil || cur == (id)g_ap) {
            @try {
                IMP o = TLOrigSetDelegate(self);
                if (o) ((void(*)(id,SEL,id,dispatch_queue_t))o)(self, _cmd, (id)g_ap, queue);
                g_apSet = 1;
            } @catch (NSException* e) {
                NSLog(@"[TL] setDelegate audio throw: %@", e.reason);
            }
        } else {
            NSLog(@"[TL] setDelegate audio skip (already %@)", NSStringFromClass([cur class]));
        }
        return;
    }
    else g_realDelegate = delegate;
    g_realQueue = queue;
    if (!isAudio && !g_proxy) g_proxy = [TLProxy new];
    if (isAudio && !g_ap) g_ap = [TLAudioProxy new];
    {
        IMP o = TLOrigSetDelegate(self);
        @try { if (o) ((void(*)(id,SEL,id,dispatch_queue_t))o)(self, _cmd, isAudio ? (id)g_ap : (id)g_proxy, queue); }
        @catch (NSException* e) { NSLog(@"[TL] setDelegate video throw: %@", e.reason); }
    }
  } @catch (NSException* e) {
    NSLog(@"[TL] setDelegate outer throw: %@", e.reason);
  }
}

// ---------------- 抢 audio delegate（应对 App 在我们 hook 之前就设过 delegate） ----------------
static dispatch_queue_t g_aq = NULL;
static void (*orig_startRunning)(id, SEL) = NULL;

static void my_startRunning(id self, SEL _cmd) {
    if (orig_startRunning) orig_startRunning(self, _cmd);
    @try {
        if (!g_ap) g_ap = [TLAudioProxy new];
        if (!g_aq) g_aq = dispatch_queue_create("tl.audio", NULL);
        Class aud = NSClassFromString(@"AVCaptureAudioDataOutput");
        NSArray* outs = nil;
        @try { outs = [self valueForKey:@"outputs"]; } @catch (NSException* e) {}
        for (id o in outs) {
            if (!aud || ![o isKindOfClass:aud]) continue;
            id d = nil;
            @try { d = [o valueForKey:@"sampleBufferDelegate"]; } @catch (NSException* e) {}
            NSLog(@"[TL] audio output found delegate=%@", d ? NSStringFromClass([d class]) : @"nil");
            /* 会话已经在跑，此时再 set 代理会被 AVFoundation 抛异常，所以这里只记录不改。
               真正的代理安装走 my_setDelegate（加载时就 hook，早于抖音设置）。 */
            if (d && d != (id)g_ap) {
                g_realAudioDelegate = d;
                NSLog(@"[TL] audio delegate found %@ (keep)", NSStringFromClass([d class]));
            } else if (!d) {
                NSLog(@"[TL] audio output has no delegate");
            }
        }
    } @catch (NSException* e) {
        NSLog(@"[TL] startRunning scan exception %@", e);
    }
}


// ---------------- AudioUnit（RTC SDK 常见路径）：抢 render callback ----------------
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <mach/vm_map.h>

static OSStatus (*g_auSetPropOrig)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void*, UInt32) = NULL;
static AURenderCallback g_auCB = NULL;
static void* g_auCBRef = NULL;
static uint64_t g_auCBCount = 0;
static AudioStreamBasicDescription g_auFmt;
static int g_auFmtOK = 0;

static void PaintABL(AudioBufferList* io, UInt32 frames) {
    if (!io || io->mNumberBuffers == 0 || frames == 0) return;
    if (g_ard == g_awr) return;
    BOOL isFloat = g_auFmtOK ? ((g_auFmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0) : YES;
    BOOL nonInt  = g_auFmtOK ? ((g_auFmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0) : (io->mNumberBuffers > 1);
    UInt32 ch = g_auFmtOK && g_auFmt.mChannelsPerFrame ? g_auFmt.mChannelsPerFrame : io->mNumberBuffers;
    if (ch < 1) ch = 1;
    size_t need = (size_t)frames * 4;
    int16_t* src = (int16_t*)malloc(need);
    if (!src) return;
    size_t got = AudioPop(src, need);
    size_t have = got / 4;
    if (!have) { free(src); return; }
    if (nonInt) {
        for (UInt32 b = 0; b < io->mNumberBuffers; ++b) {
            AudioBuffer* ab = &io->mBuffers[b];
            if (!ab->mData) continue;
            float* fp = (float*)ab->mData;
            int16_t* ip = (int16_t*)ab->mData;
            for (UInt32 f = 0; f < frames; ++f) {
                float v = 0.f;
                if (f < have) v = (b == 0 ? src[f*2] : src[f*2+1]) / 32768.0f;
                if (isFloat) fp[f] = v; else ip[f] = (int16_t)(v * 32767.0f);
            }
        }
    } else {
        AudioBuffer* ab = &io->mBuffers[0];
        if (ab->mData) {
            float* fp = (float*)ab->mData;
            int16_t* ip = (int16_t*)ab->mData;
            for (UInt32 f = 0; f < frames; ++f) {
                float l = 0.f, r = 0.f;
                if (f < have) { l = src[f*2] / 32768.0f; r = src[f*2+1] / 32768.0f; }
                for (UInt32 c = 0; c < ch; ++c) {
                    float v = (c == 0) ? l : (c == 1 ? r : (l + r) * 0.5f);
                    if (isFloat) fp[f*ch + c] = v; else ip[f*ch + c] = (int16_t)(v * 32767.0f);
                }
            }
        }
    }
    free(src);
}

static OSStatus TL_AURenderCB(void* ref, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* ts,
                              UInt32 bus, UInt32 frames, AudioBufferList* io) {
    OSStatus st = g_auCB ? g_auCB(g_auCBRef, flags, ts, bus, frames, io) : noErr;
    if ((++g_auCBCount % 300) == 1)
        NSLog(@"[TL] AU render #%llu frames=%u bufs=%u fmt=%d", g_auCBCount, (unsigned)frames,
              io ? (unsigned)io->mNumberBuffers : 0, g_auFmtOK);
    @try { PaintABL(io, frames); } @catch (NSException* e) { NSLog(@"[TL] paintAU exception %@", e); }
    return st;
}

static OSStatus TL_AudioUnitSetProperty(AudioUnit u, AudioUnitPropertyID pid, AudioUnitScope sc,
                                        AudioUnitElement el, const void* data, UInt32 size) {
    if (pid == kAudioUnitProperty_SetRenderCallback && data && size >= sizeof(AURenderCallbackStruct)) {
        AURenderCallbackStruct* rs = (AURenderCallbackStruct*)data;
        g_auCB = rs->inputProc;
        g_auCBRef = rs->inputProcRefCon;
        NSLog(@"[TL] AU render callback captured scope=%u el=%u", (unsigned)sc, (unsigned)el);
        AURenderCallbackStruct ns = { TL_AURenderCB, NULL };
        return g_auSetPropOrig ? g_auSetPropOrig(u, pid, sc, el, &ns, sizeof(ns)) : noErr;
    }
    if (pid == kAudioUnitProperty_StreamFormat && data && size >= sizeof(AudioStreamBasicDescription)) {
        memcpy(&g_auFmt, data, sizeof(AudioStreamBasicDescription));
        g_auFmtOK = 1;
        NSLog(@"[TL] AU fmt %.0fHz ch=%u bits=%u flags=0x%x", g_auFmt.mSampleRate,
              (unsigned)g_auFmt.mChannelsPerFrame, (unsigned)g_auFmt.mBitsPerChannel, (unsigned)g_auFmt.mFormatFlags);
    }
    return g_auSetPropOrig ? g_auSetPropOrig(u, pid, sc, el, data, size) : noErr;
}

// 在已加载镜像的 __got / __la_symbol_ptr 里，把指向 target 的槽位换成 repl
static int TLHookC(void* target, void* repl, const char* name) {
    if (!target || !repl) return 0;
    uint64_t tv = (uint64_t)target & 0x0000FFFFFFFFFFFFULL;
    int hits = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; ++i) {
        const struct mach_header_64* mh = (const struct mach_header_64*)_dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command* lc = (const struct load_command*)((const char*)mh + sizeof(struct mach_header_64));
        for (uint32_t c = 0; c < mh->ncmds && lc; ++c) {
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64* seg = (const struct segment_command_64*)lc;
                if (!strcmp(seg->segname, "__DATA") || !strcmp(seg->segname, "__DATA_CONST")) {
                    const struct section_64* sec = (const struct section_64*)((const char*)seg + sizeof(*seg));
                    for (uint32_t s = 0; s < seg->nsects; ++s, ++sec) {
                        if (strcmp(sec->sectname, "__got") && strcmp(sec->sectname, "__la_symbol_ptr")) continue;
                        uint64_t* slot = (uint64_t*)((const char*)mh + sec->offset + slide);
                        size_t cnt = sec->size / sizeof(uint64_t);
                        for (size_t k = 0; k < cnt; ++k) {
                            if ((slot[k] & 0x0000FFFFFFFFFFFFULL) == tv) {
                                vm_address_t pg = (vm_address_t)&slot[k] & ~(vm_page_size - 1);
                                vm_size_t psz = (vm_address_t)&slot[k] + 8 - pg;
                                if (vm_protect(mach_task_self(), pg, psz, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
                                    slot[k] = (uint64_t)repl; ++hits;
                                }
                            }
                        }
                    }
                }
            }
            lc = (const struct load_command*)((const char*)lc + lc->cmdsize);
        }
    }
    NSLog(@"[TL] hookC %s hits=%d", name, hits);
    return hits;
}


static int g_audioHookDone = 0;
static void TLInstallAudioHooks(void) {
    Class aud0 = NSClassFromString(@"AVCaptureAudioDataOutput");
    Class sess0 = NSClassFromString(@"AVCaptureSession");
    if (!aud0) return;
    SEL sel = @selector(setSampleBufferDelegate:queue:);
    Method m = class_getInstanceMethod(aud0, sel);
    if (m && !g_audioHookDone) {
        TLHookSetDelegate(aud0);
        g_audioHookDone = 1;
        NSLog(@"[TL] audio hook installed at load");
    }
    /* 不再 hook startRunning：它只用来打日志，而 hook 它曾导致自递归爆栈。
       代理安装已由 my_setDelegate（加载时 hook，早于抖音设置）完成。 */
#if TL_ENABLE_AUDIO
    Class inNode = NSClassFromString(@"AVAudioInputNode");
    SEL tapSel = @selector(installTapOnBus:bufferSize:format:block:);
    Method tm = inNode ? class_getInstanceMethod(inNode, tapSel) : NULL;
    if (tm && !orig_tap) {
        orig_tap = (void*)method_getImplementation(tm);
        method_setImplementation(tm, (IMP)my_tap);
        NSLog(@"[TL] tap hook installed at load");
    }
#endif
}

static void TLInstallHooks(void) {
    // 视频与音频输出都要换 delegate（两者没有共同的方法实现，分别 hook）
    for (NSString* cn in @[@"AVCaptureVideoDataOutput", @"AVCaptureAudioDataOutput"]) {
        Class cls = NSClassFromString(cn);
        SEL sel = @selector(setSampleBufferDelegate:queue:);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (m) {
            TLHookSetDelegate(cls);
            NSLog(@"[TL] hook %@", cn);
        }
    }
    /* startRunning 不再 hook（见上） */
    Class auCls = NSClassFromString(@"AVAudioUnit");
    (void)auCls;
    if (getenv("TL_AUHOOK")) {
        void* p = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
        g_auSetPropOrig = (OSStatus(*)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void*, UInt32))p;
        TLHookC(p, (void*)TL_AudioUnitSetProperty, "AudioUnitSetProperty");
    }
    // AVAudioEngine 路径（部分版本用 inputNode tap 取麦）
#if TL_ENABLE_AUDIO
    Class inNode = NSClassFromString(@"AVAudioInputNode");
    SEL tapSel = @selector(installTapOnBus:bufferSize:format:block:);
    Method tm = inNode ? class_getInstanceMethod(inNode, tapSel) : NULL;
    if (tm) {
        orig_tap = (void*)method_getImplementation(tm);
        method_setImplementation(tm, (IMP)my_tap);
        NSLog(@"[TL] hook AVAudioInputNode installTapOnBus");
    }
#endif

    if (getenv("TL_AUDIO_PORT")) g_audioPort = atoi(getenv("TL_AUDIO_PORT"));

    pthread_t t;
    pthread_create(&t, NULL, USBVideoThread, NULL);   // USB：手机监听 9800，PC 经 usbmux 连入
    pthread_t at;
    pthread_create(&at, NULL, AudioThread, NULL);
}

__attribute__((constructor))
static void TLInit(void) {
    @try {
        // 延迟 0.8s，等 App 完成启动、类都加载好再装 hook
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            /* audio hooks must beat Aweme's capture session: install at dylib load */
            for (int i = 0; i < 2; i++) {
                @try { TLInstallAudioHooks(); } @catch (NSException* e) {}
                if (g_audioHookDone) break;
                usleep(50 * 1000);
            }
            NSLog(@"[TL] audio early hooks done=%d startRunning=%d", g_audioHookDone, orig_startRunning ? 1 : 0);
            @try { TLInstallHooks(); }
            @catch (NSException* e) { NSLog(@"[TL] install exception: %@", e); }
        });
    } @catch (NSException* e) {
        NSLog(@"[TL] ctor exception: %@", e);
    }
}

