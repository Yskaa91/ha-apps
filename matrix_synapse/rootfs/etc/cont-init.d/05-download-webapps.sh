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
# Rollback-Pins, eine Option je Komponente (element_web_pin_version /
# element_call_pin_version):
#   auto     — jeweils das neueste Release der gewählten Quelle.
#   <tag>    — genau dieses Release. Rollback-Knopf: auf einen bekannten guten
#              Fork-Build oder auf einen upstream-Tag stellen, ohne das Image
#              neu zu bauen. Beispiel: element_web_pin_version: v1.12.30-swag.1
#              und element_call_pin_version: v0.26.1-swag.1 — die beiden Forks
#              haben verschiedene Tag-Namespaces, deshalb gibt es zwei Optionen.
#              Ein Pin, den es nicht gibt, wird NICHT still durch die
#              hartkodierte Version ersetzt: das gilt als Download-Fehler und
#              landet im Rollback-Pfad (upstream), ohne Version-Datei.
# Ketesa hat keinen Fork und bleibt deshalb immer auf etkecc/ketesa
# (releases/latest), unabhängig von webapp_source und den Pins.
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

# webapp_normalize_source <quelle> → "swag" oder "upstream" (Default: swag).
# bashio::config liefert den String "null", wenn das Feld (noch) nicht in der
# Supervisor-Konfiguration steht — dann darf nicht still auf upstream
# zurückgeschaltet werden.
webapp_normalize_source() {
    case "${1:-}" in
        swag|upstream) printf '%s' "$1" ;;
        *) printf '%s' "swag" ;;
    esac
}

# webapp_normalize_pin <pin> → "auto" oder der Tag.
# Fehlende Option, leerer String und der bashio-"null"-String bedeuten auto.
webapp_normalize_pin() {
    case "${1:-}" in
        ""|null) printf '%s' "auto" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Pin einer Komponente im Dry-Run: die Optionen element_web_pin_version /
# element_call_pin_version kommen hier aus der Umgebung statt aus bashio.
# Produktiv wird derselbe Normalisierungs-Helfer auf bashio::config angewendet.
webapp_dry_run_pin() {
    case "$1" in
        element-web) printf '%s' "${SWAG_ELEMENT_WEB_PIN_VERSION:-}" ;;
        element-call) printf '%s' "${SWAG_ELEMENT_CALL_PIN_VERSION:-}" ;;
        *) printf '%s' "" ;;
    esac
}

# ── Dry-Run (nur für tests/download-urls.sh) ────────────────────────────────
# SWAG_DRY_RUN=primary|fallback, SWAG_COMPONENT=element-web|element-call,
# SWAG_SOURCE=swag|upstream, SWAG_ELEMENT_WEB_PIN_VERSION /
# SWAG_ELEMENT_CALL_PIN_VERSION = auto|<tag>. Gibt genau eine aufgelöste
# Release-API-URL aus und beendet sich vor jedem bashio-Aufruf.
if [ -n "${SWAG_DRY_RUN:-}" ]; then
    case "${SWAG_DRY_RUN}" in
        primary)
            webapp_api_url "${SWAG_COMPONENT}" \
                "$(webapp_normalize_source "${SWAG_SOURCE:-}")" \
                "$(webapp_normalize_pin "$(webapp_dry_run_pin "${SWAG_COMPONENT}")")"
            ;;
        fallback) webapp_api_url "${SWAG_COMPONENT}" upstream auto ;;
    esac
    exit 0
fi

