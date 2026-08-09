// Drives the Shanling UA1 II vendor channel on macOS with no driver, no dext,
// no SIP change — just root.
//
// USBDeviceReEnumerate(kUSBReEnumerateCaptureDeviceMask) re-enumerates the
// device with every kernel driver detached, including the HID dext that owns
// interface 2 and refuses USBInterfaceOpenSeize. IOUSBLib.h documents root
// privileges as an accepted alternative to the com.apple.vm.device-access
// entitlement.
//
// Audio stops while the device is captured, so the release path runs on every
// exit, including Ctrl-C.
//
//   clang -o capture capture.c -framework IOKit -framework CoreFoundation
//   sudo ./capture              # read state only
//   sudo ./capture 01 40        # write command 0x01 = 40, then read back
//   sudo ./capture verify       # sweep the not-yet-confirmed command bytes
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

#define VID 0x20B1
#define PID 0x3033
#define IFACE 2
#define EP_OUT 0x03
#define EP_IN 0x82
#define PAYLOAD 40

static IOUSBDeviceInterface **gDevice = NULL;   // held open so we can release
static volatile int gReleased = 0;

// MARK: - Lookup

static IOUSBDeviceInterface **findDevice(void) {
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    int vid = VID, pid = PID;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberIntType, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(m, CFSTR(kUSBProductID), p);
    CFRelease(v); CFRelease(p);

    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) != KERN_SUCCESS) return NULL;
    io_service_t svc = IOIteratorNext(it);
    IOObjectRelease(it);
    if (!svc) return NULL;

    IOCFPlugInInterface **plug = NULL; SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(svc);
    if (kr != KERN_SUCCESS || !plug) return NULL;

    IOUSBDeviceInterface **d = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&d);
    (*plug)->Release(plug);
    return d;
}

static IOUSBInterfaceInterface700 **findInterface(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOUSBHostInterface"), &it) != KERN_SUCCESS) return NULL;

    io_service_t svc, target = 0;
    while ((svc = IOIteratorNext(it))) {
        CFNumberRef a = IORegistryEntryCreateCFProperty(svc, CFSTR("idVendor"), NULL, 0);
        CFNumberRef b = IORegistryEntryCreateCFProperty(svc, CFSTR("idProduct"), NULL, 0);
        CFNumberRef c = IORegistryEntryCreateCFProperty(svc, CFSTR("bInterfaceNumber"), NULL, 0);
        int vid = 0, pid = 0, num = -1;
        if (a) { CFNumberGetValue(a, kCFNumberIntType, &vid); CFRelease(a); }
        if (b) { CFNumberGetValue(b, kCFNumberIntType, &pid); CFRelease(b); }
        if (c) { CFNumberGetValue(c, kCFNumberIntType, &num); CFRelease(c); }
        if (vid == VID && pid == PID && num == IFACE) { target = svc; break; }
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    if (!target) return NULL;

    IOCFPlugInInterface **plug = NULL; SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(target, kIOUSBInterfaceUserClientTypeID,
            kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(target);
    if (kr != KERN_SUCCESS || !plug) return NULL;

    IOUSBInterfaceInterface700 **i = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID700), (LPVOID *)&i);
    (*plug)->Release(plug);
    return i;
}

// MARK: - Capture lifecycle

static void releaseDevice(void) {
    if (gReleased || !gDevice) return;
    gReleased = 1;
    printf("\n将设备交还系统…\n");
    IOReturn r = (*gDevice)->USBDeviceReEnumerate(gDevice, kUSBReEnumerateReleaseDeviceMask);
    printf("  release -> 0x%08X %s\n", r, r == kIOReturnSuccess ? "(OK)" : "(失败，拔插一次即可恢复)");
}

static void onSignal(int sig) { (void)sig; releaseDevice(); _exit(1); }

// MARK: - Protocol

static void buildPacket(uint8_t *p, uint8_t cmd, uint8_t val) {
    memset(p, 0, PAYLOAD);
    p[0] = 0xAA; p[1] = 0x55; p[2] = 0x10;
    p[3] = cmd; p[4] = val; p[5] = 0x01;
    int s = 0;
    for (int i = 0; i < PAYLOAD - 1; i++) s += p[i];
    p[PAYLOAD - 1] = (uint8_t)(~s & 0xFF);
}

// ReadPipeTO/WritePipeTO are documented as BULK-only and return
// kIOReturnBadArgument on an interrupt pipe, so these use the plain variants.
// The read goes through the async API with a bounded run loop: a synchronous
// ReadPipe would block forever if the device stayed quiet, and the device is
// captured at that point, so audio would stay dead.

static volatile int gReadDone;
static volatile IOReturn gReadResult;
static volatile UInt32 gReadLength;

