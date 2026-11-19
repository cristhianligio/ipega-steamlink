// SLGamepadProbe — diagnóstico de la fase 2 (SOLO LECTURA), alojado en Steam Link.
//
// Objetivo: averiguar si, desde DENTRO de la app Steam Link, se puede abrir y leer
// el PG-9083 (posición 1, analógico) con IOHIDManager. Si el sandbox lo permite,
// el puente de la fase 2 cabría entero en la app, sin tocar procesos del sistema.
//
// API de IOHIDManager CORREGIDA respecto a los intentos anteriores: el orden
// correcto con cola de despacho es SetDispatchQueue -> Open -> Activate
// (antes se hacía Activate -> Open, que desestabilizaba el proceso).
//
// Como esto corre en una app, cualquier fallo solo afecta a Steam Link (se
// recupera reabriéndola); no hay riesgo de respring ni Safe Mode.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

typedef struct __IOHIDManager *IOHIDManagerRef;
typedef struct __IOHIDElement *IOHIDElementRef;
typedef struct __IOHIDValue   *IOHIDValueRef;
typedef uint32_t IOReturn;
typedef uint32_t IOOptionBits;

extern IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef allocator, IOOptionBits options);
extern void      IOHIDManagerSetDeviceMatching(IOHIDManagerRef manager, CFDictionaryRef matching);
extern void      IOHIDManagerSetDispatchQueue(IOHIDManagerRef manager, dispatch_queue_t queue);
extern void      IOHIDManagerActivate(IOHIDManagerRef manager);
extern IOReturn  IOHIDManagerOpen(IOHIDManagerRef manager, IOOptionBits options);
typedef void (*IOHIDValueCallback)(void *context, IOReturn result, void *sender, IOHIDValueRef value);
extern void      IOHIDManagerRegisterInputValueCallback(IOHIDManagerRef manager, IOHIDValueCallback callback, void *context);
typedef void (*IOHIDDeviceCallbackC)(void *context, IOReturn result, void *sender, void *device);
extern void      IOHIDManagerRegisterDeviceMatchingCallback(IOHIDManagerRef manager, IOHIDDeviceCallbackC callback, void *context);

extern IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef value);
extern CFIndex         IOHIDValueGetIntegerValue(IOHIDValueRef value);
extern uint32_t        IOHIDElementGetUsagePage(IOHIDElementRef element);
extern uint32_t        IOHIDElementGetUsage(IOHIDElementRef element);

#define PG9083_VENDOR_ID  0x1949

static NSFileHandle *gLog;
static dispatch_queue_t gQueue;

static void SLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void SLog(NSString *fmt, ...) {
    if (!gLog) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df;
    if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss.SSS"; }
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], msg];
    @try { [gLog writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (__unused id e) {}
}

static NSString *Describe(uint32_t page, uint32_t usage) {
    if (page == 0x01) switch (usage) {
        case 0x30: return @"X stick-izq-H"; case 0x31: return @"Y stick-izq-V";
        case 0x32: return @"Z stick-der-H"; case 0x35: return @"Rz stick-der-V";
        case 0x39: return @"Hat cruceta";   default: break;
    }
    if (page == 0x02) { if (usage==0xC4) return @"Gatillo der"; if (usage==0xC5) return @"Gatillo izq"; }
    if (page == 0x09) return [NSString stringWithFormat:@"Boton %u", usage];
    return [NSString stringWithFormat:@"p%02x/u%02x", page, usage];
}

static void DeviceMatched(void *context, IOReturn result, void *sender, void *device) {
    SLog(@"Dispositivo PG-9083 emparejado con el IOHIDManager (result=0x%x)", result);
}

static void ValueCallback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    @try {
        IOHIDElementRef el = IOHIDValueGetElement(value);
        if (!el) return;
        uint32_t page = IOHIDElementGetUsagePage(el), usage = IOHIDElementGetUsage(el);
        if (page != 0x01 && page != 0x02 && page != 0x09) return;
        SLog(@"%@ = %ld", Describe(page, usage), (long)IOHIDValueGetIntegerValue(value));
    } @catch (__unused id e) {}
}

static void SLSetup(void) {
    @autoreleasepool {
        @try {
            IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0);
            if (!mgr) { SLog(@"ERROR: IOHIDManagerCreate falló"); return; }
            IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)@{ @"VendorID": @(PG9083_VENDOR_ID) });
            IOHIDManagerRegisterDeviceMatchingCallback(mgr, DeviceMatched, NULL);
            IOHIDManagerRegisterInputValueCallback(mgr, ValueCallback, NULL);
            // --- Orden CORRECTO: cola -> Open -> Activate ---
            IOHIDManagerSetDispatchQueue(mgr, gQueue);
            IOReturn r = IOHIDManagerOpen(mgr, 0);  // 0 = compartido, solo lectura
            SLog(@"IOHIDManagerOpen -> 0x%x (%@)", r,
                 r == 0 ? @"OK: la app PUEDE leer el HID" :
                 r == 0xe00002e2 ? @"NotPermitted: el sandbox de la app lo bloquea" : @"otro error");
            IOHIDManagerActivate(mgr);
            if (r == 0) SLog(@"Escuchando valores del PG-9083... mueve los sticks.");
        } @catch (id e) { SLog(@"EXCEPCION en setup: %@", e); }
    }
}

__attribute__((constructor)) static void SLGamepadProbeInit(void) {
    @autoreleasepool {
        NSString *path = @"/var/mobile/Documents/SLGamepadProbe.log";
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        gLog = [NSFileHandle fileHandleForWritingAtPath:path];
        SLog(@"=== SLGamepadProbe cargado en %@ ===", [NSProcessInfo processInfo].processName);
        gQueue = dispatch_queue_create("org.ipega-steamlink.slprobe", DISPATCH_QUEUE_SERIAL);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), gQueue, ^{ SLSetup(); });
    }
}
