// ICadeSteamLink — iPega PG-9083 como mando dentro de Steam Link.
//
// Fase 1 (posición 4, iCade): traduce teclas iCade -> mando virtual de SDL (digital).
// Fase 2 (posición 1, Android V3): lee el HID del Game Pad analógico con IOHIDManager
//         (la app Steam Link SÍ puede abrir el HID) y alimenta el mismo mando virtual
//         con sticks y gatillos analógicos, cruceta y todos los botones.
//
// Requisito de la fase 2: la preferencia EnableGamepads debe estar activa
// (com.apple.MobileBluetooth.debug) para que iPadOS cree el Game Pad en la posición 1.
// Ver docs/hardware-pg9083.md y docs/phase2-research.md.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <stddef.h>
#import <substrate.h>

#define ICSL_VERSION @"0.4.0"
#define ICSL_CONFIG_PATH @"/var/jb/etc/icadesteamlink.plist"
#define PG9083_VENDOR_ID 0x1949

#pragma mark - SDL3 (ABI mínima)

typedef uint32_t SDL_JoystickID;
typedef struct SDL_Joystick SDL_Joystick;
enum { SDL_JOYSTICK_TYPE_GAMEPAD = 1 };
enum { SDL_INIT_JOYSTICK = 0x200, SDL_INIT_GAMEPAD = 0x2000 };
enum { SDL_JOYSTICK_AXIS_MAX = 32767, SDL_JOYSTICK_AXIS_MIN = -32768 };
enum {
    SDL_GAMEPAD_BUTTON_SOUTH = 0, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH,
    SDL_GAMEPAD_BUTTON_BACK, SDL_GAMEPAD_BUTTON_GUIDE, SDL_GAMEPAD_BUTTON_START,
    SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_BUTTON_RIGHT_STICK,
    SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
    SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_DOWN, SDL_GAMEPAD_BUTTON_DPAD_LEFT, SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
};
enum {
    SDL_GAMEPAD_AXIS_LEFTX = 0, SDL_GAMEPAD_AXIS_LEFTY, SDL_GAMEPAD_AXIS_RIGHTX, SDL_GAMEPAD_AXIS_RIGHTY,
    SDL_GAMEPAD_AXIS_LEFT_TRIGGER, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
};

typedef struct {
    uint32_t version; uint16_t type; uint16_t padding; uint16_t vendor_id; uint16_t product_id;
    uint16_t naxes; uint16_t nbuttons; uint16_t nballs; uint16_t nhats; uint16_t ntouchpads; uint16_t nsensors;
    uint16_t padding2[2]; uint32_t button_mask; uint32_t axis_mask; const char *name;
    const void *touchpads; const void *sensors; void *userdata;
    void (*Update)(void *); void (*SetPlayerIndex)(void *, int); bool (*Rumble)(void *, uint16_t, uint16_t);
    bool (*RumbleTriggers)(void *, uint16_t, uint16_t); bool (*SetLED)(void *, uint8_t, uint8_t, uint8_t);
    bool (*SendEffect)(void *, const void *, int); bool (*SetSensorsEnabled)(void *, bool); void (*Cleanup)(void *);
} SDL_VirtualJoystickDesc;
_Static_assert(sizeof(SDL_VirtualJoystickDesc) == 136, "SDL_VirtualJoystickDesc (64 bits)");

static bool           (*orig_SDL_InitSubSystem)(uint32_t flags);
static SDL_JoystickID (*p_SDL_AttachVirtualJoystick)(const SDL_VirtualJoystickDesc *desc);
static bool           (*p_SDL_IsJoystickVirtual)(SDL_JoystickID instance_id);
static SDL_Joystick  *(*p_SDL_OpenJoystick)(SDL_JoystickID instance_id);
static bool           (*p_SDL_SetJoystickVirtualButton)(SDL_Joystick *joystick, int button, bool down);
static bool           (*p_SDL_SetJoystickVirtualAxis)(SDL_Joystick *joystick, int axis, int16_t value);
static const char    *(*p_SDL_GetError)(void);

