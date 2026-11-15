// IMUSynth.m — 用画面光流反推角速度，实时伪造 CMDeviceMotion
// 原型代码：需要在真机上按机型标定焦距、噪声与延迟
//
// 接入：与 Tweak.m 一起编译（把本文件加入 TLCam_FILES）
//
// 原理：
//   相邻帧做稀疏/稠密光流 → 平均位移 (dx,dy) 像素
//   角速度 ω ≈ (dx / f) * fps      （f = 焦距像素，iPhone 14 主摄 ≈ 2780px @1080p 裁切后按实际标定）
//   把 ω 积分成 attitude，配合重力向量合成 userAcceleration
//   以 100Hz 回调给抖音（CMMotionManager 的实际上限就是 100Hz）

#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>
#import <math.h>

#ifndef TL_ENABLE_IMU
#define TL_ENABLE_IMU 0
#endif

static double g_focalPx = 2780.0;   // 需要标定：拍一张已知角度旋转，反算
static double g_fps      = 30.0;

static double g_wx = 0, g_wy = 0, g_wz = 0;   // rad/s（上一帧估出来的）
static double g_lastFlowDx = 0, g_lastFlowDy = 0;
static double g_yaw = 0, g_pitch = 0, g_roll = 0;
static double g_t0 = 0;
static double g_biasX = 0, g_biasY = 0;       // 慢漂移，增加真实感
static dispatch_queue_t g_q;
static id g_handler = nil;
static NSTimer* g_timer = nil;

// ---------- 由光流更新角速度 ----------
void TLUpdateMotionFromFlow(double dxPix, double dyPix, double dt) {
    if (dt <= 0) return;
    g_lastFlowDx = dxPix; g_lastFlowDy = dyPix;
    // 像素位移 → 弧度（小角度近似）
    double ay = -(dxPix / g_focalPx) / dt;   // 水平位移 ≈ 绕 Y 轴（yaw）
    double ax = -(dyPix / g_focalPx) / dt;   // 垂直位移 ≈ 绕 X 轴（pitch）
    // 一阶低通，避免逐帧抖动
    g_wy = g_wy * 0.7 + ay * 0.3;
    g_wx = g_wx * 0.7 + ax * 0.3;
    g_wz = g_wz * 0.9;                        // 绕 Z 轴（roll）光流估不准，衰减
}

// 供外部读取（调试/标定用）
void TLGetMotionState(double* wx, double* wy, double* dx, double* dy) {
    if (wx) *wx = g_wx;
    if (wy) *wy = g_wy;
    if (dx) *dx = g_lastFlowDx;
    if (dy) *dy = g_lastFlowDy;
}

// 运行期标定：已知转了 angleRad，期间累计的角速度为 acc，则 focal' = focal * (acc/angle)
void TLCalibrateFocal(double knownAngleRad, double integratedRad) {
    if (integratedRad > 1e-6 && knownAngleRad > 1e-6) {
        g_focalPx *= (integratedRad / knownAngleRad);
        NSLog(@"[TL] focal calibrated to %.1f px", g_focalPx);
    }
}

// ---------- 生成一个 CMDeviceMotion ----------
static BOOL SetNum(id obj, NSArray<NSString*>* keys, double v) {
    for (NSString* k in keys) {
        @try { [obj setValue:@(v) forKey:k]; return YES; } @catch (NSException* e) {}
    }
    return NO;
}

static BOOL g_kvcOk = NO;

