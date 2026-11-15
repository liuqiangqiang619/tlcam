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
        [blur setValue:@(0.35) forKey:@"inputRadius"];
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

static void VTReset(void) {
    if (g_vt) { VTDecompressionSessionInvalidate(g_vt); CFRelease(g_vt); g_vt = NULL; }
    if (g_vtFmt) { CFRelease(g_vtFmt); g_vtFmt = NULL; }
}

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
    NSLog(@"[TL] h264 decoder ready %dx%d", (int)CMVideoFormatDescriptionGetDimensions(g_vtFmt).width,
          (int)CMVideoFormatDescriptionGetDimensions(g_vtFmt).height);
}

static void VTFeedNAL(const uint8_t* p, size_t n) {
    if (n < 5) return;
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
    CMSampleTimingInfo t = { CMTimeMake(1, 30), kCMTimeInvalid, kCMTimeInvalid };
    if (CMSampleBufferCreateReady(kCFAllocatorDefault, bb, g_vtFmt, 1, 1, &t, 1, &sz, &sb) == noErr && sb) {
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
            listen(ls, 1);
            NSLog(@"[TL] usb video listen %d", PC_PORT);
            while (1) {
                int c = accept(ls, NULL, NULL);
                if (c < 0) { usleep(200 * 1000); continue; }
                int nd = 1;
                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof(nd));
                NSLog(@"[TL] usb video connected");
                while (1) {
                    uint8_t h[16];
                    if (!ReadFull(c, h, 16)) break;
                    uint32_t len = ((uint32_t)h[0] << 24) | ((uint32_t)h[1] << 16) | ((uint32_t)h[2] << 8) | (uint32_t)h[3];
                    if (len < 4 || len > 4 * 1024 * 1024) { NSLog(@"[TL] bad nal len %u", len); break; }
                    uint8_t* d = (uint8_t*)malloc(len);
                    if (!d) break;
                    if (!ReadFull(c, d, len)) { free(d); break; }
                    @try { VTFeedNAL(d, len); } @catch (NSException* e) { NSLog(@"[TL] nal exception %@", e); }
                    free(d);
                }
                close(c);
                NSLog(@"[TL] usb video closed");
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

static void AudioPush(const uint8_t* d, size_t n) {
    pthread_mutex_lock(&g_alock);
    for (size_t i = 0; i < n; ++i) {
        g_abuf[g_awr] = d[i];
        g_awr = (g_awr + 1) % ARING_BYTES;
        if (g_awr == g_ard) g_ard = (g_ard + 1) % ARING_BYTES;   // 覆盖旧数据
    }
    g_audioGot++;
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
            listen(ls, 1);
            NSLog(@"[TL] usb audio listen %d", g_audioPort);
            while (1) {
                int c = accept(ls, NULL, NULL);
                if (c < 0) { usleep(200 * 1000); continue; }
                int nd = 1;
                setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &nd, sizeof(nd));
                NSLog(@"[TL] usb audio connected");
                while (1) {
                    uint8_t h[16];
                    if (!ReadFull(c, h, 16)) break;
                    uint32_t len = ((uint32_t)h[0] << 24) | ((uint32_t)h[1] << 16) | ((uint32_t)h[2] << 8) | (uint32_t)h[3];
                    if (len < 16 || len > 65536) { NSLog(@"[TL] bad pcm len %u", len); break; }
                    uint8_t* d = (uint8_t*)malloc(len);
                    if (!d) break;
                    if (!ReadFull(c, d, len)) { free(d); break; }
                    AudioPush(d, len);
                    free(d);
                }
                close(c);
                NSLog(@"[TL] usb audio closed");
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
static BOOL PaintAudioIntoBuffer(CMSampleBufferRef sb) {
    if (!sb) return NO;
    if (g_ard == g_awr) return NO;                       // 还没有 PC 音频
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
                    if (have > 0) {
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

static TLAudioProxy* g_ap = nil;

static void my_setDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    BOOL isAudio = [self isKindOfClass:NSClassFromString(@"AVCaptureAudioDataOutput")];
    if (!delegate || !queue) {              // 解绑 / 销毁路径：原样透传，绝不替换
        if (orig_setDelegate) orig_setDelegate(self, _cmd, delegate, queue);
        return;
    }
    if (delegate == (id)g_proxy || delegate == (id)g_ap) return;   // 幂等：已经是我们的代理
    if (isAudio) g_realAudioDelegate = delegate; else g_realDelegate = delegate;
    g_realQueue = queue;
    if (!isAudio && !g_proxy) g_proxy = [TLProxy new];
    if (isAudio && !g_ap) g_ap = [TLAudioProxy new];
    if (orig_setDelegate) orig_setDelegate(self, _cmd, isAudio ? (id)g_ap : (id)g_proxy, queue);
}

static void TLInstallHooks(void) {
    // 视频与音频输出都要换 delegate（两者没有共同的方法实现，分别 hook）
    for (NSString* cn in @[@"AVCaptureVideoDataOutput", @"AVCaptureAudioDataOutput"]) {
        Class cls = NSClassFromString(cn);
        SEL sel = @selector(setSampleBufferDelegate:queue:);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (m) {
            if (!orig_setDelegate) orig_setDelegate = (void*)method_getImplementation(m);
            method_setImplementation(m, (IMP)my_setDelegate);
            NSLog(@"[TL] hook %@", cn);
        }
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
            @try { TLInstallHooks(); }
            @catch (NSException* e) { NSLog(@"[TL] install exception: %@", e); }
        });
    } @catch (NSException* e) {
        NSLog(@"[TL] ctor exception: %@", e);
    }
}

