#!/usr/bin/env bash
# Regressionstest für webapp_fetch in 05-download-webapps.sh.
#
# Bug 1: webapp_fetch suchte das entpackte Payload mit
#     find /tmp/webapp-extract -name index.html | head -1
#   Element Web bringt mehrere index.html mit (App-Root, mobile_guide/,
#   decoder-ring/, widgets/element-call/). find liefert
#   Dateisystem-Reihenfolge, auf dem Live-Host wurde dadurch das
#   Element-Call-Widget nach /data/matrix/element-web kopiert.
# Bug 2: /tmp/webapp-extract wurde zwischen zwei Komponenten nie geleert, die
#   zweite Komponente konnte also die Dateien der ersten wiederverwenden.
#
# Läuft ohne bashio und ohne Netzwerk: webapp_fetch wird aus dem echten Script
# extrahiert, wget und die bashio-Logger werden gestubbt.
set -euo pipefail
S="$(dirname "$0")/../rootfs/etc/cont-init.d/05-download-webapps.sh"

# bashio-Stub (webapp_fetch loggt nur)
bashio::log.info()  { printf 'INFO: %s\n' "$*"; }
bashio::log.error() { printf 'ERROR: %s\n' "$*"; }

# webapp_fetch aus dem echten Script holen — kein Duplikat der Logik.
eval "$(sed -n '/^webapp_fetch() {/,/^}/p' "$S")"
[ "$(type -t webapp_fetch)" = "function" ] || { echo "webapp_fetch not found in $S"; exit 1; }

# wget-Stub: legt das vorbereitete Tarball an den Pfad, den webapp_fetch erwartet
STUB_TARBALL=""
wget() { cp "${STUB_TARBALL}" /tmp/webapp-download.tar.gz; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}" /tmp/webapp-extract /tmp/webapp-download.tar.gz; }
trap cleanup EXIT
DEST="${WORK}/dest"

# stage_begin / mkfile <pfad> <inhalt> / pack — bauen ein Tarball aus ${WORK}/stage
stage_begin() { rm -rf "${WORK}/stage"; mkdir -p "${WORK}/stage"; }
mkfile() {
    mkdir -p "$(dirname "${WORK}/stage/$1")"
    printf '%s' "$2" > "${WORK}/stage/$1"
}
pack() { tar -czf "${WORK}/payload.tar.gz" -C "${WORK}/stage" .; STUB_TARBALL="${WORK}/payload.tar.gz"; }

# ── 1. Element-Web-förmig: mehrere index.html, App-Root in einem Unterordner ─
stage_begin
mkfile element-v1.12.30/index.html ROOT
mkfile element-v1.12.30/version v1.12.30
mkfile element-v1.12.30/bundles/x.js js
mkfile element-v1.12.30/mobile_guide/index.html GUIDE
mkfile element-v1.12.30/decoder-ring/index.html RING
mkfile element-v1.12.30/widgets/element-call/index.html WIDGET
pack
webapp_fetch "file:///ew.tar.gz" "${DEST}/ew" "Element Web" || { echo "EW fetch failed"; exit 1; }
[ -f "${DEST}/ew/bundles/x.js" ] || { echo "EW bundles missing — wrong root extracted"; exit 1; }
[ -f "${DEST}/ew/version" ] || { echo "EW version file missing — wrong root extracted"; exit 1; }
grep -q ROOT "${DEST}/ew/index.html" || { echo "EW root index.html not the app root"; exit 1; }
grep -q WIDGET "${DEST}/ew/widgets/element-call/index.html" || { echo "EW widget subdir missing"; exit 1; }

# ── 2. Flaches Tarball (index.html im Wurzelverzeichnis) ───────────────────
stage_begin
mkfile index.html FLAT
mkfile assets/app.js js
pack
webapp_fetch "file:///flat.tar.gz" "${DEST}/flat" "Flat" || { echo "flat fetch failed"; exit 1; }
grep -q FLAT "${DEST}/flat/index.html" || { echo "flat root index.html wrong"; exit 1; }
[ -f "${DEST}/flat/assets/app.js" ] || { echo "flat assets missing"; exit 1; }

# ── 3. Zweite Komponente darf die Dateien der ersten nicht erben ───────────
# Tarball ohne index.html: muss fehlschlagen, auch wenn vorher schon etwas in
# /tmp/webapp-extract lag (dort liegt jetzt der flache Payload aus Schritt 2).
stage_begin
mkfile README.md hi
pack
if webapp_fetch "file:///noindex.tar.gz" "${DEST}/second" "Second"; then
    echo "fetch without index.html returned success"; exit 1
fi
[ ! -f "${DEST}/second/index.html" ] || { echo "second component inherited stale payload"; exit 1; }
[ ! -f "${DEST}/second/assets/app.js" ] || { echo "second component inherited stale assets"; exit 1; }

# ── 4. Zwei Top-Level-Verzeichnisse, nur eines mit index.html ──────────────
stage_begin
mkfile docs/readme.md x
mkfile pkg/index.html PKG
mkfile pkg/bundles/y.js js
pack
webapp_fetch "file:///pkg.tar.gz" "${DEST}/pkg" "Pkg" || { echo "pkg fetch failed"; exit 1; }
grep -q PKG "${DEST}/pkg/index.html" || { echo "pkg root index.html wrong"; exit 1; }
[ -f "${DEST}/pkg/bundles/y.js" ] || { echo "pkg bundles missing"; exit 1; }

echo "webapp-fetch tests passed"
