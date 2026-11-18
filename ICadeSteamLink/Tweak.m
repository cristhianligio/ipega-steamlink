// ICadeSteamLink — fase 1 del proyecto ipega-steamlink.
//
// Convierte las pulsaciones de teclado iCade del iPega PG-9083 (interruptor en la
// posición "Android & PC") en un mando virtual de SDL3 dentro de Steam Link.
//
// Arquitectura (ver docs/architecture-phase1.md):
//   [A] Interceptores: -[UIApplication sendEvent:] y -[GCKeyboardInput setKeyChangedHandler:].
//       Las teclas iCade se consumen y NO llegan a la app (ni a Qt, ni a SDL, ni al PC).
//   [B] Decodificador: código HID de la tecla -> (botón, pulsado/soltado).
//   [C] Estado: qué botones están pulsados (solo se toca en el hilo principal).
//   [D] Mando virtual: SDL_AttachVirtualJoystick (SDL3 está en Steam Link.app/Frameworks).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <dlfcn.h>
#import <stddef.h>
#import <substrate.h>

#define ICSL_VERSION @"0.2.0"
#define ICSL_CONFIG_PATH @"/var/jb/etc/icadesteamlink.plist"

#pragma mark - Definiciones mínimas de SDL3 (copiadas de SDL_joystick.h / SDL_gamepad.h, ABI de SDL 3.x)

typedef uint32_t SDL_JoystickID;
typedef struct SDL_Joystick SDL_Joystick;

enum { SDL_JOYSTICK_TYPE_GAMEPAD = 1 };
enum { SDL_INIT_JOYSTICK = 0x200, SDL_INIT_GAMEPAD = 0x2000 };
enum { SDL_JOYSTICK_AXIS_MAX = 32767, SDL_JOYSTICK_AXIS_MIN = -32768 };

// SDL_GamepadButton
enum {
    SDL_GAMEPAD_BUTTON_SOUTH = 0, SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_WEST, SDL_GAMEPAD_BUTTON_NORTH,
    SDL_GAMEPAD_BUTTON_BACK, SDL_GAMEPAD_BUTTON_GUIDE, SDL_GAMEPAD_BUTTON_START,
    SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_BUTTON_RIGHT_STICK,
    SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
    SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_DOWN, SDL_GAMEPAD_BUTTON_DPAD_LEFT, SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
};
// SDL_GamepadAxis
enum {
    SDL_GAMEPAD_AXIS_LEFTX = 0, SDL_GAMEPAD_AXIS_LEFTY, SDL_GAMEPAD_AXIS_RIGHTX, SDL_GAMEPAD_AXIS_RIGHTY,
    SDL_GAMEPAD_AXIS_LEFT_TRIGGER, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
};

typedef struct {
    uint32_t version;
    uint16_t type;
    uint16_t padding;
    uint16_t vendor_id;
    uint16_t product_id;
    uint16_t naxes;
    uint16_t nbuttons;
    uint16_t nballs;
    uint16_t nhats;
    uint16_t ntouchpads;
    uint16_t nsensors;
    uint16_t padding2[2];
    uint32_t button_mask;
    uint32_t axis_mask;
    const char *name;
    const void *touchpads;
    const void *sensors;
    void *userdata;
    void (*Update)(void *userdata);
    void (*SetPlayerIndex)(void *userdata, int player_index);
    bool (*Rumble)(void *userdata, uint16_t low, uint16_t high);
    bool (*RumbleTriggers)(void *userdata, uint16_t left, uint16_t right);
    bool (*SetLED)(void *userdata, uint8_t r, uint8_t g, uint8_t b);
    bool (*SendEffect)(void *userdata, const void *data, int size);
    bool (*SetSensorsEnabled)(void *userdata, bool enabled);
    void (*Cleanup)(void *userdata);
} SDL_VirtualJoystickDesc;

_Static_assert(sizeof(SDL_VirtualJoystickDesc) == 136, "SDL_VirtualJoystickDesc (64 bits)");
_Static_assert(offsetof(SDL_VirtualJoystickDesc, name) == 40, "SDL_VirtualJoystickDesc layout");

