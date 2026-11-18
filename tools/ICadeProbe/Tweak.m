// ICadeProbe — tweak de diagnóstico para Steam Link (SDL3).
//
// Qué hace:
//   1. Engancha SDL_InitSubSystem (función exportada por SDL3.framework).
//   2. En cuanto SDL3 se inicializa, registra un "event watch" con SDL_AddEventWatch.
//   3. Cada evento de teclado, texto, joystick o gamepad se escribe en un archivo
//      de log dentro del contenedor de la app: <contenedor>/tmp/ICadeProbe.log
//
// No modifica ni descarta ningún evento: un event watch de SDL solo observa.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <dlfcn.h>
#import <stddef.h>
#import <stdatomic.h>
#import <substrate.h>

#pragma mark - Definiciones mínimas de SDL3 (no tenemos sus headers)

// Valores de SDL_EventType en SDL3.
enum {
    PROBE_EVENT_KEY_DOWN          = 0x300,
    PROBE_EVENT_KEY_UP            = 0x301,
    PROBE_EVENT_TEXT_INPUT        = 0x303,
    PROBE_EVENT_KEYBOARD_ADDED    = 0x305,
    PROBE_EVENT_KEYBOARD_REMOVED  = 0x306,
    PROBE_EVENT_JOYSTICK_ADDED    = 0x605,
    PROBE_EVENT_JOYSTICK_REMOVED  = 0x606,
    PROBE_EVENT_GAMEPAD_ADDED     = 0x653,
    PROBE_EVENT_GAMEPAD_REMOVED   = 0x654,
};

// SDL_KeyboardEvent (SDL3)
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;   // nanosegundos
    uint32_t windowID;
    uint32_t which;       // SDL_KeyboardID
    int32_t  scancode;    // SDL_Scancode
    uint32_t key;         // SDL_Keycode (para letras = carácter ASCII en minúscula)
    uint16_t mod;
    uint16_t raw;
    bool     down;
    bool     repeat;
} ProbeKeyboardEvent;

// SDL_TextInputEvent (SDL3)
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    const char *text;
} ProbeTextInputEvent;

// SDL_KeyboardDeviceEvent / SDL_JoyDeviceEvent / SDL_GamepadDeviceEvent (SDL3)
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t which;
} ProbeDeviceEvent;

typedef union {
    uint32_t            type;
    ProbeKeyboardEvent  key;
    ProbeTextInputEvent text;
    ProbeDeviceEvent    device;
    uint8_t             padding[128];   // SDL_Event ocupa 128 bytes
} ProbeEvent;

_Static_assert(offsetof(ProbeKeyboardEvent, scancode) == 24, "SDL_KeyboardEvent layout");
_Static_assert(offsetof(ProbeKeyboardEvent, down) == 36, "SDL_KeyboardEvent layout");
_Static_assert(offsetof(ProbeTextInputEvent, text) == 24, "SDL_TextInputEvent layout");

typedef bool (*ProbeEventFilter)(void *userdata, ProbeEvent *event);

static bool (*orig_SDL_InitSubSystem)(uint32_t flags);
static bool (*p_SDL_AddEventWatch)(ProbeEventFilter filter, void *userdata);
static const char *(*p_SDL_GetJoystickNameForID)(uint32_t instance_id);
static const char *(*p_SDL_GetKeyboardNameForID)(uint32_t instance_id);

#pragma mark - Log a archivo

static dispatch_queue_t gLogQueue;
static NSFileHandle *gLogHandle;

static void ProbeLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ProbeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[ICadeProbe] %@", message);
    dispatch_async(gLogQueue, ^{
        static NSDateFormatter *formatter;
        if (!formatter) {
            formatter = [NSDateFormatter new];
            formatter.dateFormat = @"HH:mm:ss.SSS";
        }
        NSString *line = [NSString stringWithFormat:@"%@  %@\n",
                          [formatter stringFromDate:[NSDate date]], message];
        [gLogHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    });
}

static void ProbeOpenLog(void) {
    gLogQueue = dispatch_queue_create("ICadeProbe.log", DISPATCH_QUEUE_SERIAL);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ICadeProbe.log"];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];  // vacía el log en cada arranque
    gLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    ProbeLog(@"=== ICadeProbe 0.3.0 cargado en %@ %@ (iOS %@) ===",
             info[@"CFBundleIdentifier"], info[@"CFBundleShortVersionString"],
             [NSProcessInfo processInfo].operatingSystemVersionString);
    ProbeLog(@"Log: %@", path);
}

#pragma mark - Event watch