static CMDeviceMotion* MakeMotion(double dt) {
    CMDeviceMotion* m = [[CMDeviceMotion alloc] init];

    // 积分姿态
    g_yaw   += g_wy * dt;
    g_pitch += g_wx * dt;
    g_roll  += g_wz * dt;

    // 陀螺仪：加白噪声 + 慢漂移
    double n = 0.004;   // rad/s 噪声，按实测调
    double gx = g_wx + g_biasX + ((double)arc4random() / UINT32_MAX - 0.5) * n;
    double gy = g_wy + g_biasY + ((double)arc4random() / UINT32_MAX - 0.5) * n;
    double gz = g_wz          + ((double)arc4random() / UINT32_MAX - 0.5) * n;
    g_biasX += ((double)arc4random() / UINT32_MAX - 0.5) * 1e-4;
    g_biasY += ((double)arc4random() / UINT32_MAX - 0.5) * 1e-4;

    // 重力（设备坐标系，简单按 pitch/roll 旋转）
    double gx_g = -sin(g_pitch);
    double gy_g =  sin(g_roll) * cos(g_pitch);
    double gz_g =  cos(g_roll) * cos(g_pitch);

    @try {
        BOOL ok = YES;
        ok &= SetNum(m, @[@"_rotationRateX", @"_gyroX", @"rotationRate.x"], gx);
        ok &= SetNum(m, @[@"_rotationRateY", @"_gyroY", @"rotationRate.y"], gy);
        ok &= SetNum(m, @[@"_rotationRateZ", @"_gyroZ", @"rotationRate.z"], gz);
        ok &= SetNum(m, @[@"_userAccelerationX", @"_accelX"], 0.0);
        ok &= SetNum(m, @[@"_userAccelerationY", @"_accelY"], 0.0);
        ok &= SetNum(m, @[@"_userAccelerationZ", @"_accelZ"], 0.0);
        ok &= SetNum(m, @[@"_gravityX", @"gravity.x"], gx_g * 9.81);
        ok &= SetNum(m, @[@"_gravityY", @"gravity.y"], gy_g * 9.81);
        ok &= SetNum(m, @[@"_gravityZ", @"gravity.z"], gz_g * 9.81);
        ok &= SetNum(m, @[@"_timestamp", @"timestamp"], CACurrentMediaTime());
        if (!g_kvcOk && ok) { g_kvcOk = YES; NSLog(@"[TL] motion KVC ok"); }
        if (!ok && !g_kvcOk) {
            static int once = 0;
            if (once++ < 3) NSLog(@"[TL] motion KVC path mismatch, dumping ivars");
        }
    } @catch (NSException* e) {
        NSLog(@"[TL] motion kvc failed: %@", e.reason);
    }
    return m;
}

// ---------- 100Hz 回调 ----------
static FILE* g_csv = NULL;

static void Tick(void) {
    static double last = 0;
    static unsigned long long n = 0;
    double now = CACurrentMediaTime();
    double dt = last > 0 ? (now - last) : 0.01;
    last = now;
    CMDeviceMotion* m = MakeMotion(dt);
    if (g_handler) {
        void (^h)(CMDeviceMotion*, NSError*) = g_handler;
        h(m, nil);
    }
    if (g_csv) {
        fprintf(g_csv, "%.6f,%.5f,%.5f,%.5f,%.3f,%.3f\n", now, g_wx, g_wy, g_wz, g_lastFlowDx, g_lastFlowDy);
        if ((n % 100) == 0) fflush(g_csv);
    }
    if ((n % 200) == 0) {
        NSLog(@"[TL] imu wx=%.3f wy=%.3f wz=%.3f  flow=(%.2f, %.2f) px", g_wx, g_wy, g_wz, g_lastFlowDx, g_lastFlowDy);
    }
    n++;
}

static void DumpIvars(void) {
    unsigned int cnt = 0;
    Ivar* ivars = class_copyIvarList(NSClassFromString(@"CMDeviceMotion"), &cnt);
    for (unsigned int i = 0; i < cnt; ++i) {
        NSLog(@"[TL] ivar %s : %s", ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]));
    }
    if (ivars) free(ivars);
}

// ---------- hook CMMotionManager ----------
static void (*orig_start)(id, SEL, NSOperationQueue*, id) = NULL;
static void my_start(id self, SEL _cmd, NSOperationQueue* q, id handler) {
    g_handler = [handler copy];
    g_q = dispatch_queue_create("tl.motion", DISPATCH_QUEUE_SERIAL);
    if (!g_timer) {
        g_timer = [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer* t){ Tick(); }];
        [[NSRunLoop mainRunLoop] addTimer:g_timer forMode:NSRunLoopCommonModes];
    }
    NSLog(@"[TL] motion hook active");
}

__attribute__((constructor))
static void TLIMUInit(void) {
#if !TL_ENABLE_IMU
    return;
#else
    Class c = NSClassFromString(@"CMMotionManager");
    SEL s = @selector(startDeviceMotionUpdatesToQueue:withHandler:);
    Method m = class_getInstanceMethod(c, s);
    if (m) {
        orig_start = (void*)method_getImplementation(m);
        method_setImplementation(m, (IMP)my_start);
    }
    // 让 isDeviceMotionAvailable 恒为真（部分机型/模拟器会返回 NO）
    Method av = class_getInstanceMethod(c, @selector(isDeviceMotionAvailable));
    if (av) method_setImplementation(av, imp_implementationWithBlock(^BOOL(id _s){ return YES; }));

    if (getenv("TL_DUMP")) {
        NSString* p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tl_imu.csv"];
        g_csv = fopen(p.UTF8String, "w");
        if (g_csv) { fprintf(g_csv, "t,wx,wy,wz,dx,dy\n"); NSLog(@"[TL] dump -> %@", p); }
    }
    DumpIvars();
#endif
}