static bool           (*orig_SDL_InitSubSystem)(uint32_t flags);
static SDL_JoystickID (*p_SDL_AttachVirtualJoystick)(const SDL_VirtualJoystickDesc *desc);
static bool           (*p_SDL_IsJoystickVirtual)(SDL_JoystickID instance_id);
static SDL_Joystick  *(*p_SDL_OpenJoystick)(SDL_JoystickID instance_id);
static bool           (*p_SDL_SetJoystickVirtualButton)(SDL_Joystick *joystick, int button, bool down);
static bool           (*p_SDL_SetJoystickVirtualAxis)(SDL_Joystick *joystick, int axis, int16_t value);
static const char    *(*p_SDL_GetError)(void);

#pragma mark - Configuración y registro

static BOOL gEnabled = YES;
static BOOL gDpadToLeftStick = NO;
static BOOL gDebugLog = NO;

static dispatch_queue_t gLogQueue;
static NSFileHandle *gLogHandle;

static void ICSLLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ICSLLog(NSString *format, ...) {
    if (!gDebugLog || !gLogHandle) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDate *now = [NSDate date];
    dispatch_async(gLogQueue, ^{
        static NSDateFormatter *formatter;
        if (!formatter) {
            formatter = [NSDateFormatter new];
            formatter.dateFormat = @"HH:mm:ss.SSS";
        }
        NSString *line = [NSString stringWithFormat:@"%@  %@\n", [formatter stringFromDate:now], message];
        [gLogHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    });
}

static void ICSLLoadConfig(void) {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:ICSL_CONFIG_PATH];
    if ([config[@"Enabled"] isKindOfClass:[NSNumber class]])         gEnabled = [config[@"Enabled"] boolValue];
    if ([config[@"DpadToLeftStick"] isKindOfClass:[NSNumber class]]) gDpadToLeftStick = [config[@"DpadToLeftStick"] boolValue];
    if ([config[@"DebugLog"] isKindOfClass:[NSNumber class]])        gDebugLog = [config[@"DebugLog"] boolValue];

    if (gDebugLog) {
        gLogQueue = dispatch_queue_create("ICadeSteamLink.log", DISPATCH_QUEUE_SERIAL);
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ICadeSteamLink.log"];
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        gLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    ICSLLog(@"=== ICadeSteamLink %@ ===", ICSL_VERSION);
    ICSLLog(@"Configuración %@: %@ | Enabled=%d DpadToLeftStick=%d DebugLog=%d",
            ICSL_CONFIG_PATH, config ? @"leída" : @"no encontrada (valores por defecto)",
            gEnabled, gDpadToLeftStick, gDebugLog);
}

#pragma mark - [B] Decodificador iCade (códigos de uso HID de teclado)

// Botones del mando virtual. El orden coincide con el que SDL3 asigna a un mando
// virtual de tipo GAMEPAD según button_mask (ver SDL_virtualjoystick.c).
typedef enum {
    ICSLButtonA = 0, ICSLButtonB, ICSLButtonX, ICSLButtonY,
    ICSLButtonLB, ICSLButtonRB,
    ICSLButtonDpadUp, ICSLButtonDpadDown, ICSLButtonDpadLeft, ICSLButtonDpadRight,
    ICSLButtonCount,
    // Los gatillos son ejes, no botones:
    ICSLTriggerLeft = 100, ICSLTriggerRight,
} ICSLControl;

typedef struct {
    ICSLControl control;
    bool pressed;
} ICSLAction;

// Códigos HID: a=0x04 ... z=0x1D.
#define HID(letter) (0x04 + ((letter) - 'a'))

static bool ICSLDecode(long hidUsage, ICSLAction *out) {
    static const struct { char down, up; ICSLControl control; } table[] = {
        { 'w', 'e', ICSLButtonDpadUp },
        { 'x', 'z', ICSLButtonDpadDown },
        { 'a', 'q', ICSLButtonDpadLeft },
        { 'd', 'c', ICSLButtonDpadRight },
        { 'h', 'r', ICSLButtonA },
        { 'u', 'f', ICSLButtonB },
        { 'y', 't', ICSLButtonX },
        { 'j', 'n', ICSLButtonY },
        { 'i', 'm', ICSLButtonLB },
        { 'k', 'p', ICSLButtonRB },
        { 'o', 'g', ICSLTriggerLeft },   // también SELECT y L3 (mismas letras)
        { 'l', 'v', ICSLTriggerRight },  // también START y R3 (mismas letras)
    };
    for (size_t i = 0; i < sizeof(table) / sizeof(table[0]); i++) {
        if (hidUsage == HID(table[i].down)) { *out = (ICSLAction){ table[i].control, true };  return true; }
        if (hidUsage == HID(table[i].up))   { *out = (ICSLAction){ table[i].control, false }; return true; }
    }
    return false;
}

#pragma mark - [C] Estado + [D] mando virtual SDL3

static SDL_JoystickID gVirtualID;
static SDL_Joystick *gVirtualJoystick;
static bool gState[ICSLButtonCount];

static void ICSLEnsureVirtualJoystick(void) {
    if (gVirtualID && p_SDL_IsJoystickVirtual(gVirtualID)) {
        return;  // sigue existiendo
    }
    gVirtualID = 0;
    gVirtualJoystick = NULL;

    SDL_VirtualJoystickDesc desc;
    memset(&desc, 0, sizeof(desc));
    desc.version = sizeof(desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.vendor_id = 0x045E;   // Microsoft
    desc.product_id = 0x028E;  // Xbox 360 Controller: SDL y Steam lo tratan como un mando conocido
    desc.naxes = 6;
    desc.nbuttons = ICSLButtonCount;
    desc.button_mask = (1u << SDL_GAMEPAD_BUTTON_SOUTH) | (1u << SDL_GAMEPAD_BUTTON_EAST) |
                       (1u << SDL_GAMEPAD_BUTTON_WEST) | (1u << SDL_GAMEPAD_BUTTON_NORTH) |
                       (1u << SDL_GAMEPAD_BUTTON_LEFT_SHOULDER) | (1u << SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER) |
                       (1u << SDL_GAMEPAD_BUTTON_DPAD_UP) | (1u << SDL_GAMEPAD_BUTTON_DPAD_DOWN) |
                       (1u << SDL_GAMEPAD_BUTTON_DPAD_LEFT) | (1u << SDL_GAMEPAD_BUTTON_DPAD_RIGHT);
    desc.axis_mask = (1u << SDL_GAMEPAD_AXIS_LEFTX) | (1u << SDL_GAMEPAD_AXIS_LEFTY) |
                     (1u << SDL_GAMEPAD_AXIS_RIGHTX) | (1u << SDL_GAMEPAD_AXIS_RIGHTY) |
                     (1u << SDL_GAMEPAD_AXIS_LEFT_TRIGGER) | (1u << SDL_GAMEPAD_AXIS_RIGHT_TRIGGER);
    desc.name = "iPega PG-9083 (iCade)";

    SDL_JoystickID jid = p_SDL_AttachVirtualJoystick(&desc);
    if (!jid) {
        ICSLLog(@"ERROR: SDL_AttachVirtualJoystick falló: %s", p_SDL_GetError ? p_SDL_GetError() : "?");
        return;
    }
    SDL_Joystick *joystick = p_SDL_OpenJoystick(jid);
    if (!joystick) {
        ICSLLog(@"ERROR: SDL_OpenJoystick(%u) falló: %s", jid, p_SDL_GetError ? p_SDL_GetError() : "?");
        return;
    }
    gVirtualID = jid;
    gVirtualJoystick = joystick;
    memset(gState, 0, sizeof(gState));
    ICSLLog(@"Mando virtual creado: id=%u", jid);
}

static void ICSLApplyDpadToStick(void) {
    if (!gDpadToLeftStick || !gVirtualJoystick) {
        return;
    }
    int x = (gState[ICSLButtonDpadRight] ? 1 : 0) - (gState[ICSLButtonDpadLeft] ? 1 : 0);
    int y = (gState[ICSLButtonDpadDown] ? 1 : 0) - (gState[ICSLButtonDpadUp] ? 1 : 0);
    p_SDL_SetJoystickVirtualAxis(gVirtualJoystick, SDL_GAMEPAD_AXIS_LEFTX,
                                 x > 0 ? SDL_JOYSTICK_AXIS_MAX : x < 0 ? SDL_JOYSTICK_AXIS_MIN : 0);
    p_SDL_SetJoystickVirtualAxis(gVirtualJoystick, SDL_GAMEPAD_AXIS_LEFTY,
                                 y > 0 ? SDL_JOYSTICK_AXIS_MAX : y < 0 ? SDL_JOYSTICK_AXIS_MIN : 0);
}

// Solo se llama en el hilo principal.
static void ICSLApply(ICSLAction action) {
    if (!gVirtualJoystick) {
        ICSLLog(@"Tecla iCade ignorada: el mando virtual todavía no existe");
        return;
    }
    if (action.control == ICSLTriggerLeft || action.control == ICSLTriggerRight) {
        int axis = action.control == ICSLTriggerLeft ? SDL_GAMEPAD_AXIS_LEFT_TRIGGER : SDL_GAMEPAD_AXIS_RIGHT_TRIGGER;
        p_SDL_SetJoystickVirtualAxis(gVirtualJoystick, axis, action.pressed ? SDL_JOYSTICK_AXIS_MAX : SDL_JOYSTICK_AXIS_MIN);
        ICSLLog(@"%s %s", action.control == ICSLTriggerLeft ? "LT" : "RT", action.pressed ? "pulsado" : "soltado");
        return;
    }
    if (gState[action.control] == action.pressed) {
        return;  // ya estaba así (la misma tecla llega por UIKit y por GameController)
    }
    gState[action.control] = action.pressed;
    p_SDL_SetJoystickVirtualButton(gVirtualJoystick, (int)action.control, action.pressed);
    if (action.control >= ICSLButtonDpadUp) {
        ICSLApplyDpadToStick();
    }
    static const char *names[] = { "A", "B", "X", "Y", "LB", "RB", "Cruceta arriba", "Cruceta abajo", "Cruceta izquierda", "Cruceta derecha" };
    ICSLLog(@"%s %s", names[action.control], action.pressed ? "pulsado" : "soltado");
}

static void ICSLApplyOnMain(ICSLAction action) {
    if ([NSThread isMainThread]) {
        ICSLApply(action);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ ICSLApply(action); });
    }
}

