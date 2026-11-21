#!/usr/bin/env bash
set -u

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$DIR" || exit 1

if [[ -f "./index.html" ]]; then
    INDEX_PATH="./index.html"
else
    INDEX_PATH="$(find . -maxdepth 3 -type f -name 'index.html' 2>/dev/null | head -n 1)"
fi

if [[ -z "$INDEX_PATH" ]]; then
    echo "Error: No se encontró index.html." >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: Se requiere python3." >&2
    exit 1
fi

GAME_DIR="$(cd -- "$(dirname -- "$INDEX_PATH")" && pwd)" || exit 1
GAME_ID="$(printf '%s' "$GAME_DIR" | cksum | awk '{print $1}')"
PREF_PORT=$((10000 + (GAME_ID % 50000)))

DATA_ROOT="${XDG_DATA_HOME:-${HOME:-/tmp}/.local/share}/html5-launcher/$GAME_ID"
PROFILE_CHROMIUM="$DATA_ROOT/chromium"
PROFILE_FIREFOX="$DATA_ROOT/firefox"
mkdir -p -- "$PROFILE_CHROMIUM" "$PROFILE_FIREFOX" || {
    echo "Error: No se pudo crear el directorio de datos." >&2
    exit 1
}

PORT_FILE=""
SERVER_PID=""

cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    if [[ -n "${PORT_FILE:-}" ]]; then
        rm -f -- "$PORT_FILE" "${PORT_FILE}.tmp"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PORT_FILE="$(mktemp)" || {
    echo "Error: No se pudo crear el archivo temporal." >&2
    exit 1
}

python3 - "$GAME_DIR" "$PORT_FILE" "$PREF_PORT" <<'PY' &
import http.server, os, sys

os.chdir(sys.argv[1])
port_file = sys.argv[2]
pref_port = int(sys.argv[3])

ServerClass = getattr(http.server, "ThreadingHTTPServer", http.server.HTTPServer)

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

QuietHandler.extensions_map.update({
    ".wasm": "application/wasm",
    ".js": "text/javascript",
    ".mjs": "text/javascript",
    ".json": "application/json",
})

try:
    srv = ServerClass(("127.0.0.1", pref_port), QuietHandler)
except OSError:
    srv = ServerClass(("127.0.0.1", 0), QuietHandler)

with srv:
    tmp_file = port_file + ".tmp"
    with open(tmp_file, "w") as f:
        f.write(str(srv.server_address[1]) + "\n")
    os.replace(tmp_file, port_file)
    srv.serve_forever()
PY
SERVER_PID=$!

PORT=""
for _ in {1..50}; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Error: No se pudo iniciar el servidor." >&2
        exit 1
    fi
    if [[ -s "$PORT_FILE" ]]; then
        PORT="$(<"$PORT_FILE")"
        if [[ "$PORT" =~ ^[0-9]+$ ]]; then
            if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
                break
            fi
        fi
        PORT=""
    fi
    sleep 0.1
done

if [[ -z "$PORT" ]]; then
    echo "Error: El servidor no respondió." >&2
    exit 1
fi

URL="http://127.0.0.1:$PORT/index.html"

# --- Utilidades ---