#pragma mark - IOKit / IOHIDManager (ABI mínima; la app Steam Link puede abrir el HID)

typedef struct __IOHIDManager *IOHIDManagerRef;
typedef struct __IOHIDElement *IOHIDElementRef;
typedef struct __IOHIDValue   *IOHIDValueRef;
typedef uint32_t IOReturn; typedef uint32_t IOOptionBits;
extern IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef, IOOptionBits);
extern void      IOHIDManagerSetDeviceMatching(IOHIDManagerRef, CFDictionaryRef);
extern void      IOHIDManagerSetDispatchQueue(IOHIDManagerRef, dispatch_queue_t);
extern void      IOHIDManagerActivate(IOHIDManagerRef);
extern IOReturn  IOHIDManagerOpen(IOHIDManagerRef, IOOptionBits);
typedef void (*IOHIDValueCallback)(void *, IOReturn, void *, IOHIDValueRef);
extern void      IOHIDManagerRegisterInputValueCallback(IOHIDManagerRef, IOHIDValueCallback, void *);
extern IOHIDElementRef IOHIDValueGetElement(IOHIDValueRef);
extern CFIndex         IOHIDValueGetIntegerValue(IOHIDValueRef);
extern uint32_t        IOHIDElementGetUsagePage(IOHIDElementRef);
extern uint32_t        IOHIDElementGetUsage(IOHIDElementRef);

#pragma mark - Configuración y registro

static BOOL gEnabled = YES;
static BOOL gDebugLog = NO;
static dispatch_queue_t gLogQueue;
static NSFileHandle *gLogHandle;

