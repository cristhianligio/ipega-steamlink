# iPega PG-9083 (sin "S"): cómo lo ve iPadOS

Notas de hardware obtenidas con `tools/hid-snapshot.sh` en un iPad 6ª gen con iPadOS 17.7.11.

## Interruptor lateral

El control tiene un interruptor de 4 posiciones en el lado izquierdo. Cada posición se reconoce por el icono que queda debajo del interruptor:

| N.º | Posición | Icono | Modo (manual) | Nombre Bluetooth | LED | Resultado en iPadOS |
|---|---|---|---|---|---|---|
| 1 | Totalmente a la izquierda | Android | Android V3 | `PG-9083` | LED 1 | Se empareja ("Conectado"), pero **iPadOS no crea ningún dispositivo de entrada**. Su descriptor sí incluye un **gamepad analógico** (ver abajo). |
| 2 | Segunda desde la izquierda | Android | No Function | n/a | n/a | n/a |
| 3 | Bajo la manzana | Apple | iOS | _pendiente_ | _pendiente_ | _pendiente_ |
| 4 | Totalmente a la derecha | Mando | Android & PC | `PG-9083` | LED 4 | **Teclado iCade** (ver abajo) |

> En otra posición, que todavía no sabemos cuál es, el control aparecía como `Newgamepad N1` y no escribía nada en Notas.

## Posición 4: "Android & PC" → teclado iCade

- **Vendor ID / Product ID:** `0x1949` / `0x0402` (6473 / 1026)
- **Transporte:** Bluetooth (iPadOS crea un `IOHIDUserDevice`)
- **Usos principales:** teclado (página 0x01, uso 0x06) y Consumer Control (página 0x0C, uso 0x01)
- **No envía ejes analógicos:** el descriptor solo contiene teclado y teclas multimedia.
- iPadOS **no** lo considera un mando (no aparece *Ajustes → General → Mando de juegos*).

Descriptor HID decodificado:

```
Report ID 1: Teclado estándar
  8 bits de modificadores (E0–E7), 1 byte reservado,
  5 LEDs (salida), 6 teclas simultáneas (array 0x00–0xFF)
Report ID 2: Consumer Control (10 bits)
  Play/Pause (0xCD), Pista anterior (0xB6), Pista siguiente (0xB5),
  Volumen + (0xE9), Volumen − (0xEA), Expulsar (0xB8), 0x95,
  AC Home (0x223), AC Back (0x224), Menú (0x40)
```

Letras registradas con ICadeProbe 0.3.0 dentro de Steam Link. Cada botón envía una letra al pulsar y otra al soltar; ambas son pulsaciones cortas de teclado (≈10 ms):

| Botón | Al pulsar | Al soltar | Código HID (pulsar/soltar) |
|---|---|---|---|
| Cruceta ↑ | `w` | `e` | 0x1A / 0x08 |
| Cruceta ↓ | `x` | `z` | 0x1B / 0x1D |
| Cruceta ← | `a` | `q` | 0x04 / 0x14 |
| Cruceta → | `d` | `c` | 0x07 / 0x06 |
| A | `h` | `r` | 0x0B / 0x15 |
| B | `u` | `f` | 0x18 / 0x09 |
| X | `y` | `t` | 0x1C / 0x17 |
| Y | `j` | `n` | 0x0D / 0x11 |
| L1 | `i` | `m` | 0x0C / 0x10 |
| R1 | `k` | `p` | 0x0E / 0x13 |
| L2 | `o` | `g` | 0x12 / 0x0A |
| R2 | `l` | `v` | 0x0F / 0x19 |
| SELECT | `o` | `g` | igual que L2 (*) |
| START | `l` | `v` | igual que R2 (*) |
| L3 (pulsar stick izq.) | `o` | `g` | igual que L2 (*) |
| R3 (pulsar stick der.) | `l` | `v` | igual que R2 (*) |
| Stick izquierdo | igual que la cruceta | | digital, sin valores intermedios |
| Stick derecho | _no envía nada_ | | |

