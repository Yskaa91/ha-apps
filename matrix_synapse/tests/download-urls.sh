#!/usr/bin/env bash
# Prüft die URL-Auflösung von 05-download-webapps.sh im Dry-Run-Modus.
# Läuft ohne bashio und ohne Add-on-Container: das Script beendet sich im
# Dry-Run vor jedem bashio-Aufruf.
set -euo pipefail
S="$(dirname "$0")/../rootfs/etc/cont-init.d/05-download-webapps.sh"
# out <komponente> <quelle> <element_web_pin> <element_call_pin> <modus>
out() {
    SWAG_DRY_RUN="$5" SWAG_COMPONENT="$1" SWAG_SOURCE="$2" \
    SWAG_ELEMENT_WEB_PIN_VERSION="$3" SWAG_ELEMENT_CALL_PIN_VERSION="$4" bash "$S"
}

# Element Web — Quelle swag/upstream, Pin auto/Tag
[ "$(out element-web swag auto auto primary)" = "https://api.github.com/repos/Yskaa91/element-web/releases/latest" ] || { echo "EW swag auto wrong"; exit 1; }
[ "$(out element-web upstream auto auto primary)" = "https://api.github.com/repos/element-hq/element-web/releases/latest" ] || { echo "EW upstream wrong"; exit 1; }
[ "$(out element-web swag v1.12.30-swag.1 auto primary)" = "https://api.github.com/repos/Yskaa91/element-web/releases/tags/v1.12.30-swag.1" ] || { echo "EW pin wrong"; exit 1; }

# Element Call — eigener Tag-Namespace, eigener Pin
[ "$(out element-call swag auto auto primary)" = "https://api.github.com/repos/Yskaa91/element-call/releases/latest" ] || { echo "EC swag auto wrong"; exit 1; }
[ "$(out element-call upstream auto auto primary)" = "https://api.github.com/repos/element-hq/element-call/releases/latest" ] || { echo "EC upstream wrong"; exit 1; }
[ "$(out element-call swag auto v0.26.1-swag.1 primary)" = "https://api.github.com/repos/Yskaa91/element-call/releases/tags/v0.26.1-swag.1" ] || { echo "EC pin wrong"; exit 1; }

# Der Pin der einen Komponente darf die andere nicht beeinflussen: die
# Tag-Namespaces der Forks sind verschieden (v1.12.30-swag.<n> vs
# v0.26.1-swag.<n>), ein gemeinsamer Pin wäre für eine der beiden falsch.
[ "$(out element-call swag v1.12.30-swag.1 auto primary)" = "https://api.github.com/repos/Yskaa91/element-call/releases/latest" ] || { echo "EW pin leaked into EC"; exit 1; }
[ "$(out element-web swag auto v0.26.1-swag.1 primary)" = "https://api.github.com/repos/Yskaa91/element-web/releases/latest" ] || { echo "EC pin leaked into EW"; exit 1; }

# Fehlende Option, leerer String und der bashio-"null"-String bedeuten auto
[ "$(out element-web swag null '' primary)" = "https://api.github.com/repos/Yskaa91/element-web/releases/latest" ] || { echo "EW unset pin default wrong"; exit 1; }
[ "$(out element-call swag '' null primary)" = "https://api.github.com/repos/Yskaa91/element-call/releases/latest" ] || { echo "EC unset pin default wrong"; exit 1; }
[ "$(out element-web null null null primary)" = "https://api.github.com/repos/Yskaa91/element-web/releases/latest" ] || { echo "EW unset-config default wrong"; exit 1; }

# Fallback ist für jede Komponente immer upstream, egal was gepinnt ist
[ "$(out element-web swag auto auto fallback)" = "https://api.github.com/repos/element-hq/element-web/releases/latest" ] || { echo "EW fallback wrong"; exit 1; }
[ "$(out element-call swag auto v0.26.1-swag.1 fallback)" = "https://api.github.com/repos/element-hq/element-call/releases/latest" ] || { echo "EC fallback wrong"; exit 1; }

echo "download-url tests passed"
