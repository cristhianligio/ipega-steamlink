// BBGamepadProbe — tweak de diagnóstico de la fase 2 (SOLO LECTURA).
//
// Se inyecta ÚNICAMENTE en backboardd, que sí tiene permiso para leer el HID.
// Abre el PG-9083 en modo COMPARTIDO (no "seize": no le quita la entrada al
// sistema) y registra los valores de sticks/botones en un archivo de log.
//
// Seguridad:
//   - No engancha (hook) ninguna función de backboardd: es un cliente HID aparte.
//   - Trabaja en su propia cola (dispatch queue), nunca en el hilo principal.
//   - Si algo falla al abrir, lo registra y se queda quieto, sin tocar nada más.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>

typedef struct __IOHIDManager *IOHIDManagerRef;
typedef struct __IOHIDDevice  *IOHIDDeviceRef;
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

static NSFileHandle *gLog;
static dispatch_queue_t gQueue;

static void BBLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void BBLog(NSString *fmt, ...) {
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
        if (page != 0x01 && page != 0x02 && page != 0x09) return;  // solo ejes/gatillos/botones
        CFIndex v = IOHIDValueGetIntegerValue(value);
        BBLog(@"%@ = %ld  [%ld..%ld]", Describe(page, usage), (long)v,
              (long)IOHIDElementGetLogicalMin(el), (long)IOHIDElementGetLogicalMax(el));
    } @catch (__unused id e) {}
}

static void BBSetup(void) {
    @autoreleasepool {
        NSString *path = @"/var/mobile/Documents/BBGamepadProbe.log";
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        gLog = [NSFileHandle fileHandleForWritingAtPath:path];
        BBLog(@"=== BBGamepadProbe cargado en %@ ===", [NSProcessInfo processInfo].processName);

        IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0);
        if (!mgr) { BBLog(@"ERROR: IOHIDManagerCreate falló"); return; }

        NSDictionary *match = @{ @"VendorID": @(PG9083_VENDOR_ID) };
        IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)match);
        IOHIDManagerRegisterInputValueCallback(mgr, ValueCallback, NULL);
        IOHIDManagerSetDispatchQueue(mgr, gQueue);
        IOHIDManagerActivate(mgr);

        IOReturn r = IOHIDManagerOpen(mgr, 0);  // 0 = compartido, SOLO LECTURA (no seize)
        if (r != 0) {
            BBLog(@"ERROR: IOHIDManagerOpen devolvió 0x%x (en backboardd no debería)", r);
            return;
        }
        BBLog(@"IOHIDManagerOpen OK: escuchando el PG-9083 (vendor 0x%x)", PG9083_VENDOR_ID);
    }
}

__attribute__((constructor)) static void BBGamepadProbeInit(void) {
    @autoreleasepool {
        // Doble comprobación: solo actuamos dentro de backboardd.
        NSString *exe = [[NSBundle mainBundle] executablePath].lastPathComponent;
        if (![exe isEqualToString:@"backboardd"]) return;
        gQueue = dispatch_queue_create("org.ipega-steamlink.bbprobe", DISPATCH_QUEUE_SERIAL);
        // Diferimos el arranque para no bloquear el inicio de backboardd.
        dispatch_async(gQueue, ^{ BBSetup(); });
    }
}
