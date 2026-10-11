#!/usr/bin/env bash
# Prüft die URL-Auflösung von 05-download-webapps.sh im Dry-Run-Modus.
# Läuft ohne bashio und ohne Add-on-Container: das Script beendet sich im
# Dry-Run vor jedem bashio-Aufruf.
set -euo pipefail
S="$(dirname "$0")/../rootfs/etc/cont-init.d/05-download-webapps.sh"
out() { SWAG_DRY_RUN="$4" SWAG_COMPONENT="$1" SWAG_SOURCE="$2" SWAG_PIN="$3" bash "$S"; }
[ "$(out element-web swag auto primary)" = "https://api.github.com/repos/Yskaa91/element-web/releases/latest" ] || { echo "EW swag auto wrong"; exit 1; }
[ "$(out element-web upstream auto primary)" = "https://api.github.com/repos/element-hq/element-web/releases/latest" ] || { echo "EW upstream wrong"; exit 1; }
[ "$(out element-call swag v0.26.1-swag.1 primary)" = "https://api.github.com/repos/Yskaa91/element-call/releases/tags/v0.26.1-swag.1" ] || { echo "EC pin wrong"; exit 1; }
[ "$(out element-web swag auto fallback)" = "https://api.github.com/repos/element-hq/element-web/releases/latest" ] || { echo "EW fallback wrong"; exit 1; }
# bashio::config liefert "null" für ein Feld, das (noch) nicht in der
# Supervisor-Konfiguration steht — das darf nicht auf upstream umschalten.
[ "$(out element-web null null primary)" = "https://api.github.com/repos/Yskaa91/element-web/releases/latest" ] || { echo "EW unset-config default wrong"; exit 1; }
echo "download-url tests passed"
