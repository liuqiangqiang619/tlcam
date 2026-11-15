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
#import <netinet/tcp.h>

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

#define TL_ENABLE_AUDIO 0
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
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
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
    ci = CameraImperfections(ci, mdx, mdy);
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
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        (id)kCVPixelBufferWidthKey:  @(FLOW_W),
        (id)kCVPixelBufferHeightKey: @(FLOW_H),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, FLOW_W, FLOW_H,
                            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
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
        int s = -1;
        while (1) {
            if (s < 0) {
                s = ConnectPC2(g_audioPort);
                if (s < 0) { usleep(500 * 1000); continue; }
                NSLog(@"[TL] audio connected to %s:%d", PC_HOST, g_audioPort);
            }
            uint32_t beLen = 0;
            if (!ReadFull(s, &beLen, 4)) { close(s); s = -1; continue; }
            uint32_t len = ntohl(beLen);
            if (len == 0 || len > 65536) { close(s); s = -1; continue; }
            uint8_t* tmp = malloc(len);
            if (!ReadFull(s, tmp, len)) { free(tmp); close(s); s = -1; continue; }
            AudioPush(tmp, len);
            free(tmp);
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
    CMSampleBufferRef sb = MakeAudioBuffer(1024);
    if (sb) {
        if (g_realAudioDelegate) [g_realAudioDelegate captureOutput:output didOutputSampleBuffer:sb fromConnection:connection];
        CFRelease(sb);
        return;
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
static CVPixelBufferPoolRef g_pool = NULL;
static size_t g_poolW = 0, g_poolH = 0;

static CVPixelBufferRef ScaleBuffer(CVPixelBufferRef src, size_t tw, size_t th) {
    if (!g_ciCtx) g_ciCtx = [CIContext contextWithOptions:nil];
    if (!g_pool || g_poolW != tw || g_poolH != th) {
        if (g_pool) { CVPixelBufferPoolRelease(g_pool); g_pool = NULL; }
        NSDictionary* attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            (id)kCVPixelBufferWidthKey: @(tw),
            (id)kCVPixelBufferHeightKey: @(th),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &g_pool);
        g_poolW = tw; g_poolH = th;
    }
    if (!g_pool) return NULL;
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, g_pool, &dst) != kCVReturnSuccess || !dst) return NULL;
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
- (void)captureOutput:(AVCaptureOutput*)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection*)connection {
    CVPixelBufferRef inPB = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferRef use = NULL;
    pthread_mutex_lock(&g_lock);
    BOOL dimOk = YES;
    if (inPB && g_latest) {
        dimOk = (CVPixelBufferGetWidth(inPB) == CVPixelBufferGetWidth(g_latest) &&
                 CVPixelBufferGetHeight(inPB) == CVPixelBufferGetHeight(g_latest));
    }
    if (g_latest && g_latestSeq != g_sentSeq) {
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

    if (!use) {                       // 还没有 PC 帧 → 透传相机
        if (g_realDelegate) [g_realDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
        return;
    }

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, use, &fmt) == noErr) {
        CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());
        CMSampleTimingInfo timing = { CMTimeMake(1, OUT_FPS), pts, pts };
        CMSampleBufferRef sb = NULL;
        if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, use, fmt, &timing, &sb) == noErr) {
            if (g_realDelegate)
                [g_realDelegate captureOutput:output didOutputSampleBuffer:sb fromConnection:connection];
            CFRelease(sb);
        }
        CFRelease(fmt);
    }
    ScheduleFlow(use);
    CVPixelBufferRelease(use);
}
@end

// ---------------- 交换 setSampleBufferDelegate:queue: ----------------
static void (*orig_setDelegate)(id, SEL, id, dispatch_queue_t) = NULL;

static TLAudioProxy* g_ap = nil;

static void my_setDelegate(id self, SEL _cmd, id delegate, dispatch_queue_t queue) {
    BOOL isAudio = [self isKindOfClass:NSClassFromString(@"AVCaptureAudioDataOutput")];
    if (isAudio) g_realAudioDelegate = delegate; else g_realDelegate = delegate;
    g_realQueue = queue;
    if (!isAudio && !g_proxy) g_proxy = [TLProxy new];
    if (isAudio && !g_ap) g_ap = [TLAudioProxy new];
    if (orig_setDelegate) orig_setDelegate(self, _cmd, isAudio ? (id)g_ap : (id)g_proxy, queue);
}

__attribute__((constructor))
static void TLInit(void) {
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
    pthread_create(&t, NULL, ReceiverThread, NULL);
    pthread_t at;
    pthread_create(&at, NULL, AudioThread, NULL);
}
