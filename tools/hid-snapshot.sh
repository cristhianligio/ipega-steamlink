#!/bin/zsh
# hid-snapshot.sh — Captura los dispositivos HID que ve el iPad y muestra los que
# NO son componentes internos de Apple (por ejemplo, un control Bluetooth).
#
# Uso (en el Mac):   ./hid-snapshot.sh <etiqueta>
#   ej.:              ./hid-snapshot.sh pos4-android-pc
#
# Requiere el alias SSH "ipad" (ver README). Guarda la salida completa en
# captures/<fecha>-<etiqueta>.txt para poder compararla después.

set -euo pipefail
label="${1:-sin-etiqueta}"
dir="$(cd "$(dirname "$0")" && pwd)/captures"
mkdir -p "$dir"
out="$dir/$(date +%Y%m%d-%H%M%S)-$label.txt"

ssh -o BatchMode=yes -o ConnectTimeout=8 ipad 'ioreg -l -w0 -r -c IOHIDDevice' > "$out"
echo "Captura completa guardada en: $out"
echo

python3 -I - "$out" <<'EOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# Cada dispositivo empieza en una línea "+-o Nombre  <class ...>" del nivel superior.
blocks = re.split(r"\n(?=\+-o )", text)
keys = ["Product", "Manufacturer", "Transport", "VendorID", "ProductID",
        "PrimaryUsagePage", "PrimaryUsage", "DeviceUsagePairs", "ReportDescriptor"]
found = 0
for b in blocks:
    transport = re.search(r'"Transport" = "([^"]*)"', b)
    transport = transport.group(1) if transport else ""
    if transport in ("SPU", "SPI", "Audio", ""):
        continue  # componentes internos del iPad
    found += 1
    print(b.splitlines()[0][:150])
    for k in keys:
        m = re.search(r'"%s" = (.*)' % k, b)
        if m:
            print(f"    {k} = {m.group(1)}")
    print()
if not found:
    print("No hay ningún dispositivo HID externo conectado (¿el control está apagado o desconectado?).")
EOF