#pragma mark - [A] Interceptor UIKit

static void (*orig_sendEvent)(UIApplication *self, SEL _cmd, UIEvent *event);

static void hook_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if (![event isKindOfClass:[UIPressesEvent class]]) {
        orig_sendEvent(self, _cmd, event);
        return;
    }
    // Un evento de teclado físico suele llevar una sola tecla. Solo lo consumimos
    // si TODAS sus teclas son iCade y no hay modificadores (Cmd, Ctrl, etc.).
    NSSet<UIPress *> *presses = ((UIPressesEvent *)event).allPresses;
    NSMutableArray<NSValue *> *actions = [NSMutableArray array];
    BOOL allICade = presses.count > 0;
    for (UIPress *press in presses) {
        ICSLAction action;
        UIKey *key = press.key;
        if (!key || key.modifierFlags != 0 || !ICSLDecode((long)key.keyCode, &action)) {
            allICade = NO;
            break;
        }
        if (press.phase == UIPressPhaseBegan) {  // la letra de "soltar" también llega como Began
            [actions addObject:[NSValue valueWithBytes:&action objCType:@encode(ICSLAction)]];
        }
    }
    if (!allICade) {
        orig_sendEvent(self, _cmd, event);
        return;
    }
    for (NSValue *value in actions) {
        ICSLAction action;
        [value getValue:&action size:sizeof(action)];
        ICSLApply(action);
    }
    // No llamamos a orig_sendEvent: la app nunca ve la tecla.
}

