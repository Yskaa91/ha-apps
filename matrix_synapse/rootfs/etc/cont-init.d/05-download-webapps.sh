#!/usr/bin/with-contenv bashio
# ============================================================================
# 05-download-webapps.sh — Element Web, Ketesa (ehem. Synapse Admin), Element Call
#
# Jede Komponente trackt ihre installierte Version in einer eigenen
# .*_version Datei unter /data/matrix/. Bei jedem Start wird die aktuelle
# "latest" Version per GitHub API abgefragt und mit der installierten
# verglichen — nur bei Unterschied (oder fehlender Installation) wird neu
# heruntergeladen. Kein "einmal installiert, für immer eingefroren" mehr.
#
# Webapp-Quelle (webapp_source):
#   swag     — Element Web / Element Call kommen aus den Release-Tags unseres
#              Forks (Yskaa91/*). Nur so landen unsere Discord-artigen
#              Voice-Features im Frontend.
#   upstream — Original-Assets von element-hq/*.
# Webapp-Pin (webapp_pin_version):
#   auto     — jeweils das neueste Release der gewählten Quelle.
#   <tag>    — genau dieses Release (z.B. v1.12.30-swag.1). Rollback-Knopf:
#              auf einen bekannten guten Fork-Build oder auf einen
#              upstream-Tag stellen, ohne das Image neu zu bauen.
# Ketesa hat keinen Fork und bleibt deshalb immer auf etkecc/ketesa
# (releases/latest), unabhängig von webapp_source/webapp_pin_version.
#
# set +e: bashio-Umgebung läuft mit set -e, d.h. ein einzelner fehlgeschlagener
# Befehl (z.B. cp auf nicht existierenden Pfad) killt sonst sofort das ganze
# Script und damit per s6 den ganzen Container. Alle Fehlerfälle werden
# stattdessen explizit per if/else behandelt und geloggt.
# ============================================================================
set +e

# ── Quelle/Pin auflösen (auch ohne bashio nutzbar, siehe Dry-Run unten) ─────
# webapp_repo <komponente> <quelle> → "owner/repo" des Release-Repos.
webapp_repo() {
    case "$1" in
        element-web)
            if [ "$2" = "swag" ]; then echo "Yskaa91/element-web"; else echo "element-hq/element-web"; fi
            ;;
        element-call)
            if [ "$2" = "swag" ]; then echo "Yskaa91/element-call"; else echo "element-hq/element-call"; fi
            ;;
        *)
            echo "etkecc/ketesa"
            ;;
    esac
}

# webapp_api_url <komponente> <quelle> <pin> → GitHub Release-API-URL.
# "auto" (oder leer) = releases/latest, sonst releases/tags/<pin>.
webapp_api_url() {
    _wa_repo="$(webapp_repo "$1" "$2")"
    if [ -n "${3:-}" ] && [ "${3}" != "auto" ]; then
        echo "https://api.github.com/repos/${_wa_repo}/releases/tags/${3}"
    else
        echo "https://api.github.com/repos/${_wa_repo}/releases/latest"
    fi
}

# ── Dry-Run (nur für tests/download-urls.sh) ────────────────────────────────
# SWAG_DRY_RUN=primary|fallback, SWAG_COMPONENT=element-web|element-call,
# SWAG_SOURCE=swag|upstream, SWAG_PIN=auto|<tag>. Gibt genau eine aufgelöste
# Release-API-URL aus und beendet sich vor jedem bashio-Aufruf.
if [ -n "${SWAG_DRY_RUN:-}" ]; then
    case "${SWAG_DRY_RUN}" in
        primary)  webapp_api_url "${SWAG_COMPONENT}" "${SWAG_SOURCE:-swag}" "${SWAG_PIN:-auto}" ;;
        fallback) webapp_api_url "${SWAG_COMPONENT}" upstream auto ;;
    esac
    exit 0
fi