static NSString *ProbeKeyLabel(uint32_t key) {
    if (key >= 0x20 && key < 0x7f) {
        return [NSString stringWithFormat:@"'%c'", (char)key];
    }
    return [NSString stringWithFormat:@"0x%x", key];
}

static bool ProbeEventWatch(void *userdata, ProbeEvent *event) {
    switch (event->type) {
        case PROBE_EVENT_KEY_DOWN:
        case PROBE_EVENT_KEY_UP: {
            ProbeKeyboardEvent *k = &event->key;
            ProbeLog(@"%-8s key=%@ scancode=%d mod=0x%x repeat=%d teclado=%u",
                     k->down ? "KEY_DOWN" : "KEY_UP", ProbeKeyLabel(k->key),
                     k->scancode, k->mod, k->repeat, k->which);
            break;
        }
        case PROBE_EVENT_TEXT_INPUT:
            ProbeLog(@"TEXT     \"%s\"", event->text.text ? event->text.text : "(null)");
            break;
        case PROBE_EVENT_KEYBOARD_ADDED:
        case PROBE_EVENT_KEYBOARD_REMOVED: {
            const char *name = p_SDL_GetKeyboardNameForID ? p_SDL_GetKeyboardNameForID(event->device.which) : NULL;
            ProbeLog(@"%s id=%u nombre=\"%s\"",
                     event->type == PROBE_EVENT_KEYBOARD_ADDED ? "TECLADO CONECTADO" : "TECLADO DESCONECTADO",
                     event->device.which, name ? name : "?");
            break;
        }
        case PROBE_EVENT_JOYSTICK_ADDED:
        case PROBE_EVENT_JOYSTICK_REMOVED:
        case PROBE_EVENT_GAMEPAD_ADDED:
        case PROBE_EVENT_GAMEPAD_REMOVED: {
            const char *label =
                event->type == PROBE_EVENT_JOYSTICK_ADDED   ? "JOYSTICK CONECTADO" :
                event->type == PROBE_EVENT_JOYSTICK_REMOVED ? "JOYSTICK DESCONECTADO" :
                event->type == PROBE_EVENT_GAMEPAD_ADDED    ? "GAMEPAD CONECTADO" : "GAMEPAD DESCONECTADO";
            const char *name = (event->type == PROBE_EVENT_JOYSTICK_ADDED || event->type == PROBE_EVENT_GAMEPAD_ADDED)
                && p_SDL_GetJoystickNameForID ? p_SDL_GetJoystickNameForID(event->device.which) : NULL;
            ProbeLog(@"%s id=%u nombre=\"%s\"", label, event->device.which, name ? name : "?");
            break;
        }
        default:
            // Cualquier otro evento de teclado (0x3xx) o de mando (0x6xx) también se anota.
            if ((event->type & 0xff00) == 0x300 || (event->type & 0xff00) == 0x600) {
                ProbeLog(@"SDL EVENT 0x%x", event->type);
            }
            break;
    }
    return true;  // en un event watch el valor de retorno se ignora
}

#pragma mark - Hook de UIKit: -[UIApplication sendEvent:]
//
// Captura las pulsaciones de teclado físico ANTES de que lleguen a Qt o a SDL,
// así vemos las teclas aunque la pantalla visible no sea la ventana de SDL.

static void (*orig_sendEvent)(UIApplication *self, SEL _cmd, UIEvent *event);

static void hook_sendEvent(UIApplication *self, SEL _cmd, UIEvent *event) {
    if ([event isKindOfClass:[UIPressesEvent class]]) {
        for (UIPress *press in ((UIPressesEvent *)event).allPresses) {
            if (press.phase != UIPressPhaseBegan && press.phase != UIPressPhaseEnded) {
                continue;
            }
            UIKey *key = press.key;
            ProbeLog(@"UIKIT %-5s pressType=%ld chars=\"%@\" hid=0x%02lx mods=0x%lx (%@ type=%ld)",
                     press.phase == UIPressPhaseBegan ? "DOWN" : "UP", (long)press.type,
                     key.charactersIgnoringModifiers ?: @"",
                     (long)key.keyCode, (long)key.modifierFlags,
                     NSStringFromClass([event class]), (long)event.type);
        }
    } else if (event.type != UIEventTypeTouches) {
        // Eventos no táctiles de otro tipo (p. ej. teclado físico privado de UIKit).
        ProbeLog(@"UIKIT EVENTO %@ type=%ld subtype=%ld",
                 NSStringFromClass([event class]), (long)event.type, (long)event.subtype);
    }
    orig_sendEvent(self, _cmd, event);
}