static void readComplete(void *refcon, IOReturn result, void *arg0) {
    (void)refcon;
    gReadResult = result;
    gReadLength = (UInt32)(uintptr_t)arg0;
    gReadDone = 1;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static int readOnce(IOUSBInterfaceInterface700 **intf, int pipeIn,
                    uint8_t *buf, UInt32 cap, double seconds) {
    gReadDone = 0; gReadResult = kIOReturnSuccess; gReadLength = 0;
    memset(buf, 0, cap);

    IOReturn r = (*intf)->ReadPipeAsync(intf, pipeIn, buf, cap, readComplete, NULL);
    if (r != kIOReturnSuccess) return -1;

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    if (!gReadDone) {
        (*intf)->AbortPipe(intf, pipeIn);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.2, false);
        return -2;
    }
    return gReadResult == kIOReturnSuccess ? (int)gReadLength : -3;
}

/*!
 * Sends one command and collects the reply.
 * @param frame  Receives the 9-byte data frame, if one arrives.
 * @param quiet  Suppresses the per-transfer dump (used by the verify sweep).
 * @return Frame length, or <= 0 on failure.
 */
static int exchangeRaw(IOUSBInterfaceInterface700 **intf, int pipeOut, int pipeIn,
                       uint8_t cmd, uint8_t val, uint8_t *frame, int quiet,
                       const char *label) {
    uint8_t wire[1 + PAYLOAD];
    wire[0] = 0x01;
    buildPacket(wire + 1, cmd, val);

    IOReturn r = (*intf)->WritePipe(intf, pipeOut, wire, sizeof(wire));
    if (!quiet) printf("[%s] 写 -> 0x%08X%s\n", label, r,
                       r == kIOReturnSuccess ? "" : " (失败)");
    if (r != kIOReturnSuccess) return -1;

    int dataLen = 0;
    // Each request yields a data frame plus a trailing terminator; both must be
    // consumed or the next reply arrives one request late.
    for (int i = 0; i < 2; i++) {
        uint8_t in[64];
        int n = readOnce(intf, pipeIn, in, sizeof(in), i == 0 ? 1.0 : 0.4);
        if (n <= 0) { if (i == 0 && !quiet) printf("    无回复 (%d)\n", n); break; }

        if (i == 0 && n >= 9 && in[1] == 0x55 && in[2] == 0xAA) {
            memcpy(frame, in, 9);
            dataLen = n;
        }
        if (quiet) continue;

        printf("    收到#%d %d 字节:", i + 1, n);
        for (int k = 0; k < n; k++) printf(" %02X", in[k]);
        if (n >= 4 && in[1] == 0x55 && in[2] == 0xAA) {
            printf("   <<< 页 0x%02X", in[3]);
            if (in[3] == 0x21) printf("  音量=%d 增益=%d 滤波器=%d 平衡=%d",
                                      in[4], in[5], in[6], (int8_t)in[7]);
        }
        printf("\n");
    }
    return dataLen;
}

static void exchange(IOUSBInterfaceInterface700 **intf, int pipeOut, int pipeIn,
                     uint8_t cmd, uint8_t val, const char *label) {
    uint8_t frame[9] = {0};
    exchangeRaw(intf, pipeOut, pipeIn, cmd, val, frame, 0, label);
}

// MARK: - Command verification sweep

struct Check {
    uint8_t cmd;          // command byte
    uint8_t page;         // page to read back
    int index;            // byte within the frame that should change
    int testValue;        // value to write
    int fallbackValue;    // used when testValue equals the current value
    int wireOffset;       // added on the wire (screen offset uses +50)
    int isSigned;
    const char *name;
};

/*! Returns the *logical* value, i.e. with any wire offset removed. */
static int readField(IOUSBInterfaceInterface700 **intf, int pipeOut, int pipeIn,
                     uint8_t page, int index, int isSigned, int wireOffset, int *ok) {
    uint8_t f[9] = {0};
    int n = exchangeRaw(intf, pipeOut, pipeIn, 0xFF, (uint8_t)(page - 0x20), f, 1, NULL);
    *ok = (n >= 9 && f[3] == page);
    if (!*ok) return 0;
    int raw = isSigned ? (int)(int8_t)f[index] : (int)f[index];
    return raw - wireOffset;
}

static void verifySweep(IOUSBInterfaceInterface700 **intf, int pipeOut, int pipeIn) {
    static const struct Check checks[] = {
        {0x04, 0x21, 7, -6,  4, 0,  1, "声道平衡"},
        {0x06, 0x22, 4,  3,  8, 0,  0, "亮度"},
        {0x07, 0x22, 6,  1,  2, 0,  0, "屏幕方向"},
        {0x09, 0x22, 5, 30, 45, 0,  0, "息屏时间"},
        {0x15, 0x23, 4,  3,  9, 50, 0, "屏幕偏移"},
    };
    int n = sizeof(checks) / sizeof(checks[0]);

    printf("验证上游文档中尚未确认的命令字（结束后自动恢复原值）\n\n");
    printf("%-10s %-8s %-8s %-8s %s\n", "项目", "原值", "写入", "读回", "结果");
    printf("---------------------------------------------------------\n");

    for (int i = 0; i < n; i++) {
        const struct Check *c = &checks[i];
        int ok = 0;
        int before = readField(intf, pipeOut, pipeIn, c->page, c->index,
                               c->isSigned, c->wireOffset, &ok);
        if (!ok) { printf("%-10s 读取原值失败，跳过\n", c->name); continue; }
        usleep(80000);

        // Writing the value it already holds proves nothing, so pick another.
        int target = c->testValue;
        if (target == before) target = c->fallbackValue;

        uint8_t frame[9] = {0};
        exchangeRaw(intf, pipeOut, pipeIn, c->cmd,
                    (uint8_t)(target + c->wireOffset), frame, 1, NULL);
        usleep(200000);

        int after = readField(intf, pipeOut, pipeIn, c->page, c->index,
                              c->isSigned, c->wireOffset, &ok);
        int pass = ok && after == target;
        printf("%-10s %-8d %-8d %-8d %s\n", c->name, before, target, after,
               pass ? "✅ 确认" : (after == before ? "❌ 无变化" : "⚠️ 值不符"));

        usleep(120000);
        exchangeRaw(intf, pipeOut, pipeIn, c->cmd,
                    (uint8_t)(before + c->wireOffset), frame, 1, NULL);
        usleep(200000);
    }
    printf("\n原值已恢复。\n");
}

