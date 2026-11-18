# Fase 2 (sticks analógicos): investigación

Objetivo: conseguir que el iPad acepte el PG-9083 en la **posición 1 (Android V3)**, donde el control envía un mando completo con sticks y gatillos analógicos (ver [hardware-pg9083.md](hardware-pg9083.md)), y llevar esa entrada a Steam Link.

Esta fase **todavía no tiene código**. Esto son notas de ingeniería inversa sobre `bluetoothd` de iPadOS 17.7.11 (binario copiado del iPad a `~/steamlink-re/bt/`, solo lectura; análisis estático con `llvm-objdump`).

## Qué decide si un mando se acepta

En `bluetoothd` hay una función (en la copia analizada, `0x1003fdb0c`) que se llama desde el manejador de `HIDDeviceBehavior` (el valor con el que iPadOS decide cómo tratar un dispositivo HID). Su lógica, resumida:

1. Si el *feature flag* de Apple **`GameControllerBlockListRemoval`** (conjunto `BluetoothFeatures`) está activo → devuelve "soportado".
2. Lee un ajuste booleano **`EnableGamepads`** del dominio de preferencias **`com.apple.MobileBluetooth.debug`** (subsección "HID").
3. Mira unos bits del propio dispositivo (`flags & 0xB800`, que vienen de las páginas de uso de su descriptor HID):
   - si están presentes → "soportado";
   - si no, y **`EnableGamepads` está activo** → "soportado", y además registra el mensaje **"Bypassing MFi gamepad authentication"**;
   - si no, y `EnableGamepads` está desactivado → "no soportado".

Es decir, Apple dejó en el sistema una llave (`EnableGamepads`) que hace que `bluetoothd` trate como mando válido a un control que, de lo contrario, rechazaría por no estar certificado (MFi).

## Hipótesis a comprobar (sin escribir ningún tweak)

Si `EnableGamepads` se puede activar como preferencia de `com.apple.MobileBluetooth.debug`, puede que el iPad acepte el control en la posición 1 **solo con cambiar ese ajuste** y reiniciar `bluetoothd`, sin parchear nada.

Riesgos y dudas:
- No está confirmado que la posición 1 llegue siquiera a crear un `IOHIDUserDevice`: puede fallar en un paso anterior (la posición 1 no creaba ningún dispositivo, mientras que la 3 sí). El experimento lo dirá.
- Aunque el iPad cree el dispositivo, seguramente lo verá como un **mando genérico**, no como uno que iPadOS exponga a las apps vía GameController. Steam Link (SDL3) podría leerlo igualmente como joystick HID; habrá que comprobarlo.
- `bluetoothd` es un proceso de sistema. Cambiar una preferencia es reversible; parchear el binario, no, y además rompería su firma. Por eso el primer paso es solo la preferencia.

## Experimento propuesto (reversible)

1. Guardar el valor actual (por si acaso) y activar la preferencia en el iPad:
   - leer `com.apple.MobileBluetooth.debug`;
   - poner `EnableGamepads = true` (probando tanto en la raíz como en una subsección `HID`).
2. Reiniciar `bluetoothd` (o el iPad).
3. Emparejar el control en la **posición 1** y repetir `tools/hid-snapshot.sh`: ver si ahora aparece un `IOHIDDevice` de tipo gamepad.
4. Si aparece, abrir Steam Link y ver si SDL3 lo detecta como joystick (con un tweak de diagnóstico parecido a ICadeProbe).
5. Pase lo que pase, dejar la preferencia como estaba.

Si el experimento funciona, la fase 2 podría ser mucho más sencilla de lo previsto: una preferencia del sistema más, quizá, un pequeño tweak de mapeo en Steam Link, en lugar de un tweak dentro de `bluetoothd`.

## Pendiente de confirmar

- Que `EnableGamepads` se lee de verdad con `CFPreferences`/`NSUserDefaults` del dominio `com.apple.MobileBluetooth.debug` (y no de un plist interno distinto).
- Si hace falta además el *feature flag* `GameControllerBlockListRemoval`, que no se activa con una preferencia normal.
- Qué bits son exactamente `0xB800` en `flags`, para entender por qué la posición 1 no los tiene.