#pragma mark - Hook de GameController: -[GCKeyboardInput setKeyChangedHandler:]
//
// SDL3 lee el teclado físico a través de GCKeyboard. Envolvemos el handler que SDL
// instala para ver cada tecla que entrega GameController, sin cambiar su comportamiento.

typedef void (^ProbeKeyChangedHandler)(GCKeyboardInput *keyboard, GCControllerButtonInput *key,
                                       GCKeyCode keyCode, BOOL pressed);

static void (*orig_setKeyChangedHandler)(GCKeyboardInput *self, SEL _cmd, ProbeKeyChangedHandler handler);

static void hook_setKeyChangedHandler(GCKeyboardInput *self, SEL _cmd, ProbeKeyChangedHandler handler) {
    ProbeLog(@"GCKeyboardInput %p: keyChangedHandler %@", self, handler ? @"instalado" : @"eliminado");
    ProbeKeyChangedHandler wrapped = handler;
    if (handler) {
        wrapped = ^(GCKeyboardInput *keyboard, GCControllerButtonInput *key, GCKeyCode keyCode, BOOL pressed) {
            ProbeLog(@"GCKEY %-5s hid=0x%02lx", pressed ? "DOWN" : "UP", (long)keyCode);
            handler(keyboard, key, keyCode, pressed);
        };
    }
    orig_setKeyChangedHandler(self, _cmd, wrapped);
}

static void ProbeWatchKeyboards(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidConnectNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        GCKeyboard *kb = note.object;
        ProbeLog(@"GCKeyboard CONECTADO: \"%@\" (%@)", kb.vendorName, kb.productCategory);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidDisconnectNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        ProbeLog(@"GCKeyboard DESCONECTADO");
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) {
        GCController *c = note.object;
        ProbeLog(@"GCController CONECTADO: \"%@\" (%@)", c.vendorName, c.productCategory);
    }];
}

#pragma mark - Hook de SDL_InitSubSystem

static atomic_bool gWatchInstalled;

static bool hook_SDL_InitSubSystem(uint32_t flags) {
    bool ok = orig_SDL_InitSubSystem(flags);
    ProbeLog(@"SDL_InitSubSystem(0x%x) -> %s", flags, ok ? "OK" : "ERROR");
    if (ok && !atomic_exchange(&gWatchInstalled, true)) {
        bool added = p_SDL_AddEventWatch(ProbeEventWatch, NULL);
        ProbeLog(@"SDL_AddEventWatch -> %s", added ? "OK (escuchando eventos)" : "ERROR");
    }
    return ok;
}

__attribute__((constructor)) static void ICadeProbeInit(void) {
    ProbeOpenLog();

    MSHookMessageEx([UIApplication class], @selector(sendEvent:),
                    (IMP)hook_sendEvent, (IMP *)&orig_sendEvent);
    ProbeLog(@"Hook instalado en -[UIApplication sendEvent:]");

    MSHookMessageEx([GCKeyboardInput class], @selector(setKeyChangedHandler:),
                    (IMP)hook_setKeyChangedHandler, (IMP *)&orig_setKeyChangedHandler);
    ProbeWatchKeyboards();
    ProbeLog(@"Hook instalado en GCKeyboardInput; teclados ya conectados: %@",
             GCKeyboard.coalescedKeyboard ? @"sí" : @"ninguno");

    void *initSubSystem      = dlsym(RTLD_DEFAULT, "SDL_InitSubSystem");
    p_SDL_AddEventWatch       = (bool (*)(ProbeEventFilter, void *))dlsym(RTLD_DEFAULT, "SDL_AddEventWatch");
    p_SDL_GetJoystickNameForID = (const char *(*)(uint32_t))dlsym(RTLD_DEFAULT, "SDL_GetJoystickNameForID");
    p_SDL_GetKeyboardNameForID = (const char *(*)(uint32_t))dlsym(RTLD_DEFAULT, "SDL_GetKeyboardNameForID");

    if (!initSubSystem || !p_SDL_AddEventWatch) {
        ProbeLog(@"ERROR: no encontré SDL3 (SDL_InitSubSystem=%p, SDL_AddEventWatch=%p)",
                 initSubSystem, p_SDL_AddEventWatch);
        return;
    }
    MSHookFunction(initSubSystem, (void *)hook_SDL_InitSubSystem, (void **)&orig_SDL_InitSubSystem);
    ProbeLog(@"Hook instalado en SDL_InitSubSystem");
}