static void ICSLLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ICSLLog(NSString *format, ...) {
    if (!gDebugLog || !gLogHandle) return;
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDate *now = [NSDate date];
    dispatch_async(gLogQueue, ^{
        static NSDateFormatter *fmt;
        if (!fmt) { fmt = [NSDateFormatter new]; fmt.dateFormat = @"HH:mm:ss.SSS"; }
        NSString *line = [NSString stringWithFormat:@"%@  %@\n", [fmt stringFromDate:now], message];
        @try { [gLogHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; } @catch (__unused id e) {}
    });
}

static void ICSLLoadConfig(void) {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:ICSL_CONFIG_PATH];
    if ([config[@"Enabled"] isKindOfClass:[NSNumber class]])  gEnabled = [config[@"Enabled"] boolValue];
    if ([config[@"DebugLog"] isKindOfClass:[NSNumber class]]) gDebugLog = [config[@"DebugLog"] boolValue];
    if (gDebugLog) {
        gLogQueue = dispatch_queue_create("ICadeSteamLink.log", DISPATCH_QUEUE_SERIAL);
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ICadeSteamLink.log"];
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        gLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    ICSLLog(@"=== ICadeSteamLink %@ === Enabled=%d", ICSL_VERSION, gEnabled);
}

#pragma mark - Mando virtual: índices de botón (orden que asigna SDL según button_mask)

enum {
    VB_A = 0, VB_B, VB_X, VB_Y, VB_BACK, VB_START, VB_L3, VB_R3, VB_LB, VB_RB,
    VB_DPAD_UP, VB_DPAD_DOWN, VB_DPAD_LEFT, VB_DPAD_RIGHT, VB_COUNT
};

static SDL_JoystickID gVirtualID;
static SDL_Joystick *gVirtualJoystick;

static void ICSLEnsureVirtualJoystick(void) {
    if (gVirtualID && p_SDL_IsJoystickVirtual(gVirtualID)) return;
    gVirtualID = 0; gVirtualJoystick = NULL;

    SDL_VirtualJoystickDesc desc; memset(&desc, 0, sizeof(desc));
    desc.version = sizeof(desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.vendor_id = 0x045E; desc.product_id = 0x028E;  // Xbox 360: mando conocido para SDL/Steam
    desc.naxes = 6;
    desc.nbuttons = VB_COUNT;
    desc.button_mask =
        (1u << SDL_GAMEPAD_BUTTON_SOUTH) | (1u << SDL_GAMEPAD_BUTTON_EAST) |
        (1u << SDL_GAMEPAD_BUTTON_WEST)  | (1u << SDL_GAMEPAD_BUTTON_NORTH) |
        (1u << SDL_GAMEPAD_BUTTON_BACK)  | (1u << SDL_GAMEPAD_BUTTON_START) |
        (1u << SDL_GAMEPAD_BUTTON_LEFT_STICK) | (1u << SDL_GAMEPAD_BUTTON_RIGHT_STICK) |
        (1u << SDL_GAMEPAD_BUTTON_LEFT_SHOULDER) | (1u << SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER) |
        (1u << SDL_GAMEPAD_BUTTON_DPAD_UP) | (1u << SDL_GAMEPAD_BUTTON_DPAD_DOWN) |
        (1u << SDL_GAMEPAD_BUTTON_DPAD_LEFT) | (1u << SDL_GAMEPAD_BUTTON_DPAD_RIGHT);
    desc.axis_mask =
        (1u << SDL_GAMEPAD_AXIS_LEFTX) | (1u << SDL_GAMEPAD_AXIS_LEFTY) |
        (1u << SDL_GAMEPAD_AXIS_RIGHTX) | (1u << SDL_GAMEPAD_AXIS_RIGHTY) |
        (1u << SDL_GAMEPAD_AXIS_LEFT_TRIGGER) | (1u << SDL_GAMEPAD_AXIS_RIGHT_TRIGGER);
    desc.name = "iPega PG-9083";

    SDL_JoystickID jid = p_SDL_AttachVirtualJoystick(&desc);
    if (!jid) { ICSLLog(@"ERROR AttachVirtualJoystick: %s", p_SDL_GetError ? p_SDL_GetError() : "?"); return; }
    SDL_Joystick *joy = p_SDL_OpenJoystick(jid);
    if (!joy) { ICSLLog(@"ERROR OpenJoystick: %s", p_SDL_GetError ? p_SDL_GetError() : "?"); return; }
    gVirtualID = jid; gVirtualJoystick = joy;
    ICSLLog(@"Mando virtual creado (id=%u, %d botones, 6 ejes)", jid, VB_COUNT);
}

// Helpers seguros (SDL3 bloquea el joystick internamente; se pueden llamar desde cualquier hilo).
static inline void VBtn(int button, bool down) {
    SDL_Joystick *j = gVirtualJoystick; if (j) p_SDL_SetJoystickVirtualButton(j, button, down);
}
static inline void VAxis(int axis, int16_t value) {
    SDL_Joystick *j = gVirtualJoystick; if (j) p_SDL_SetJoystickVirtualAxis(j, axis, value);
}
// Gatillos (un solo sentido, 0..255): HID 0 = suelto, 255 = a fondo.
static inline int16_t ScaleTrigger(CFIndex v) {
    long s = (long)v * 257 - 32896;
    if (s < SDL_JOYSTICK_AXIS_MIN) s = SDL_JOYSTICK_AXIS_MIN;
    if (s > SDL_JOYSTICK_AXIS_MAX) s = SDL_JOYSTICK_AXIS_MAX;
    return (int16_t)s;
}

// Calibración automática por eje de stick. Algunos sticks del PG-9083 tienen un
// recorrido asimétrico (p. ej. el stick derecho vertical llega a 0 hacia arriba
// pero solo a ~167 hacia abajo). Aprendemos el mínimo y el máximo vistos y
// estiramos cada mitad al rango completo, con el centro fijo en 128.
typedef struct { CFIndex minv, maxv; } ICSLAxisCal;
static ICSLAxisCal gCal[4] = { {128,128}, {128,128}, {128,128}, {128,128} };  // LEFTX,LEFTY,RIGHTX,RIGHTY

static inline int16_t CalibrateStick(int sdlAxis, CFIndex v) {
    ICSLAxisCal *c = &gCal[sdlAxis];
    if (v < c->minv) c->minv = v;
    if (v > c->maxv) c->maxv = v;
    const CFIndex center = 128;
    const long MIN_SPAN = 40;  // suelo: evita sensibilidad excesiva antes de calibrar y limita la amplificación
    long s;
    if (v >= center) { long span = c->maxv - center; if (span < MIN_SPAN) span = MIN_SPAN; s = (long)(v - center) * SDL_JOYSTICK_AXIS_MAX / span; }
    else             { long span = center - c->minv; if (span < MIN_SPAN) span = MIN_SPAN; s = (long)(v - center) * 32768 / span; }
    if (s < SDL_JOYSTICK_AXIS_MIN) s = SDL_JOYSTICK_AXIS_MIN;
    if (s > SDL_JOYSTICK_AXIS_MAX) s = SDL_JOYSTICK_AXIS_MAX;
    return (int16_t)s;
}

#pragma mark - Fase 2: lector HID del Game Pad analógico

static IOHIDManagerRef gHidManager;
static dispatch_queue_t gHidQueue;
static int gHatState = -1;

static void ICSLApplyHat(CFIndex hat) {
    // 0=N,1=NE,2=E,3=SE,4=S,5=SO,6=O,7=NO; fuera de 0..7 = centro.
    bool up = false, down = false, left = false, right = false;
    switch (hat) {
        case 0: up = true; break;              case 1: up = true; right = true; break;
        case 2: right = true; break;           case 3: right = true; down = true; break;
        case 4: down = true; break;            case 5: down = true; left = true; break;
        case 6: left = true; break;            case 7: left = true; up = true; break;
        default: break;  // centro
    }
    VBtn(VB_DPAD_UP, up); VBtn(VB_DPAD_DOWN, down); VBtn(VB_DPAD_LEFT, left); VBtn(VB_DPAD_RIGHT, right);
}

static void HidValueCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    @try {
        IOHIDElementRef el = IOHIDValueGetElement(value); if (!el) return;
        uint32_t page = IOHIDElementGetUsagePage(el), usage = IOHIDElementGetUsage(el);
        CFIndex v = IOHIDValueGetIntegerValue(value);
        if (page == 0x01) {           // Generic Desktop: sticks y cruceta
            switch (usage) {
                case 0x30: VAxis(SDL_GAMEPAD_AXIS_LEFTX,  CalibrateStick(SDL_GAMEPAD_AXIS_LEFTX,  v)); break;
                case 0x31: VAxis(SDL_GAMEPAD_AXIS_LEFTY,  CalibrateStick(SDL_GAMEPAD_AXIS_LEFTY,  v)); break;
                case 0x32: VAxis(SDL_GAMEPAD_AXIS_RIGHTX, CalibrateStick(SDL_GAMEPAD_AXIS_RIGHTX, v)); break;
                case 0x35: VAxis(SDL_GAMEPAD_AXIS_RIGHTY, CalibrateStick(SDL_GAMEPAD_AXIS_RIGHTY, v)); break;
                case 0x39: if (v != gHatState) { gHatState = (int)v; ICSLApplyHat(v); } break;
                default: break;
            }
        } else if (page == 0x02) {    // Simulation: gatillos analógicos
            if (usage == 0xC5) VAxis(SDL_GAMEPAD_AXIS_LEFT_TRIGGER,  ScaleTrigger(v));   // L2 (Brake)
            if (usage == 0xC4) VAxis(SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, ScaleTrigger(v));   // R2 (Accelerator)
        } else if (page == 0x09) {    // Botones
            bool down = (v != 0);
            switch (usage) {
                case 1:  VBtn(VB_A, down); break;      case 2:  VBtn(VB_B, down); break;
                case 4:  VBtn(VB_X, down); break;      case 5:  VBtn(VB_Y, down); break;
                case 7:  VBtn(VB_LB, down); break;     case 8:  VBtn(VB_RB, down); break;
                case 11: VBtn(VB_BACK, down); break;   case 12: VBtn(VB_START, down); break;
                case 14: VBtn(VB_L3, down); break;     case 15: VBtn(VB_R3, down); break;
                // 9/10 (L2/R2 digitales) se ignoran: usamos los ejes analógicos de gatillo.
                default: break;
            }
        }
    } @catch (__unused id e) {}
}

static void ICSLStartHidReader(void) {
    if (gHidManager) return;
    gHidQueue = dispatch_queue_create("ICadeSteamLink.hid", DISPATCH_QUEUE_SERIAL);
    IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    if (!mgr) { ICSLLog(@"ERROR: IOHIDManagerCreate falló"); return; }
    IOHIDManagerSetDeviceMatching(mgr, (__bridge CFDictionaryRef)@{ @"VendorID": @(PG9083_VENDOR_ID) });
    IOHIDManagerRegisterInputValueCallback(mgr, HidValueCallback, NULL);
    IOHIDManagerSetDispatchQueue(mgr, gHidQueue);   // orden correcto: cola -> Open -> Activate
    IOReturn r = IOHIDManagerOpen(mgr, 0);
    IOHIDManagerActivate(mgr);
    gHidManager = mgr;
    ICSLLog(@"Lector HID: IOHIDManagerOpen -> 0x%x (%@)", r,
            r == 0 ? @"OK, leyendo el Game Pad analógico" : @"sin acceso (posición 4 iCade seguirá funcionando)");
}

#pragma mark - Fase 1: decodificador iCade (posición 4)

typedef struct { int button; int triggerAxis; bool isTrigger; } ICSLMap;

static bool ICSLDecodeICade(long hid, ICSLMap *out, bool *pressed) {
    // a=0x04 .. z=0x1D
    #define HID(c) (0x04 + ((c) - 'a'))
    static const struct { char down, up; int button; int trig; bool isTrig; } t[] = {
        { 'w','e', VB_DPAD_UP,   0,0 }, { 'x','z', VB_DPAD_DOWN, 0,0 },
        { 'a','q', VB_DPAD_LEFT, 0,0 }, { 'd','c', VB_DPAD_RIGHT,0,0 },
        { 'h','r', VB_A,0,0 }, { 'u','f', VB_B,0,0 }, { 'y','t', VB_X,0,0 }, { 'j','n', VB_Y,0,0 },
        { 'i','m', VB_LB,0,0 }, { 'k','p', VB_RB,0,0 },
        { 'o','g', 0, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, 1 }, { 'l','v', 0, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, 1 },
    };
    for (size_t i = 0; i < sizeof(t)/sizeof(t[0]); i++) {
        if (hid == HID(t[i].down)) { *out = (ICSLMap){t[i].button,t[i].trig,t[i].isTrig}; *pressed = true;  return true; }
        if (hid == HID(t[i].up))   { *out = (ICSLMap){t[i].button,t[i].trig,t[i].isTrig}; *pressed = false; return true; }
    }
    return false;
    #undef HID
}

static void ICSLApplyICade(ICSLMap m, bool pressed) {
    if (m.isTrigger) VAxis(m.triggerAxis, pressed ? SDL_JOYSTICK_AXIS_MAX : SDL_JOYSTICK_AXIS_MIN);
    else             VBtn(m.button, pressed);
}

static void (*orig_sendEvent)(UIApplication *, SEL, UIEvent *);
static void hook_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if (![event isKindOfClass:[UIPressesEvent class]]) { orig_sendEvent(self, _cmd, event); return; }
    NSSet<UIPress *> *presses = ((UIPressesEvent *)event).allPresses;
    NSMutableArray *acts = [NSMutableArray array];
    BOOL allICade = presses.count > 0;
    for (UIPress *press in presses) {
        UIKey *key = press.key; ICSLMap m; bool pr;
        if (!key || key.modifierFlags != 0 || !ICSLDecodeICade((long)key.keyCode, &m, &pr)) { allICade = NO; break; }
        if (press.phase == UIPressPhaseBegan) {
            [acts addObject:@[ [NSValue valueWithBytes:&m objCType:@encode(ICSLMap)], @(pr) ]];
        }
    }
    if (!allICade) { orig_sendEvent(self, _cmd, event); return; }
    for (NSArray *a in acts) { ICSLMap m; [a[0] getValue:&m size:sizeof(m)]; ICSLApplyICade(m, [a[1] boolValue]); }
    // consumido: la tecla iCade no llega a la app ni al PC.
}

