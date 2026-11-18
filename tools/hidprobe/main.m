// hidprobe — herramienta de diagnóstico de la fase 2.
//
// Se ejecuta como root en el iPad y usa IOHIDManager para ver si un proceso con
// permisos puede leer los valores (incluidos los analógicos) del Game Pad PG-9083
// que crea iPadOS cuando EnableGamepads está activo (ver docs/phase2-research.md).
//
// Imprime, por cada valor que cambia: página de uso, uso, valor y nombre del
// dispositivo. Pensado para ejecutarse unos segundos mientras se mueve el control.
//
// No modifica nada: solo abre los dispositivos HID en modo lectura.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// --- Prototipos de IOKit/IOHIDManager (el SDK de Theos no trae los headers, pero
//     la librería IOKit sí exporta estos símbolos) ---
typedef struct __IOHIDManager *IOHIDManagerRef;
typedef struct __IOHIDDevice  *IOHIDDeviceRef;
typedef struct __IOHIDElement *IOHIDElementRef;
typedef struct __IOHIDValue   *IOHIDValueRef;
typedef uint32_t IOReturn;
typedef uint32_t IOOptionBits;

extern IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef allocator, IOOptionBits options);
extern void      IOHIDManagerSetDeviceMatching(IOHIDManagerRef manager, CFDictionaryRef matching);
extern void      IOHIDManagerScheduleWithRunLoop(IOHIDManagerRef manager, CFRunLoopRef runLoop, CFStringRef mode);
extern IOReturn  IOHIDManagerOpen(IOHIDManagerRef manager, IOOptionBits options);
typedef void (*IOHIDValueCallback)(void *context, IOReturn result, void *sender, IOHIDValueRef value);
extern void      IOHIDManagerRegisterInputValueCallback(IOHIDManagerRef manager, IOHIDValueCallback callback, void *context);
typedef void (*IOHIDDeviceCallback)(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
extern void      IOHIDManagerRegisterDeviceMatchingCallback(IOHIDManagerRef manager, IOHIDDeviceCallback callback, void *context);

extern IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef value);
extern CFIndex         IOHIDValueGetIntegerValue(IOHIDValueRef value);
extern uint32_t        IOHIDElementGetUsagePage(IOHIDElementRef element);
extern uint32_t        IOHIDElementGetUsage(IOHIDElementRef element);
extern CFIndex         IOHIDElementGetLogicalMin(IOHIDElementRef element);
extern CFIndex         IOHIDElementGetLogicalMax(IOHIDElementRef element);
extern CFTypeRef       IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key);

static NSString *UsagePageName(uint32_t page) {
    switch (page) {
        case 0x01: return @"GenericDesktop";
        case 0x02: return @"Simulation";
        case 0x06: return @"GenericDeviceControls";
        case 0x07: return @"Keyboard";
        case 0x09: return @"Button";
        case 0x0C: return @"Consumer";
        default:   return [NSString stringWithFormat:@"0x%02x", page];
    }
}

static NSString *UsageName(uint32_t page, uint32_t usage) {
    if (page == 0x01) {
        switch (usage) {
            case 0x30: return @"X (stick izq. horizontal)";
            case 0x31: return @"Y (stick izq. vertical)";
            case 0x32: return @"Z (stick der. horizontal)";
            case 0x35: return @"Rz (stick der. vertical)";
            case 0x33: return @"Rx";
            case 0x34: return @"Ry";
            case 0x39: return @"Hat (cruceta)";
            default: break;
        }
    }
    if (page == 0x02) {
        if (usage == 0xC4) return @"Acelerador (gatillo der.)";
        if (usage == 0xC5) return @"Freno (gatillo izq.)";
    }
    if (page == 0x09) return [NSString stringWithFormat:@"Botón %u", usage];
    return [NSString stringWithFormat:@"uso 0x%02x", usage];
}

static void ValueCallback(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (!element) return;
    uint32_t page = IOHIDElementGetUsagePage(element);
    uint32_t usage = IOHIDElementGetUsage(element);
    // Ignorar ruido de otras páginas internas.
    if (page != 0x01 && page != 0x02 && page != 0x09 && page != 0x0C) return;
    CFIndex v = IOHIDValueGetIntegerValue(value);
    CFIndex lo = IOHIDElementGetLogicalMin(element);
    CFIndex hi = IOHIDElementGetLogicalMax(element);
    printf("  %-16s  %-28s  valor=%4ld  [%ld..%ld]\n",
           UsagePageName(page).UTF8String, UsageName(page, usage).UTF8String,
           (long)v, (long)lo, (long)hi);
    fflush(stdout);
}

static void DeviceMatchedCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    CFTypeRef name = IOHIDDeviceGetProperty(device, CFSTR("Product"));
    printf("Dispositivo HID abierto: %s\n",
           name ? [(__bridge NSString *)name UTF8String] : "(sin nombre)");
    fflush(stdout);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int seconds = (argc > 1) ? atoi(argv[1]) : 20;
        printf("hidprobe: escuchando eventos HID durante %d s. Mueve los sticks y pulsa botones.\n", seconds);
        fflush(stdout);

        IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, 0);
        if (!manager) { fprintf(stderr, "ERROR: IOHIDManagerCreate falló\n"); return 1; }

        IOHIDManagerSetDeviceMatching(manager, NULL);  // todos los dispositivos
        IOHIDManagerRegisterDeviceMatchingCallback(manager, DeviceMatchedCallback, NULL);
        IOHIDManagerRegisterInputValueCallback(manager, ValueCallback, NULL);
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

        IOReturn r = IOHIDManagerOpen(manager, 0);
        if (r != 0) {
            fprintf(stderr, "ERROR: IOHIDManagerOpen devolvió 0x%x (¿faltan entitlements?)\n", r);
            return 2;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
        printf("hidprobe: fin.\n");
    }
    return 0;
}
