# ipega-steamlink

Usa el control **iPega PG-9083** (el modelo original, **sin** la "S" al final) como mando en **Steam Link** para iPad o iPhone con jailbreak.

> **Estado:** fase 1 terminada y probada. Funcionan la cruceta y los botones; los sticks analógicos todavía no (ver [Hoja de ruta](#hoja-de-ruta)).

---

## Índice

1. [¿Por qué hace falta esto?](#por-qué-hace-falta-esto)
2. [Qué necesitas](#qué-necesitas)
3. [Paso 1: Preparar el control](#paso-1-preparar-el-control)
4. [Paso 2: Conectar el Mac al iPad por SSH](#paso-2-conectar-el-mac-al-ipad-por-ssh)
5. [Paso 3: Instalar el tweak](#paso-3-instalar-el-tweak)
6. [Paso 4: Jugar](#paso-4-jugar)
7. [Cambiar las opciones](#cambiar-las-opciones)
8. [Desinstalar](#desinstalar)
9. [Solución de problemas](#solución-de-problemas)
10. [Limitaciones](#limitaciones)
11. [Hoja de ruta](#hoja-de-ruta)
12. [Para desarrolladores](#para-desarrolladores)
13. [Licencia](#licencia)

---

## ¿Por qué hace falta esto?

- iPadOS solo reconoce como **mando de juego** ciertos controles: los certificados por Apple (MFi), los de Xbox, PlayStation, Nintendo y algunos más.
- El **PG-9083 original** no es ninguno de ellos. En su "modo iOS" funcionaba simulando toques en la pantalla, un truco que Apple bloqueó a partir de iOS 13.4.
- El **PG-9083S** (con "S") es otro modelo: se hace pasar por un mando de PlayStation 4 y funciona sin este proyecto. **Si tu control es un PG-9083S, no necesitas este tweak.**
- Con el interruptor en la posición **"Android & PC"**, el PG-9083 se conecta al iPad como un **teclado iCade**: cada botón "escribe" dos letras, una al pulsarlo y otra al soltarlo.

Este tweak se carga dentro de Steam Link, atrapa esas letras antes de que la app las vea y las convierte en un **mando virtual** (presentado como un mando de Xbox 360) que Steam Link reconoce.

**¿Cómo sé qué modelo tengo?** Cuando el control está emparejado, en el iPad ve a **Ajustes → Bluetooth**:
- si aparece como **`PG-9083`** o **`Newgamepad N1`**, es el modelo original: este proyecto es para ti;
- si aparece como **`DUALSHOCK 4 Wireless Controller`**, es un PG-9083S y no necesitas nada más.

---

## Qué necesitas

**En el iPad o iPhone:**

| Requisito | Notas |
|---|---|
| Jailbreak **rootless** con **palera1n** | Probado en un iPad 6ª generación con iPadOS 17.7.11. |
| **Sileo** | Viene con palera1n. |
| **ElleKit** | Se instala desde Sileo (lo explicamos en el paso 3). Es lo que permite que los tweaks se carguen dentro de las apps. |
| **OpenSSH** | Se instala desde Sileo. Permite controlar el iPad desde el Mac. |
| **Steam Link** de la App Store | Probado con la versión 1.4.5. |

**En el ordenador:**

- Un **Mac**, para copiar el tweak al iPad. Los usuarios de Windows o Linux pueden seguir los mismos pasos con cualquier programa de terminal que tenga `ssh` y `scp`.

> **Si tu jailbreak es semi-tethered (palera1n lo es):** cada vez que reinicies el iPad tendrás que volver a ejecutar palera1n. Mientras no lo hagas, los tweaks (incluido este) no se cargan y el control no funcionará en Steam Link.

---

## Paso 1: Preparar el control

El PG-9083 tiene un **interruptor pequeño en el lado izquierdo** con 4 posiciones. Cada posición se reconoce por el icono que queda **debajo** del interruptor:

| Posición | Icono debajo | Modo | ¿Sirve para este tweak? |
|---|---|---|---|
| Totalmente a la izquierda | Robot Android | Android V3 | No |
| Segunda desde la izquierda | Robot Android | Sin función | No |
| Bajo la manzana | Manzana | iOS | No |
| **Totalmente a la derecha** | **Mando** | **Android & PC** | **Sí** ✅ |

**1.1.** Si el control estaba emparejado antes en otro modo, haz que el iPad lo olvide:
1. Abre **Ajustes** en el iPad y toca **Bluetooth**.
2. En **Mis dispositivos**, toca el icono **ⓘ** que hay a la derecha del control (por ejemplo `PG-9083` o `Newgamepad N1`).
3. Toca **Olvidar este dispositivo** y confirma.

**1.2.** Apaga el control: mantén pulsado el botón **HOME** unos 5 segundos, hasta que se apaguen todas las luces.

**1.3.** Mueve el interruptor **totalmente a la derecha**, hasta que quede debajo del **icono del mando**.

**1.4.** Mantén pulsado **HOME** durante **3 segundos** y suéltalo. Las luces empezarán a parpadear: el control está buscando con qué emparejarse.

**1.5.** En el iPad, en **Ajustes → Bluetooth**, toca **`PG-9083`** en la sección **Otros dispositivos**.

**Qué deberías ver:** el control pasa a **Mis dispositivos** con el texto **Conectado**, y se queda encendida la luz **LED 4**.

**1.6. (Comprobación).** Abre la app **Notas**, crea una nota nueva, toca dentro y pulsa **arriba** en la cruceta del control. Deberían escribirse las letras **`we`**. Si aparecen, el control está listo. Borra la nota.

---

## Paso 2: Conectar el Mac al iPad por SSH

SSH permite enviar órdenes al iPad desde la Terminal del Mac. Solo hay que configurarlo una vez.

### 2.1. Instalar OpenSSH en el iPad

1. En el iPad, abre **Sileo**.
2. Toca la pestaña **Buscar** (la lupa), escribe `OpenSSH` y toca el resultado **OpenSSH**.
3. Toca **Obtener** y luego **Confirmar**.

### 2.2. Averiguar la dirección IP del iPad

1. En el iPad, abre **Ajustes → Wi-Fi**.
2. Toca el icono **ⓘ** que hay junto a la red a la que estás conectado.
3. Anota el número que aparece en **Dirección IP** (por ejemplo `192.168.1.25`). En los pasos siguientes, sustituye **`IP_DEL_IPAD`** por ese número.

> El Mac y el iPad tienen que estar conectados a **la misma red Wi-Fi**.

### 2.3. Abrir la Terminal del Mac

Abre **Finder → Aplicaciones → Utilidades → Terminal**. También puedes pulsar `Cmd + Espacio`, escribir `Terminal` y pulsar Enter.

Todos los comandos de esta guía se **copian, se pegan en la Terminal y se ejecutan pulsando Enter**.

### 2.4. Crear una clave SSH (para no escribir la contraseña cada vez)

Copia, pega y pulsa Enter:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ipad_ed25519 -N "" -C "mac-a-ipad"
```

- `ssh-keygen` crea una "llave" formada por dos archivos: una parte **privada**, que se queda en tu Mac y nunca se comparte, y una parte **pública**, que se copia al iPad.
- `-f ~/.ssh/ipad_ed25519` indica dónde se guarda.
- `-N ""` significa "sin frase de acceso adicional".

**Qué deberías ver:** `Your identification has been saved in ...` y un dibujo hecho de símbolos.

### 2.5. Copiar la clave al iPad

Sustituye `IP_DEL_IPAD` por la IP que anotaste:

```bash
ssh-copy-id -i ~/.ssh/ipad_ed25519.pub mobile@IP_DEL_IPAD
```

- Te pedirá la **contraseña del usuario `mobile`**: es la que configuraste al hacer el jailbreak. Escríbela y pulsa Enter. **Mientras escribes no verás nada en pantalla**; es normal.
- Si te pregunta `Are you sure you want to continue connecting (yes/no)?`, escribe `yes` y pulsa Enter.

**Qué deberías ver:** `Number of key(s) added: 1`.

### 2.6. Crear el atajo "ipad"

Sustituye `IP_DEL_IPAD` y ejecuta:

```bash
printf '\nHost ipad\n  HostName IP_DEL_IPAD\n  User mobile\n  IdentityFile ~/.ssh/ipad_ed25519\n  IdentitiesOnly yes\n' >> ~/.ssh/config
```

A partir de ahora basta con escribir `ssh ipad` para conectarse.

### 2.7. Comprobar que funciona

```bash
ssh ipad 'whoami'
```

**Qué deberías ver:** la palabra **`mobile`**, **sin** que te pida contraseña.

---

## Paso 3: Instalar el tweak

### 3.1. Instalar ElleKit en el iPad

1. En el iPad, abre **Sileo**.
2. Toca **Buscar**, escribe `ElleKit` y toca el resultado **ElleKit**.
3. Toca **Obtener**, luego **Confirmar**.
4. Cuando termine, toca **Reiniciar SpringBoard** (o **Respring**). La pantalla se pondrá negra unos segundos; no es un reinicio completo.

### 3.2. Conseguir el archivo del tweak

Necesitas el archivo **`org.ipega-steamlink.icadesteamlink_<versión>_iphoneos-arm64.deb`**:

- **Opción A:** descárgalo desde la página **Releases** de este repositorio. Guárdalo en tu carpeta **Descargas** del Mac.
- **Opción B:** compílalo tú mismo (ver [Para desarrolladores](#para-desarrolladores)). Quedará en `ICadeSteamLink/packages/`.

### 3.3. Copiar el archivo al iPad

En la Terminal, escribe `scp ` (con un espacio al final), **arrastra el archivo `.deb` desde Finder hasta la ventana de la Terminal** (se escribirá su ruta) y completa el comando para que quede así:

```bash
scp ~/Downloads/org.ipega-steamlink.icadesteamlink_0.2.0_iphoneos-arm64.deb ipad:/var/mobile/Documents/ICadeSteamLink.deb
```

- `scp` copia archivos de un dispositivo a otro.
- La primera ruta es el archivo de tu Mac; `ipad:/var/mobile/Documents/ICadeSteamLink.deb` es dónde se guarda en el iPad.

**Qué deberías ver:** una línea con `100%`.

### 3.4. Instalarlo

```bash
ssh -t ipad 'sudo dpkg -i /var/mobile/Documents/ICadeSteamLink.deb; killall -9 "Steam Link"'
```

- `ssh -t ipad`: se conecta al iPad y permite que te pida la contraseña.
- `sudo dpkg -i …`: instala el tweak con permisos de administrador.
- `killall -9 "Steam Link"`: cierra Steam Link **a la fuerza**, para que cargue el tweak al volver a abrirla. Sin `-9`, Steam Link ignora la orden y sigue abierta.

Escribe la contraseña de `mobile` cuando te la pida (no verás nada mientras escribes) y pulsa Enter.

**Qué deberías ver:** `Setting up org.ipega-steamlink.icadesteamlink (0.2.0) ...` y ningún mensaje con la palabra `error`. Si aparece `No matching processes were found`, Steam Link ya estaba cerrada, y no pasa nada.

---

## Paso 4: Jugar

1. Comprueba que el control está encendido, con el interruptor **totalmente a la derecha**, y aparece como **Conectado** en **Ajustes → Bluetooth**.
2. Abre **Steam Link**.
3. Usa la cruceta para moverte por los menús, **A** para aceptar y **B** para volver.
4. Conéctate a tu PC y juega.

### Botones

| Botón del PG-9083 | Botón que recibe Steam | Letras iCade |
|---|---|---|
| Cruceta y stick izquierdo | Cruceta | `w/e` `x/z` `a/q` `d/c` |
| A | A | `h/r` |
| B | B | `u/f` |
| X | X | `y/t` |
| Y | Y | `j/n` |
| L1 | LB | `i/m` |
| R1 | RB | `k/p` |
| L2 | LT (gatillo, apretado del todo o suelto) | `o/g` |
| R2 | RT (gatillo, apretado del todo o suelto) | `l/v` |
| SELECT, L3 | Igual que L2 (el control envía las mismas letras) | `o/g` |
| START, R3 | Igual que R2 (el control envía las mismas letras) | `l/v` |
| Stick derecho | Nada (el control no envía nada en este modo) | — |

---

## Cambiar las opciones

Las opciones están en el archivo `/var/jb/etc/icadesteamlink.plist` del iPad:

| Opción | Valor por defecto | Qué hace |
|---|---|---|
| `Enabled` | `true` | Con `false`, el tweak no hace nada y Steam Link funciona como si no estuviera instalado. |
| `DpadToLeftStick` | `false` | Con `true`, la cruceta también mueve el **stick izquierdo** (al 100 %). Útil en juegos que solo se manejan con el stick. |
| `DebugLog` | `false` | Con `true`, se escribe un registro de cada pulsación (útil para informar de errores). |

**Para cambiarlas:**

1. Copia el archivo al Escritorio del Mac:
   ```bash
   scp ipad:/var/jb/etc/icadesteamlink.plist ~/Desktop/
   ```
2. En el Escritorio, haz clic derecho sobre `icadesteamlink.plist` → **Abrir con → TextEdit**.
3. Cambia `<false/>` por `<true/>` (o al revés) en la línea que hay **debajo** de la opción que quieras cambiar. Guarda con `Cmd + S` y cierra TextEdit.
4. Copia el archivo de vuelta al iPad:
   ```bash
   scp ~/Desktop/icadesteamlink.plist ipad:/var/mobile/Documents/
   ```
5. Colócalo en su sitio y reinicia Steam Link (pedirá la contraseña de `mobile`):
   ```bash
   ssh -t ipad 'sudo cp /var/mobile/Documents/icadesteamlink.plist /var/jb/etc/icadesteamlink.plist; killall -9 "Steam Link"'
   ```

> Al **actualizar** el tweak a una versión nueva, este archivo vuelve a sus valores por defecto. Repite estos pasos si habías cambiado algo.

---

## Desinstalar

```bash
ssh -t ipad 'sudo dpkg -r org.ipega-steamlink.icadesteamlink; killall -9 "Steam Link"'
```

**Qué deberías ver:** `Removing org.ipega-steamlink.icadesteamlink ...`.

También puedes desinstalarlo desde **Sileo → Instalados**: toca **ICadeSteamLink** y luego **Eliminar**.

---

## Solución de problemas

| Problema | Causa probable | Solución |
|---|---|---|
| En Notas no se escriben letras | El interruptor no está en "Android & PC", o el iPad recuerda el control de otro modo | Repite el [Paso 1](#paso-1-preparar-el-control) completo, incluido "Olvidar este dispositivo". |
| En Steam Link aparecen letras escritas o el control no hace nada | El tweak no se cargó | 1) Si reiniciaste el iPad, vuelve a ejecutar palera1n. 2) Comprueba que ElleKit está instalado en Sileo. 3) Cierra Steam Link a la fuerza (último comando del paso 3.4) y ábrela de nuevo. |
| `ssh: connect to host ... Connection refused` o `timed out` | El iPad está bloqueado, cambió de IP o no tiene el jailbreak activo | Desbloquéalo, comprueba la IP (paso 2.2) y, si se reinició, vuelve a ejecutar palera1n. |
| `Sorry, try again` al usar `sudo` | Contraseña incorrecta | Escribe la contraseña del usuario `mobile` del iPad. |
| `ssh ipad` pide contraseña | La clave no se copió bien | Repite los pasos 2.5 y 2.7. |
| `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED` | Se reinstaló OpenSSH o el jailbreak | Ejecuta `ssh-keygen -R IP_DEL_IPAD` y repite el paso 2.5. |

**Para informar de un error:** activa `DebugLog` (ver [Cambiar las opciones](#cambiar-las-opciones)), reproduce el problema en Steam Link y obtén el registro con:

```bash
ssh ipad 'cat "$(find /var/mobile/Containers/Data/Application -maxdepth 3 -name ICadeSteamLink.log | head -1)"'
```

Copia lo que aparezca y añádelo a tu informe en la sección **Issues** del repositorio.

---

## Limitaciones

- **Todo es digital:** el modo iCade no envía valores intermedios, así que no hay movimientos suaves con el stick.
- **El stick derecho no funciona** en este modo: el control no envía nada.
- **SELECT y START** envían las mismas letras que L2 y R2, así que el tweak no puede distinguirlos.
- Mientras el tweak está activo, un **teclado físico** conectado al iPad no puede escribir dentro de Steam Link las 24 letras que usa iCade (fuera de Steam Link funciona normal).
- Solo funciona **dentro de Steam Link**.

---

## Hoja de ruta

- [x] **Fase 1:** teclado iCade → mando virtual dentro de Steam Link.
- [ ] **Fase 2:** sticks analógicos. Consistirá en un tweak de sistema que lea los datos del control en otro modo del interruptor y los pase al mismo mando virtual. Antes hay que analizar las posiciones "Android V3" e "iOS".
- [ ] Instalación directa desde un repositorio de Sileo.

---

## Para desarrolladores

### Estructura

```
ICadeSteamLink/        Tweak principal (fase 1)
  Tweak.m              Código
  layout/etc/          Archivo de opciones por defecto
docs/
  architecture-phase1.md  Diseño de la fase 1
  hardware-pg9083.md      Cómo ve iPadOS el control: descriptor HID y tabla iCade
tools/
  ICadeProbe/          Tweak de diagnóstico: registra las teclas y los eventos de SDL/UIKit/GameController en Steam Link
  hid-snapshot.sh      Muestra desde el Mac los dispositivos HID externos que ve el iPad
```

### Compilar

Requisitos en el Mac: Xcode, [Homebrew](https://brew.sh) y [Theos](https://theos.dev) con el SDK de iOS 16.5.

```bash
brew install ldid xz dpkg make
```
```bash
git clone --recursive https://github.com/theos/theos.git ~/theos
```

Descarga el SDK `iPhoneOS16.5.sdk` del repositorio [theos/sdks](https://github.com/theos/sdks) y colócalo en `~/theos/sdks/`. Añade `export THEOS="$HOME/theos"` a tu `~/.zshrc`.

Luego compila:

```bash
cd ICadeSteamLink && gmake package FINALPACKAGE=1
```

- Theos **no admite rutas con espacios**: clona este repositorio en una carpeta sin espacios en su ruta.
- Usa `gmake` (GNU make 4 de Homebrew), no el `make` de macOS.

### Cómo funciona

Steam Link 1.4.5 usa **SDL3** como framework dinámico sin cifrar. El tweak:

1. engancha `SDL_InitSubSystem` y, cuando se inicializa el joystick, crea un mando con `SDL_AttachVirtualJoystick`;
2. engancha `-[UIApplication sendEvent:]` y `-[GCKeyboardInput setKeyChangedHandler:]` para consumir las teclas iCade;
3. traduce cada tecla con `SDL_SetJoystickVirtualButton` / `SDL_SetJoystickVirtualAxis`.

Los detalles están en [docs/architecture-phase1.md](docs/architecture-phase1.md).

---

## Licencia

[MIT](LICENSE): puedes usar, modificar y redistribuir este código libremente, siempre que conserves el aviso de copyright y de licencia.

Este proyecto no está afiliado a Valve, a iPega ni a Apple. Steam y Steam Link son marcas de Valve Corporation.