#pragma mark - [A] Interceptor GameController (lo usa SDL3 para leer el teclado)

typedef void (^ICSLKeyChangedHandler)(GCKeyboardInput *keyboard, GCControllerButtonInput *key,
                                      GCKeyCode keyCode, BOOL pressed);

static void (*orig_setKeyChangedHandler)(GCKeyboardInput *self, SEL _cmd, ICSLKeyChangedHandler handler);

static void hook_setKeyChangedHandler(GCKeyboardInput *self, SEL _cmd, ICSLKeyChangedHandler handler) {
    ICSLKeyChangedHandler wrapped = handler;
    if (handler) {
        wrapped = ^(GCKeyboardInput *keyboard, GCControllerButtonInput *key, GCKeyCode keyCode, BOOL pressed) {
            ICSLAction action;
            if (ICSLDecode((long)keyCode, &action)) {
                if (pressed) {
                    ICSLApplyOnMain(action);
                }
                return;  // SDL no recibe la tecla: no viaja al PC
            }
            handler(keyboard, key, keyCode, pressed);
        };
        ICSLLog(@"Handler de GCKeyboardInput envuelto");
    }
    orig_setKeyChangedHandler(self, _cmd, wrapped);
}

#pragma mark - Hook de SDL_InitSubSystem: crear el mando cuando SDL está listo