typedef void (^ICSLKeyHandler)(GCKeyboardInput *, GCControllerButtonInput *, GCKeyCode, BOOL);
static void (*orig_setKeyChangedHandler)(GCKeyboardInput *, SEL, ICSLKeyHandler);
static void hook_setKeyChangedHandler(GCKeyboardInput *self, SEL _cmd, ICSLKeyHandler handler) {
    ICSLKeyHandler wrapped = handler;
    if (handler) wrapped = ^(GCKeyboardInput *kb, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) {
        ICSLMap m; bool pr;
        if (ICSLDecodeICade((long)code, &m, &pr)) { if (pressed) ICSLApplyICade(m, pr); return; }
        handler(kb, key, code, pressed);
    };
    orig_setKeyChangedHandler(self, _cmd, wrapped);
}

#pragma mark - Hook de SDL + arranque

static bool hook_SDL_InitSubSystem(uint32_t flags) {
    bool ok = orig_SDL_InitSubSystem(flags);
    if (ok && (flags & (SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD))) {
        dispatch_async(dispatch_get_main_queue(), ^{ ICSLEnsureVirtualJoystick(); });
    }
    return ok;
}

#define LOAD_SDL(sym) (p_##sym = (__typeof__(p_##sym))dlsym(RTLD_DEFAULT, #sym))