# webapp_fetch <url> <zielverzeichnis> <komponentenname> → 0 wenn index.html
# gefunden und kopiert. Lädt ein Release-Tarball, extrahiert es und wählt den
# Payload-Root deterministisch: flaches index.html im Wurzelverzeichnis oder
# sonst das erste Top-Level-Verzeichnis, das direkt ein index.html enthält.
# Bewusst NICHT rekursiv suchen.
webapp_fetch() {
    _wf_url="$1"
    _wf_dest="$2"
    _wf_label="$3"
    if ! wget -q "${_wf_url}" -O /tmp/webapp-download.tar.gz 2>/dev/null; then
        return 1
    fi
    # Vor dem Entpacken leeren: sonst liegt die vorherige Komponente noch in
    # /tmp/webapp-extract und die Auswahl unten findet deren Dateien.
    rm -rf /tmp/webapp-extract
    mkdir -p /tmp/webapp-extract "${_wf_dest}"
    tar -xzf /tmp/webapp-download.tar.gz -C /tmp/webapp-extract 2>/dev/null
    rm -f /tmp/webapp-download.tar.gz
    # Payload-Root NICHT per "find -name index.html | head -1" bestimmen:
    # Element Web liefert mehrere index.html mit (App-Root, mobile_guide/,
    # decoder-ring/, widgets/element-call/), find liefert
    # Dateisystem-Reihenfolge — auf dem Live-Host wurde dadurch das
    # Element-Call-Widget nach /data/matrix/element-web kopiert.
    _wf_src=""
    if [ -f /tmp/webapp-extract/index.html ]; then
        _wf_src="/tmp/webapp-extract"
    else
        for _wf_d in /tmp/webapp-extract/*/; do
            if [ -f "${_wf_d}index.html" ]; then _wf_src="${_wf_d}"; break; fi
        done
    fi
    if [ -z "${_wf_src}" ]; then
        bashio::log.error "❌ ${_wf_label}: index.html nicht gefunden!"
        return 1
    fi
    rm -rf "${_wf_dest:?}"/*
    cp -r "${_wf_src}"/. "${_wf_dest}/"
    return 0
}

EW_VERSION_FILE="/data/matrix/.element-web_version"
ADMIN_VERSION_FILE="/data/matrix/.ketesa_version"
EC_VERSION_FILE="/data/matrix/.element-call_version"
mkdir -p /data/matrix

# Quelle und Pins genau einmal lesen (Rollback per Option, kein Rebuild nötig).
# Zwei getrennte Pins, weil die Tag-Namespaces der Forks verschieden sind:
# Element Web v1.12.30-swag.<n>, Element Call v0.26.1-swag.<n>.
WEBAPP_SOURCE="$(webapp_normalize_source "$(bashio::config 'webapp_source')")"
EW_PIN="$(webapp_normalize_pin "$(bashio::config 'element_web_pin_version')")"
EC_PIN="$(webapp_normalize_pin "$(bashio::config 'element_call_pin_version')")"

# ── Element Web ───────────────────────────────────────────────────────────
EW_REPO="$(webapp_repo element-web "${WEBAPP_SOURCE}")"
EW_API="$(webapp_api_url element-web "${WEBAPP_SOURCE}" "${EW_PIN}")"
bashio::log.info "🔍 Prüfe Element Web Version (Quelle: ${WEBAPP_SOURCE}, Pin: ${EW_PIN})..."
EW_LATEST=$(curl -sf \
    "${EW_API}" \
    | jq -r .tag_name 2>/dev/null)
EW_PIN_MISSING=0
if [ -z "${EW_LATEST}" ] || [ "${EW_LATEST}" = "null" ]; then
    if [ "${EW_PIN}" = "auto" ]; then
        # Netzwerkfehler/API-Ausfall: bisheriges Verhalten, letzte bekannte
        # upstream-Version als Notnagel.
        EW_LATEST="v1.11.85"
    else
        # Ein fehlender Pin ist ein echter Fehler: NICHT still auf die
        # hartkodierte Version zurückfallen, sondern laut loggen und wie ein
        # fehlgeschlagener swag-Download behandeln (upstream-Fallback, keine
        # Version-Datei).
        EW_LATEST=""
        EW_PIN_MISSING=1
        bashio::log.error "❌ Element Web: gepinnter Release-Tag ${EW_PIN} nicht gefunden: ${EW_API}"
    fi
fi
EW_INSTALLED=$(cat "${EW_VERSION_FILE}" 2>/dev/null || echo "")

if [ "${EW_PIN_MISSING}" = "0" ] && [ "${EW_INSTALLED}" = "${EW_LATEST}" ]; then
    bashio::log.info "✅ Element Web bereits aktuell (${EW_INSTALLED})"
else
    if [ "${EW_PIN_MISSING}" = "1" ]; then
        EW_URL="https://github.com/${EW_REPO}/releases/download/${EW_PIN}/element-${EW_PIN}.tar.gz"
    else
        bashio::log.info "📥 Lade Element Web ${EW_LATEST} (installiert: ${EW_INSTALLED:-keine})..."
        EW_URL="https://github.com/${EW_REPO}/releases/download/${EW_LATEST}/element-${EW_LATEST}.tar.gz"
    fi
    if [ "${EW_PIN_MISSING}" = "0" ] && webapp_fetch "${EW_URL}" /data/matrix/element-web "Element Web"; then
        echo "${EW_LATEST}" > "${EW_VERSION_FILE}"
        COUNT=$(find /data/matrix/element-web -type f | wc -l)
        bashio::log.info "✅ Element Web ${EW_LATEST} installiert (${COUNT} Dateien)"
    elif [ "${WEBAPP_SOURCE}" = "swag" ] || [ "${EW_PIN_MISSING}" = "1" ]; then
        # Rollback: unser Build ist kaputt/leer oder der Pin existiert nicht →
        # einmal gegen upstream neu laden. Die Version-Datei wird dabei bewusst
        # NICHT geschrieben, damit der nächste Start wieder unseren Build
        # versucht.
        EW_FB_LATEST=$(curl -sf \
            "$(webapp_api_url element-web upstream auto)" \
            | jq -r .tag_name 2>/dev/null)
        [ -z "${EW_FB_LATEST}" ] || [ "${EW_FB_LATEST}" = "null" ] && EW_FB_LATEST="v1.11.85"
        EW_FB_URL="https://github.com/element-hq/element-web/releases/download/${EW_FB_LATEST}/element-${EW_FB_LATEST}.tar.gz"
        bashio::log.error "❌ Element Web Download fehlgeschlagen: ${EW_URL}"
        bashio::log.error "↩️  Fallback auf upstream: ${EW_FB_URL}"
        if webapp_fetch "${EW_FB_URL}" /data/matrix/element-web "Element Web"; then
            COUNT=$(find /data/matrix/element-web -type f | wc -l)
            bashio::log.info "⚠️  Element Web ${EW_FB_LATEST} aus upstream-Fallback installiert (${COUNT} Dateien) — Version-Datei bleibt unverändert, nächster Start probiert wieder ${WEBAPP_SOURCE}"
        else
            bashio::log.error "❌ Element Web: auch upstream-Fallback fehlgeschlagen: ${EW_FB_URL}"
        fi
    else
        bashio::log.error "❌ Element Web Download fehlgeschlagen!"
    fi
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
    EC_API="$(webapp_api_url element-call "${WEBAPP_SOURCE}" "${EC_PIN}")"
    bashio::log.info "🔍 Prüfe Element Call Version (Quelle: ${WEBAPP_SOURCE}, Pin: ${EC_PIN})..."
    EC_LATEST=$(curl -sf \
        "${EC_API}" \
        | jq -r .tag_name 2>/dev/null)
    EC_PIN_MISSING=0
    if [ -z "${EC_LATEST}" ] || [ "${EC_LATEST}" = "null" ]; then
        if [ "${EC_PIN}" = "auto" ]; then
            EC_LATEST="v0.7.0"
        else
            # Wie bei Element Web: fehlender Pin = Download-Fehler, kein stiller
            # Rückfall auf die hartkodierte Version.
            EC_LATEST=""
            EC_PIN_MISSING=1
            bashio::log.error "❌ Element Call: gepinnter Release-Tag ${EC_PIN} nicht gefunden: ${EC_API}"
        fi
    fi
    EC_INSTALLED=$(cat "${EC_VERSION_FILE}" 2>/dev/null || echo "")

    if [ "${EC_PIN_MISSING}" = "0" ] && [ "${EC_INSTALLED}" = "${EC_LATEST}" ]; then
        bashio::log.info "✅ Element Call bereits aktuell (${EC_INSTALLED})"
    else
        if [ "${EC_PIN_MISSING}" = "1" ]; then
            EC_URL="https://github.com/${EC_REPO}/releases/download/${EC_PIN}/element-call-${EC_PIN}.tar.gz"
        else
            bashio::log.info "📥 Lade Element Call ${EC_LATEST} (installiert: ${EC_INSTALLED:-keine})..."

            # Asset URL ermitteln (tarball oder zip)
            EC_URL=$(curl -sf \
                "${EC_API}" \
                | jq -r '.assets[] | select(.name | test("element-call.*\\.tar\\.gz")) | .browser_download_url' \
                | head -1)

            if [ -z "${EC_URL}" ]; then
                EC_URL="https://github.com/${EC_REPO}/releases/download/${EC_LATEST}/element-call-${EC_LATEST}.tar.gz"
            fi
        fi

        if [ "${EC_PIN_MISSING}" = "0" ] && webapp_fetch "${EC_URL}" /data/matrix/element-call "Element Call"; then
            echo "${EC_LATEST}" > "${EC_VERSION_FILE}"
            COUNT=$(find /data/matrix/element-call -type f | wc -l)
            bashio::log.info "✅ Element Call ${EC_LATEST} installiert (${COUNT} Dateien)"
            # Die Widget-Kopie unter Element Web altert sonst still mit: Sie
            # wird nur bei einem Element-Web-Wechsel neu geladen, nicht bei
            # einem Element-Call-Wechsel. Configs (*.json) bleiben unangetastet.
            if [ -d /data/matrix/element-web/widgets/element-call ]; then
                rm -rf /data/matrix/element-web/widgets/element-call/assets \
                    /data/matrix/element-web/widgets/element-call/index.html \
                    /data/matrix/element-web/widgets/element-call/favicon.png
                cp -r /data/matrix/element-call/assets \
                    /data/matrix/element-call/index.html \
                    /data/matrix/element-call/favicon.png \
                    /data/matrix/element-web/widgets/element-call/ 2>/dev/null \
                    && bashio::log.info "✅ Element-Call-Widget-Kopie synchronisiert" \
                    || bashio::log.error "❌ Element-Call-Widget-Kopie konnte nicht synchronisiert werden"
            fi
        elif [ "${WEBAPP_SOURCE}" = "swag" ] || [ "${EC_PIN_MISSING}" = "1" ]; then
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
            if webapp_fetch "${EC_FB_URL}" /data/matrix/element-call "Element Call"; then
                COUNT=$(find /data/matrix/element-call -type f | wc -l)
                bashio::log.info "⚠️  Element Call ${EC_FB_LATEST} aus upstream-Fallback installiert (${COUNT} Dateien) — Version-Datei bleibt unverändert, nächster Start probiert wieder ${WEBAPP_SOURCE}"
            else
                bashio::log.error "❌ Element Call: auch upstream-Fallback fehlgeschlagen: ${EC_FB_URL}"
            fi
        else
            bashio::log.error "❌ Element Call Download fehlgeschlagen: ${EC_URL}"
            ls -la /tmp/webapp-extract/ || true
        fi
    fi
fi

exit 0