# webapp_fetch <url> <zielverzeichnis> → 0 wenn index.html gefunden und kopiert.
# Lädt ein Release-Tarball, extrahiert es und validiert es anhand von
# index.html (flach oder in einem Unterordner, je nach Build-Layout).
webapp_fetch() {
    _wf_url="$1"
    _wf_dest="$2"
    if ! wget -q "${_wf_url}" -O /tmp/webapp-download.tar.gz 2>/dev/null; then
        return 1
    fi
    rm -rf /tmp/webapp-extract
    mkdir -p /tmp/webapp-extract "${_wf_dest}"
    tar -xzf /tmp/webapp-download.tar.gz -C /tmp/webapp-extract 2>/dev/null
    rm -f /tmp/webapp-download.tar.gz
    _wf_index="$(find /tmp/webapp-extract -name "index.html" | head -1)"
    if [ -z "${_wf_index}" ]; then
        return 1
    fi
    rm -rf "${_wf_dest:?}"/*
    cp -r "$(dirname "${_wf_index}")/." "${_wf_dest}/"
    return 0
}

EW_VERSION_FILE="/data/matrix/.element-web_version"
ADMIN_VERSION_FILE="/data/matrix/.ketesa_version"
EC_VERSION_FILE="/data/matrix/.element-call_version"
mkdir -p /data/matrix

# Quelle und Pin genau einmal lesen (Rollback per Option, kein Rebuild nötig).
WEBAPP_SOURCE="$(bashio::config 'webapp_source')"
WEBAPP_PIN="$(bashio::config 'webapp_pin_version')"
[ -n "${WEBAPP_SOURCE}" ] || WEBAPP_SOURCE="swag"
[ -n "${WEBAPP_PIN}" ] || WEBAPP_PIN="auto"

# ── Element Web ───────────────────────────────────────────────────────────
EW_REPO="$(webapp_repo element-web "${WEBAPP_SOURCE}")"
EW_API="$(webapp_api_url element-web "${WEBAPP_SOURCE}" "${WEBAPP_PIN}")"
bashio::log.info "🔍 Prüfe Element Web Version (Quelle: ${WEBAPP_SOURCE}, Pin: ${WEBAPP_PIN})..."
EW_LATEST=$(curl -sf \
    "${EW_API}" \
    | jq -r .tag_name 2>/dev/null)
[ -z "${EW_LATEST}" ] || [ "${EW_LATEST}" = "null" ] && EW_LATEST="v1.11.85"
EW_INSTALLED=$(cat "${EW_VERSION_FILE}" 2>/dev/null || echo "")

if [ "${EW_INSTALLED}" != "${EW_LATEST}" ]; then
    bashio::log.info "📥 Lade Element Web ${EW_LATEST} (installiert: ${EW_INSTALLED:-keine})..."
    EW_URL="https://github.com/${EW_REPO}/releases/download/${EW_LATEST}/element-${EW_LATEST}.tar.gz"
    if webapp_fetch "${EW_URL}" /data/matrix/element-web; then
        echo "${EW_LATEST}" > "${EW_VERSION_FILE}"
        COUNT=$(find /data/matrix/element-web -type f | wc -l)
        bashio::log.info "✅ Element Web ${EW_LATEST} installiert (${COUNT} Dateien)"
    elif [ "${WEBAPP_SOURCE}" = "swag" ]; then
        # Rollback: unser Build ist kaputt/leer → einmal gegen upstream neu
        # laden. Die Version-Datei wird dabei bewusst NICHT geschrieben, damit
        # der nächste Start wieder unseren Build versucht.
        EW_FB_LATEST=$(curl -sf \
            "$(webapp_api_url element-web upstream auto)" \
            | jq -r .tag_name 2>/dev/null)
        [ -z "${EW_FB_LATEST}" ] || [ "${EW_FB_LATEST}" = "null" ] && EW_FB_LATEST="v1.11.85"
        EW_FB_URL="https://github.com/element-hq/element-web/releases/download/${EW_FB_LATEST}/element-${EW_FB_LATEST}.tar.gz"
        bashio::log.error "❌ Element Web Download fehlgeschlagen: ${EW_URL}"
        bashio::log.error "↩️  Fallback auf upstream: ${EW_FB_URL}"
        if webapp_fetch "${EW_FB_URL}" /data/matrix/element-web; then
            COUNT=$(find /data/matrix/element-web -type f | wc -l)
            bashio::log.info "⚠️  Element Web ${EW_FB_LATEST} aus upstream-Fallback installiert (${COUNT} Dateien) — Version-Datei bleibt unverändert, nächster Start probiert wieder ${WEBAPP_SOURCE}"
        else
            bashio::log.error "❌ Element Web: auch upstream-Fallback fehlgeschlagen: ${EW_FB_URL}"
        fi
    else
        bashio::log.error "❌ Element Web Download fehlgeschlagen!"
    fi
else
    bashio::log.info "✅ Element Web bereits aktuell (${EW_INSTALLED})"
fi

# ── Ketesa (ehem. Synapse Admin) UI ──────────────────────────────────────
ENABLE_ADMIN=$(bashio::config 'enable_synapse_admin')
if [ "${ENABLE_ADMIN}" = "true" ]; then
    bashio::log.info "🔍 Prüfe Ketesa Version..."
    ADMIN_LATEST=$(curl -sf \
        "$(webapp_api_url ketesa upstream auto)" \
        | jq -r .tag_name 2>/dev/null)
    [ -z "${ADMIN_LATEST}" ] || [ "${ADMIN_LATEST}" = "null" ] && ADMIN_LATEST="v1.5.1"
    ADMIN_INSTALLED=$(cat "${ADMIN_VERSION_FILE}" 2>/dev/null || echo "")

    if [ "${ADMIN_INSTALLED}" != "${ADMIN_LATEST}" ]; then
        bashio::log.info "📥 Lade Ketesa ${ADMIN_LATEST} (installiert: ${ADMIN_INSTALLED:-keine})..."
        if wget -q "https://github.com/etkecc/ketesa/releases/download/${ADMIN_LATEST}/ketesa.tar.gz" \
            -O /tmp/synapse-admin.tar.gz 2>/dev/null; then
            mkdir -p /tmp/admin-extract /data/matrix/synapse-admin
            tar -xzf /tmp/synapse-admin.tar.gz -C /tmp/admin-extract 2>/dev/null

            # Ketesa packt teils flach, teils in einem Unterordner — robust suchen
            if [ -f /tmp/admin-extract/index.html ]; then
                ADMINDIR="/tmp/admin-extract"
            else
                ADMINDIR=$(find /tmp/admin-extract -maxdepth 2 -name "index.html" | head -1 | xargs dirname 2>/dev/null)
            fi

            if [ -n "${ADMINDIR}" ] && [ -f "${ADMINDIR}/index.html" ]; then
                rm -rf /data/matrix/synapse-admin/*
                cp -r "${ADMINDIR}/." /data/matrix/synapse-admin/
                echo "${ADMIN_LATEST}" > "${ADMIN_VERSION_FILE}"
                COUNT=$(find /data/matrix/synapse-admin -type f | wc -l)
                bashio::log.info "✅ Ketesa ${ADMIN_LATEST} installiert (${COUNT} Dateien)"
            else
                bashio::log.error "❌ Ketesa: index.html nicht gefunden!"
            fi
            rm -f /tmp/synapse-admin.tar.gz && rm -rf /tmp/admin-extract
        else
            bashio::log.error "❌ Ketesa Download fehlgeschlagen!"
        fi
    else
        bashio::log.info "✅ Ketesa bereits aktuell (${ADMIN_INSTALLED})"
    fi
else
    bashio::log.info "⏭️  Ketesa-Download übersprungen (enable_synapse_admin: false)"
fi

# ── Element Call (nur wenn Voice/Video aktiviert) ────────────────────────
ENABLE_VOICE=$(bashio::config 'enable_voice_calls')
if [ "${ENABLE_VOICE}" = "true" ]; then
    EC_REPO="$(webapp_repo element-call "${WEBAPP_SOURCE}")"
    EC_API="$(webapp_api_url element-call "${WEBAPP_SOURCE}" "${WEBAPP_PIN}")"
    bashio::log.info "🔍 Prüfe Element Call Version (Quelle: ${WEBAPP_SOURCE}, Pin: ${WEBAPP_PIN})..."
    EC_LATEST=$(curl -sf \
        "${EC_API}" \
        | jq -r .tag_name 2>/dev/null)
    [ -z "${EC_LATEST}" ] || [ "${EC_LATEST}" = "null" ] && EC_LATEST="v0.7.0"
    EC_INSTALLED=$(cat "${EC_VERSION_FILE}" 2>/dev/null || echo "")

    if [ "${EC_INSTALLED}" != "${EC_LATEST}" ]; then
        bashio::log.info "📥 Lade Element Call ${EC_LATEST} (installiert: ${EC_INSTALLED:-keine})..."

        # Asset URL ermitteln (tarball oder zip)
        EC_URL=$(curl -sf \
            "${EC_API}" \
            | jq -r '.assets[] | select(.name | test("element-call.*\\.tar\\.gz")) | .browser_download_url' \
            | head -1)

        if [ -z "${EC_URL}" ]; then
            EC_URL="https://github.com/${EC_REPO}/releases/download/${EC_LATEST}/element-call-${EC_LATEST}.tar.gz"
        fi

        if webapp_fetch "${EC_URL}" /data/matrix/element-call; then
            echo "${EC_LATEST}" > "${EC_VERSION_FILE}"
            COUNT=$(find /data/matrix/element-call -type f | wc -l)
            bashio::log.info "✅ Element Call ${EC_LATEST} installiert (${COUNT} Dateien)"
        elif [ "${WEBAPP_SOURCE}" = "swag" ]; then
            # Rollback wie bei Element Web: einmal upstream, Version-Datei
            # bewusst nicht schreiben.
            EC_FB_API="$(webapp_api_url element-call upstream auto)"
            EC_FB_LATEST=$(curl -sf "${EC_FB_API}" | jq -r .tag_name 2>/dev/null)
            [ -z "${EC_FB_LATEST}" ] || [ "${EC_FB_LATEST}" = "null" ] && EC_FB_LATEST="v0.7.0"
            EC_FB_URL=$(curl -sf "${EC_FB_API}" \
                | jq -r '.assets[] | select(.name | test("element-call.*\\.tar\\.gz")) | .browser_download_url' \
                | head -1)
            if [ -z "${EC_FB_URL}" ]; then
                EC_FB_URL="https://github.com/element-hq/element-call/releases/download/${EC_FB_LATEST}/element-call-${EC_FB_LATEST}.tar.gz"
            fi
            bashio::log.error "❌ Element Call Download fehlgeschlagen: ${EC_URL}"
            bashio::log.error "↩️  Fallback auf upstream: ${EC_FB_URL}"
            if webapp_fetch "${EC_FB_URL}" /data/matrix/element-call; then
                COUNT=$(find /data/matrix/element-call -type f | wc -l)
                bashio::log.info "⚠️  Element Call ${EC_FB_LATEST} aus upstream-Fallback installiert (${COUNT} Dateien) — Version-Datei bleibt unverändert, nächster Start probiert wieder ${WEBAPP_SOURCE}"
            else
                bashio::log.error "❌ Element Call: auch upstream-Fallback fehlgeschlagen: ${EC_FB_URL}"
            fi
        else
            bashio::log.error "❌ Element Call Download fehlgeschlagen: ${EC_URL}"
            ls -la /tmp/webapp-extract/ || true
        fi
    else
        bashio::log.info "✅ Element Call bereits aktuell (${EC_INSTALLED})"
    fi
fi

exit 0
