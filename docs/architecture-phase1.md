# Fase 1: arquitectura del tweak iCade → mando virtual

Objetivo: que Steam Link (iPadOS) reconozca el iPega PG-9083, con el interruptor en la posición 4 ("Android & PC", modo teclado iCade), como un mando de juego.

**Estado:** probado y funcionando con ICadeSteamLink 0.1.0 (iPad 6ª gen, iPadOS 17.7.11, Steam Link 1.4.5). La cruceta, A y B navegan por la interfaz de Steam Link; el control funciona durante la transmisión al PC, y no se escapa ninguna letra ni a la pantalla ni al PC. Cuando Steam Link reinicia el subsistema de mandos de SDL al empezar a transmitir, el mando virtual se vuelve a crear solo.

## Datos de partida (comprobados)

- Steam Link 1.4.5 (`com.valvesoftware.SteamLink17`) usa **SDL3 3.5.0** como framework dinámico **sin cifrar**. SDL3 exporta la API de mando virtual: `SDL_AttachVirtualJoystick`, `SDL_SetJoystickVirtualButton/Axis/Hat`.
- Steam Link inicializa el subsistema de joystick/gamepad de SDL al arrancar (`SDL_InitSubSystem(0x200)` y `(0x2000)`).
- Las teclas del control llegan a UIKit como `UIPhysicalKeyboardEvent` y GameController las ve como un `GCKeyboard`. SDL3 lee el teclado mediante `GCKeyboardInput.keyChangedHandler`, que instala cuando arranca su subsistema de vídeo.
- Mapeo iCade del control: ver [hardware-pg9083.md](hardware-pg9083.md).

## Componentes

```
UIKit (UIPhysicalKeyboardEvent) ─┐
                                 ├─► [A] Interceptores ─► [B] Decodificador iCade ─► [C] Estado del mando ─► [D] Mando virtual SDL3
GameController (GCKeyboard) ─────┘          │
                                            └─ las teclas iCade se descartan (no llegan a Qt, a SDL ni al PC)
```

**[A] Interceptores** (dos puntos, porque la app usa los dos caminos):

1. Hook a `-[UIApplication sendEvent:]`: si un evento de teclado físico contiene solo teclas iCade, se procesa y **no** se entrega a la app. Así la interfaz Qt no recibe letras sueltas.
2. Hook a `-[GCKeyboardInput setKeyChangedHandler:]`: envuelve el handler de SDL3. Las teclas iCade se procesan y no se le pasan a SDL, para que no viajen al PC como pulsaciones de teclado durante la transmisión.

**[B] Decodificador:** tabla de letra → (botón, pulsado/soltado). Cada botón iCade envía una letra al pulsar y otra al soltar, por eso solo se procesan los *key down* e ignoramos los *key up*.

| Letras | Botón del mando virtual |
|---|---|
| `w/e` `x/z` `a/q` `d/c` | Cruceta (hat) ↑ ↓ ← → |
| `h/r` | A |
| `u/f` | B |
| `y/t` | X |
| `j/n` | Y |
| `i/m` | LB (L1) |
| `k/p` | RB (R1) |
| `o/g` | LT (L2), gatillo al 0 % o al 100 % |
| `l/v` | RT (R2), gatillo al 0 % o al 100 % |

SELECT/START/L3/R3 no se usan porque comparten letras con L2/R2 (decisión del autor).

**[C] Estado:** botones activos y dirección de la cruceta. Se actualiza en el hilo principal.

**[D] Mando virtual:** al iniciarse el subsistema de joystick de SDL3 (hook a `SDL_InitSubSystem`), el tweak llama a `SDL_AttachVirtualJoystick` con:

- tipo: gamepad;
- Vendor/Product ID de un mando de Xbox, para que SDL le aplique su mapeo estándar y Steam lo muestre como un mando conocido;
- 6 ejes (sticks y gatillos), los botones de la tabla y 1 hat.

Luego lo abre con `SDL_OpenJoystick` y escribe los valores con `SDL_SetJoystickVirtual*`. Si la app reinicia los subsistemas de SDL y el mando desaparece, se vuelve a crear.

## Opciones previstas

- **Cruceta → stick izquierdo:** copiar la cruceta en el stick izquierdo con valores de −100 % / +100 %, para juegos que no usan la cruceta. Desactivada por defecto.
- **Registro de depuración:** archivo `tmp/ICadeSteamLink.log` en el contenedor de la app. Desactivado por defecto.

## Limitaciones conocidas

- Todo es digital: el modo iCade no envía valores analógicos y el stick derecho no envía nada. Los sticks analógicos son el objetivo de la fase 2.
- Mientras el tweak esté activo, un teclado físico real **no podrá escribir** las 24 letras iCade dentro de Steam Link.
- SELECT y START no están disponibles.