int main(int argc, char **argv) {
    if (geteuid() != 0) {
        printf("需要 root：sudo %s\n", argv[0]);
        return 1;
    }

    int doVerify = (argc >= 2 && strcmp(argv[1], "verify") == 0);
    int haveWrite = (!doVerify && argc >= 3);
    uint8_t wcmd = haveWrite ? (uint8_t)strtol(argv[1], NULL, 16) : 0;
    uint8_t wval = haveWrite ? (uint8_t)strtol(argv[2], NULL, 10) : 0;

    IOUSBDeviceInterface **d = findDevice();
    if (!d) { printf("找不到设备\n"); return 1; }

    printf("捕获设备（会暂时中断音频）…\n");
    IOReturn r = (*d)->USBDeviceReEnumerate(d, kUSBReEnumerateCaptureDeviceMask);
    printf("  capture -> 0x%08X %s\n", r, r == kIOReturnSuccess ? "(OK)" : "(失败)");
    (*d)->Release(d);
    if (r != kIOReturnSuccess) return 2;

    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);
    sleep(2);   // let the device re-enumerate

    gDevice = findDevice();
    if (!gDevice) { printf("重新枚举后找不到设备（拔插一次恢复）\n"); return 3; }

    IOUSBInterfaceInterface700 **intf = findInterface();
    if (!intf) { printf("找不到接口 %d\n", IFACE); releaseDevice(); return 4; }

    r = (*intf)->USBInterfaceOpen(intf);
    printf("USBInterfaceOpen -> 0x%08X %s\n", r,
           r == kIOReturnSuccess ? "(成功！内核驱动已脱离)" : "(仍被占用)");
    if (r != kIOReturnSuccess) { releaseDevice(); return 5; }

    // Async completions are delivered through the run loop, so the interface's
    // event source has to be scheduled before any ReadPipeAsync.
    CFRunLoopSourceRef source = NULL;
    r = (*intf)->CreateInterfaceAsyncEventSource(intf, &source);
    if (r != kIOReturnSuccess || !source) {
        printf("CreateInterfaceAsyncEventSource -> 0x%08X\n", r);
        goto done;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);

    UInt8 n = 0;
    (*intf)->GetNumEndpoints(intf, &n);
    int pipeOut = 0, pipeIn = 0;
    for (UInt8 i = 1; i <= n; i++) {
        UInt8 dir, num, tt, iv; UInt16 mp;
        if ((*intf)->GetPipeProperties(intf, i, &dir, &num, &tt, &mp, &iv) != kIOReturnSuccess) continue;
        printf("  管道 %d: 端点 0x%02X %s type=%d max=%d\n", i,
               (unsigned)(num | (dir == kUSBIn ? 0x80 : 0)),
               dir == kUSBIn ? "IN" : "OUT", tt, mp);
        if (tt == kUSBInterrupt && dir == kUSBOut) pipeOut = i;
        if (tt == kUSBInterrupt && dir == kUSBIn) pipeIn = i;
    }
    if (!pipeOut || !pipeIn) { printf("端点不齐\n"); goto done; }
    printf("\n");

    if (doVerify) {
        verifySweep(intf, pipeOut, pipeIn);
    } else if (haveWrite) {
        printf("--- 写入前 ---\n");
        exchange(intf, pipeOut, pipeIn, 0xFF, 1, "读音频页");
        usleep(120000);
        exchange(intf, pipeOut, pipeIn, wcmd, wval, "写入");
        usleep(200000);
        printf("--- 写入后 ---\n");
        exchange(intf, pipeOut, pipeIn, 0xFF, 1, "读音频页");
    } else {
        for (uint8_t page = 0; page < 4; page++) {
            char label[32];
            snprintf(label, sizeof(label), "读页 %d", page);
            exchange(intf, pipeOut, pipeIn, 0xFF, page, label);
            usleep(60000);
        }
    }

done:
    (*intf)->USBInterfaceClose(intf);
    (*intf)->Release(intf);
    releaseDevice();
    return 0;
}
