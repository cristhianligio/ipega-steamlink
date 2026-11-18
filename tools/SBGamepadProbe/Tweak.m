// SBGamepadProbe — tweak de diagnóstico de la fase 2 (SOLO LECTURA), para SpringBoard.
//
// SpringBoard es CLIENTE del sistema de eventos HID (no el servidor, como backboardd),
// así que abrir aquí un cliente HID no provoca el bloqueo que vimos en backboardd.
// Abre el PG-9083 en modo COMPARTIDO (no "seize") y registra sus valores en un log.
//
// Redes de seguridad:
//   - INTERRUPTOR DE APAGADO: si existe el archivo /var/mobile/Documents/gpprobe.off,
//     el tweak no hace nada. Ese archivo lo puede crear el usuario por SSH SIN sudo
//     (touch), así que permite desactivarlo sin reinstalar nada.
//   - Arranque diferido 5 s, para no tocar HID durante el inicio de SpringBoard.
//   - Cola propia (nunca el hilo principal). No engancha ninguna función. try/catch.

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

extern IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef value);
extern CFIndex         IOHIDValueGetIntegerValue(IOHIDValueRef value);
extern uint32_t        IOHIDElementGetUsagePage(IOHIDElementRef element);
extern uint32_t        IOHIDElementGetUsage(IOHIDElementRef element);
extern CFIndex         IOHIDElementGetLogicalMin(IOHIDElementRef element);
extern CFIndex         IOHIDElementGetLogicalMax(IOHIDElementRef element);

#define PG9083_VENDOR_ID  0x1949
#define KILL_SWITCH       @"/var/mobile/Documents/gpprobe.off"

static NSFileHandle *gLog;
static dispatch_queue_t gQueue;

static void SBLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void SBLog(NSString *fmt, ...) {
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

static void ValueCallback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    @try {
        IOHIDElementRef el = IOHIDValueGetElement(value);
        if (!el) return;
        uint32_t page = IOHIDElementGetUsagePage(el), usage = IOHIDElementGetUsage(el);
        if (page != 0x01 && page != 0x02 && page != 0x09) return;
        CFIndex v = IOHIDValueGetIntegerValue(value);
        SBLog(@"%@ = %ld  [%ld..%ld]", Describe(page, usage), (long)v,
              (long)IOHIDElementGetLogicalMin(el), (long)IOHIDElementGetLogicalMax(el));
    } @catch (__unused id e) {}
}

static void SBSetup(void) {
    @autoreleasepool {
        @try {
            NSString *path = @"/var/mobile/Documents/SBGamepadProbe.log";
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
            gLog = [NSFileHandle fileHandleForWritingAtPath:path];
            SBLog(@"=== SBGamepadProbe cargado en SpringBoard ===");

            IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0);
            if (!mgr) { SBLog(@"ERROR: IOHIDManagerCreate falló"); return; }
            IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)@{ @"VendorID": @(PG9083_VENDOR_ID) });
            IOHIDManagerRegisterInputValueCallback(mgr, ValueCallback, NULL);
            IOHIDManagerSetDispatchQueue(mgr, gQueue);
            IOHIDManagerActivate(mgr);
            IOReturn r = IOHIDManagerOpen(mgr, 0);  // 0 = compartido, solo lectura
            if (r != 0) { SBLog(@"ERROR: IOHIDManagerOpen devolvió 0x%x", r); return; }
            SBLog(@"IOHIDManagerOpen OK: escuchando el PG-9083 (vendor 0x%x)", PG9083_VENDOR_ID);
        } @catch (id e) { SBLog(@"EXCEPCION en setup: %@", e); }
    }
}

__attribute__((constructor)) static void SBGamepadProbeInit(void) {
    @autoreleasepool {
        NSString *exe = [[NSBundle mainBundle] executablePath].lastPathComponent;
        if (![exe isEqualToString:@"SpringBoard"]) return;
        // Interruptor de apagado: si existe el archivo, no hacer nada.
        if ([[NSFileManager defaultManager] fileExistsAtPath:KILL_SWITCH]) return;
        gQueue = dispatch_queue_create("org.ipega-steamlink.sbprobe", DISPATCH_QUEUE_SERIAL);
        // Arranque diferido 5 s, para que SpringBoard termine de iniciarse.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), gQueue, ^{ SBSetup(); });
    }
}