(*) iCade solo tiene 8 botones además de la cruceta, así que el control repite letras. Confirmado pulsando cada botón por separado en Notas: SELECT y L3 envían lo mismo que L2 (`o`/`g`), y START y R3 lo mismo que R2 (`l`/`v`). El tweak no puede distinguirlos. **Decisión:** `o/g` = L2 y `l/v` = R2; SELECT, START, L3 y R3 no se usan.

Observaciones en Steam Link 1.4.5:

- Las teclas llegan a UIKit como `UIPhysicalKeyboardEvent` (tipo de evento 4, privado), **no** como `UIPressesEvent` público.
- GameController detecta el control como `GCKeyboard` "Generic Keyboard".
- Steam Link no reacciona a ningún botón: no trata el teclado iCade como mando.
- En la pantalla inicial (Qt) SDL3 no recibe ninguna tecla y no instala su `keyChangedHandler` de `GCKeyboard`. Ese handler se instala con el subsistema de vídeo (`SDL_INIT_VIDEO`), que la app arranca más tarde.

Descriptor en bruto:

```
05010906a101850175019508050719e029e715002501810295017508810395057501050819012905910295017503910395067508150026ff000507190029ff8100c0050c0901a1018502150025017501950a09cd09b609b509e909ea09b809950a23020a240209408102950175068103c0
```

## Posición 1: "Android V3" → gamepad HID (ignorado por iPadOS)

- Se empareja y aparece como **Conectado** en Ajustes, pero **no** aparece ningún `IOHIDDevice` en el IORegistry. Tampoco escribe en Notas, no mueve el puntero y no aparece *Ajustes → General → Mando de juegos*.
- El descriptor HID se obtuvo de la ficha que guarda `bluetoothd` en `…/SystemGroup/<uuid>/Library/Preferences/com.apple.MobileBluetooth.devices.plist` (clave `HIDDescriptor`, 208 bytes).
- **IDs HID:** `HIDVendorID` 0x1337, `HIDProductID` 0x0204. **Device ID** (registro PnP): 0x1949 / 0x0402, el mismo que en la posición 4.

Descriptor decodificado:

```
Report ID 2: Consumer Control (10 bits): igual que en la posición 4
Report ID 6: Ratón: 3 botones, X/Y relativos (−127..127), rueda (−127..127)
Report ID 7: Gamepad (página 0x01, uso 0x05)
  X, Y, Z, Rz            4 × 8 bits, 0..255   → dos sticks analógicos
  Hat switch             4 bits, 0..7 (8 direcciones) + 4 bits de relleno
  Botones 1–16           16 × 1 bit
  Accelerator, Brake     2 × 8 bits, 0..255   → gatillos analógicos (página 0x02)
  Relleno                8 bits
```

**Conclusión para la fase 2:** en esta posición el control envía exactamente lo que necesitamos: dos sticks y dos gatillos analógicos, cruceta de 8 direcciones y 16 botones. Pero iPadOS no lo convierte en un dispositivo HID utilizable. **Hipótesis, pendiente de comprobar:** `bluetoothd` recibe los reportes pero no crea el `IOHIDUserDevice`, así que nunca llegan a `backboardd`. Si se confirma, el tweak de la fase 2 tendrá que trabajar en `bluetoothd`, no en `backboardd` como se planteó al principio.

Descriptor en bruto:

```
050c0901a1018502150025017501950a09cd09b609b509e909ea09b809950a23020a240209408102950175068103c005010902a10185060901a100050919012903150025017501950381027505950181010501093009311581257f75089502810609381581257f750895018106c0c005010905a10185070901a1000930093109320935150026ff00750895048102c00939150025073500463b016514750495018142750495018101050919012910150025017501951081020502150026ff0009c409c5950275088102750895018101c0
```