__attribute__((constructor)) static void ICadeSteamLinkInit(void) {
    @autoreleasepool {
        ICSLLoadConfig();
        if (!gEnabled) { ICSLLog(@"Desactivado por configuración"); return; }

        void *initSS = dlsym(RTLD_DEFAULT, "SDL_InitSubSystem");
        LOAD_SDL(SDL_AttachVirtualJoystick); LOAD_SDL(SDL_IsJoystickVirtual); LOAD_SDL(SDL_OpenJoystick);
        LOAD_SDL(SDL_SetJoystickVirtualButton); LOAD_SDL(SDL_SetJoystickVirtualAxis); LOAD_SDL(SDL_GetError);
        if (!initSS || !p_SDL_AttachVirtualJoystick || !p_SDL_IsJoystickVirtual || !p_SDL_OpenJoystick ||
            !p_SDL_SetJoystickVirtualButton || !p_SDL_SetJoystickVirtualAxis) {
            ICSLLog(@"ERROR: no encontré SDL3; el tweak no hará nada"); return;
        }
        MSHookFunction(initSS, (void *)hook_SDL_InitSubSystem, (void **)&orig_SDL_InitSubSystem);
        MSHookMessageEx([UIApplication class], @selector(sendEvent:), (IMP)hook_sendEvent, (IMP *)&orig_sendEvent);
        MSHookMessageEx([GCKeyboardInput class], @selector(setKeyChangedHandler:),
                        (IMP)hook_setKeyChangedHandler, (IMP *)&orig_setKeyChangedHandler);
        // Lector HID de la fase 2: arranca con un pequeño retardo tras cargar la app.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ICSLStartHidReader(); });
        ICSLLog(@"Hooks instalados (SDL, UIKit, GameController) + lector HID programado");
    }
}
