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

## Resultado del experimento (2026-11-17): EnableGamepads funciona a nivel de sistema

Se creó `/var/mobile/Library/Preferences/com.apple.MobileBluetooth.debug.plist` (usuario `mobile`, que es quien ejecuta `bluetoothd`) con:

```
EnableGamepads = true
HID = { EnableGamepads = true }
```

Tras `killall -9 cfprefsd` y reiniciar `bluetoothd`, se emparejó el control en la **posición 1 (Android V3)**.

**Antes:** ningún `IOHIDDevice`. **Después:** iPadOS crea un `IOHIDUserDevice` "PG-9083" con `DeviceUsagePairs` que incluye **`{page=1, usage=5}` = Game Pad** (además de ratón y consumer). El `ReportDescriptor` es el completo de 208 bytes, con el Report 7 de gamepad analógico (X/Y/Z/Rz y gatillos de 0..255, hat y 16 botones).

Es decir, la preferencia `EnableGamepads` hace que `bluetoothd` **deje de rechazar** el control y lo exponga como dispositivo HID de tipo mando.

**Pero** *Configuración → General → Mando de juegos* **sigue sin aparecer**. Eso indica que iPadOS creó el dispositivo HID a bajo nivel, pero **no lo está exponiendo a través del framework GameController**. Como las apps de iOS (incluida Steam Link vía SDL3, por su ruta MFi) leen los mandos por GameController y no pueden abrir un `IOHIDDevice` arbitrario (sandbox), es probable que Steam Link todavía no lo vea. Falta comprobarlo.

### Comandos usados (reversibles)

```
# escribir la preferencia (como mobile, sin sudo)
cat > /var/mobile/Library/Preferences/com.apple.MobileBluetooth.debug.plist <<PLIST
... EnableGamepads=true, HID={EnableGamepads=true} ...
PLIST
# recargar (sudo)
sudo killall -9 cfprefsd
sudo launchctl kickstart -k user/501/com.apple.bluetoothd   # 501 = uid de mobile
# limpieza
rm /var/mobile/Library/Preferences/com.apple.MobileBluetooth.debug.plist && sudo killall -9 cfprefsd
```

### Siguiente incógnita

¿Steam Link (SDL3) detecta este gamepad? Dos escenarios:
- **Sí** → la fase 2 sería casi trivial: la preferencia + el mapeo que ya tenemos.
- **No** (lo más probable, al no aparecer en GameController) → hace falta un tweak que lea los reportes HID del Game Pad y los pase al joystick virtual de SDL que ya creamos en la fase 1. Ese tweak podría vivir en la propia Steam Link (si puede abrir el IOHIDDevice) o en `backboardd`/`bluetoothd`.

### Prueba en Steam Link: SDL NO ve el mando

Con la preferencia activa, el control en posición 1 y el diagnóstico ICadeProbe 0.3.0, se abrió Steam Link. En el registro:

- SDL inicializa los subsistemas de joystick y gamepad (`SDL_InitSubSystem(0x200)` y `(0x2000)`).
- **No hay ningún evento `JOYSTICK CONECTADO` ni `GAMEPAD CONECTADO`.**
- Al mover sticks y pulsar botones, **no llega ningún evento** a SDL, ni a UIKit, ni a GameController. Steam Link no reacciona.

**Conclusión confirmada:** la preferencia `EnableGamepads` hace que el mando exista como `IOHIDDevice` de sistema, pero **no lo expone por GameController**, que es la única vía por la que SDL3 lee mandos en iOS. Las apps no pueden abrir ese `IOHIDDevice` por el sandbox. Por tanto, Steam Link no lo ve y hace falta un tweak puente.

## Opciones para la fase 2 (puente HID analógico → joystick virtual de SDL)

El mando virtual de SDL dentro de Steam Link (de la fase 1) sirve tal cual; lo único que falta es **alimentarlo con los reportes HID analógicos**. Dónde leerlos:

1. **Tweak en `backboardd`** (el intermediario de HID del sistema): usar `IOHIDEventSystemClient`/`IOHIDManager` para recibir los eventos del Game Pad y reenviarlos a Steam Link (memoria compartida + Darwin notifications, o un socket local). backboardd sí tiene permisos de HID. Es el enfoque más prometedor.
2. **Tweak en la propia Steam Link** que intente abrir el `IOHIDDevice` con `IOHIDManager`. Probablemente lo impida el sandbox de la app, aunque sea un tweak inyectado. A comprobar.
3. **Tweak en `bluetoothd`**: leer los reportes antes de que se "pierdan". Más invasivo y arriesgado (proceso crítico).

Decisión pendiente. El enfoque 1 (backboardd) es el candidato principal; antes hay que comprobar que backboardd recibe de verdad los eventos de este Game Pad y que se pueden leer con `IOHIDEventSystemClient`.