static bool hook_SDL_InitSubSystem(uint32_t flags) {
    bool ok = orig_SDL_InitSubSystem(flags);
    if (ok && (flags & (SDL_INIT_JOYSTICK | SDL_INIT_GAMEPAD))) {
        if ([NSThread isMainThread]) {
            ICSLEnsureVirtualJoystick();
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ ICSLEnsureVirtualJoystick(); });
        }
    }
    return ok;
}

#pragma mark - Arranque

#define LOAD_SDL(sym) (p_##sym = (__typeof__(p_##sym))dlsym(RTLD_DEFAULT, #sym))

__attribute__((constructor)) static void ICadeSteamLinkInit(void) {
    @autoreleasepool {
        ICSLLoadConfig();
        if (!gEnabled) {
            ICSLLog(@"Desactivado por configuración");
            return;
        }

        void *initSubSystem = dlsym(RTLD_DEFAULT, "SDL_InitSubSystem");
        LOAD_SDL(SDL_AttachVirtualJoystick);
        LOAD_SDL(SDL_IsJoystickVirtual);
        LOAD_SDL(SDL_OpenJoystick);
        LOAD_SDL(SDL_SetJoystickVirtualButton);
        LOAD_SDL(SDL_SetJoystickVirtualAxis);
        LOAD_SDL(SDL_GetError);
        if (!initSubSystem || !p_SDL_AttachVirtualJoystick || !p_SDL_IsJoystickVirtual || !p_SDL_OpenJoystick ||
            !p_SDL_SetJoystickVirtualButton || !p_SDL_SetJoystickVirtualAxis) {
            ICSLLog(@"ERROR: no encontré las funciones de SDL3; el tweak no hará nada");
            return;
        }

        MSHookFunction(initSubSystem, (void *)hook_SDL_InitSubSystem, (void **)&orig_SDL_InitSubSystem);
        MSHookMessageEx([UIApplication class], @selector(sendEvent:),
                        (IMP)hook_sendEvent, (IMP *)&orig_sendEvent);
        MSHookMessageEx([GCKeyboardInput class], @selector(setKeyChangedHandler:),
                        (IMP)hook_setKeyChangedHandler, (IMP *)&orig_setKeyChangedHandler);
        ICSLLog(@"Hooks instalados (SDL_InitSubSystem, UIApplication, GCKeyboardInput)");
    }
}