# Detecta si un navegador está confinado (Snap o Flatpak).
# Los snap no pueden leer carpetas ocultas de $HOME (~/.local, etc.),
# y los flatpak solo escriben dentro de ~/.var/app/...
is_sandboxed() {
    local exe target
    exe="$(command -v "$1" 2>/dev/null)" || return 1
    case "$exe" in
        /snap/*|/var/lib/flatpak/*) return 0 ;;
    esac
    target="$(readlink -f "$exe" 2>/dev/null)"
    case "${target:-}" in
        /snap/*|*/snap/*|*/flatpak/*) return 0 ;;
    esac
    return 1
}

# Ejecuta un navegador y decide si fue útil o hay que probar el siguiente.
# Uso: try_browser <comando> [argumentos...]
try_browser() {
    echo "Abriendo con: $*" >&2
    START_TS=$SECONDS
    "$@"
    local rc=$?
    # Si terminó bien, o si estuvo abierto un tiempo razonable,
    # damos la ejecución por completa.
    if (( rc == 0 )) || (( SECONDS - START_TS >= 10 )); then
        exit $rc
    fi
    echo "Aviso: '$1' falló al arrancar (código $rc); probando el siguiente navegador..." >&2
    return 0
}

# --- Navegadores Chromium: se prueban en orden; si uno falla al
#     arrancar, se continúa con el siguiente en vez de abortar ---

CHROMIUM_CANDIDATES=(
    microsoft-edge
    microsoft-edge-stable
    google-chrome
    google-chrome-stable
    chromium
    chromium-browser
    ungoogled-chromium
    brave-browser
    brave
    vivaldi
    vivaldi-stable
    opera
)

for candidate in "${CHROMIUM_CANDIDATES[@]}"; do
    command -v "$candidate" >/dev/null 2>&1 || continue

    CHROMIUM_ARGS=(
        "--app=$URL"
        --start-maximized
        --no-first-run
        --no-default-browser-check
    )

    if is_sandboxed "$candidate"; then
        # Confinado snap/flatpak: usar el perfil predeterminado del navegador,
        # porque no puede acceder a ~/.local/share/...
        echo "Aviso: $candidate parece instalado como snap/flatpak; se usará su perfil predeterminado." >&2
    else
        CHROMIUM_ARGS+=( "--user-data-dir=$PROFILE_CHROMIUM" )
    fi

    try_browser "$candidate" "${CHROMIUM_ARGS[@]}"
done

# --- Falkon (navegador de KDE, motor QtWebEngine): no entiende las
#     opciones de Chromium, por eso se lanza solo con la URL ---

if command -v falkon >/dev/null 2>&1; then
    try_browser falkon "$URL"
fi

# --- Firefox como respaldo (variantes y detección snap/flatpak) ---

FIREFOX_CMD=()
for candidate in \
    firefox \
    firefox-esr \
    firefox-bin \
    firefox-developer-edition \
    firefox-nightly \
    librewolf
do
    if command -v "$candidate" >/dev/null 2>&1; then
        FIREFOX_CMD=("$candidate")
        break
    fi
done

FIREFOX_SANDBOX=0
if [[ ${#FIREFOX_CMD[@]} -gt 0 ]]; then
    if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
        FIREFOX_SANDBOX=1
    elif [[ "$(readlink -f "$(command -v "${FIREFOX_CMD[0]}")" 2>/dev/null)" =~ /snap/|/flatpak/ ]]; then
        FIREFOX_SANDBOX=1
    fi
else
    if command -v flatpak >/dev/null 2>&1 && flatpak info org.mozilla.firefox >/dev/null 2>&1; then
        FIREFOX_CMD=(flatpak run org.mozilla.firefox)
        FIREFOX_SANDBOX=1
    elif command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
        FIREFOX_CMD=(snap run firefox)
        FIREFOX_SANDBOX=1
    fi
fi

if [[ ${#FIREFOX_CMD[@]} -eq 0 ]]; then
    echo "Error: No se encontró un navegador compatible." >&2
    exit 1
fi

if [[ "$FIREFOX_SANDBOX" -eq 0 ]]; then
    "${FIREFOX_CMD[@]}" --no-remote --profile "$PROFILE_FIREFOX" --new-window "$URL"
    exit $?
else
    START_TS=$SECONDS
    "${FIREFOX_CMD[@]}" --new-window "$URL"
    if (( SECONDS - START_TS < 5 )) && command -v pgrep >/dev/null 2>&1; then
        while pgrep -u "$(id -u)" -f 'firefox' >/dev/null 2>&1; do
            sleep 2
        done
    fi
fi

