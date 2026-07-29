#!/usr/bin/env bash
# GemRun — one-command runner.
#
#   ./run.sh              start the Django API, then build + launch the iOS
#                         app in the Simulator (requires macOS + Xcode)
#   ./run.sh backend      start only the Django API (works on any OS)
#   ./run.sh app          build + launch only the iOS app
#   ./run.sh device       backend + build/install/launch signed on a paired
#                         physical iPhone (uses the Mac's LAN IP for the API)
#   ./run.sh stop         stop the background Django API
#
# Simulator builds read LIVE data from the local Django API automatically
# (AppConfig resolves GEMRUN_API_URL → Info.plist → simulator default).
# Force the in-app mock instead with:  GEMRUN_API_URL=mock ./run.sh app

set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-all}"
API_PORT=8000
PID_FILE="backend/.server.pid"

say() { printf '\n== %s\n' "$*"; }

start_backend() {
    say "Backend: Django API on port ${API_PORT}"
    command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }

    if curl -sf "http://127.0.0.1:${API_PORT}/v1/gems/catalog" >/dev/null 2>&1; then
        echo "Already running - skipping."
        return
    fi

    cd backend
    if [ ! -d .venv ]; then
        echo "Creating virtualenv..."
        python3 -m venv .venv
    fi
    # shellcheck disable=SC1091
    source .venv/bin/activate
    pip install -q -r requirements.txt

    # Verbose startup: show exactly what this backend will run with.
    echo "-- Python:  $(python --version 2>&1)  (venv: backend/.venv)"
    echo "-- Git:     $(git log --oneline -1 2>/dev/null || echo 'unknown')"
    echo "-- Config:  WALKABILITY_MODE=${WALKABILITY_MODE:-overpass}" \
         "PRESENCE_DROP_MIN_RUNS=${PRESENCE_DROP_MIN_RUNS:-0}" \
         "SEED_DEMO=${SEED_DEMO:-1}" \
         "GEMRUN_LOG_LEVEL=${GEMRUN_LOG_LEVEL:-INFO}"
    python - <<'PYEOF'
import ssl, urllib.request
try:
    import certifi
    ctx = ssl.create_default_context(cafile=certifi.where())
    src = "certifi"
except ImportError:
    ctx, src = None, "system default (certifi NOT installed)"
try:
    urllib.request.urlopen("https://overpass-api.de", timeout=8, context=ctx)
    print(f"-- HTTPS:   OK via {src}")
except urllib.error.HTTPError as exc:
    # An HTTP status (even 4xx) means TLS + connection succeeded.
    print(f"-- HTTPS:   OK via {src} (server said {exc.code}, connection fine)")
except Exception as exc:
    print(f"-- HTTPS:   FAILING via {src}: {exc!r}")
    print("            -> Overpass unreachable: no seeded routes; off-route gem spawning stays empty (fail closed)")
PYEOF
    python manage.py migrate --no-input | tail -1
    # Suggested demo routes: STREET-FOLLOWING (chained from real OSM walkable
    # ways, never circles), starting at the seed coordinate. Seeds nothing if
    # Overpass is unreachable; skips if already seeded. Opt out: SEED_DEMO=0.
    if [ "${SEED_DEMO:-1}" = "1" ]; then
        python manage.py seed
    fi
    # Stock gems NOW (not just on first map open) and log what was created
    # + the area's full gem inventory.
    PRESENCE_DROP_MIN_RUNS="${PRESENCE_DROP_MIN_RUNS:-0}" \
        python manage.py stock_gems
    # Dev gate: any published route spawns system gems immediately (no
    # 3-run popularity wait). Override: PRESENCE_DROP_MIN_RUNS=3 ./run.sh
    PRESENCE_DROP_MIN_RUNS="${PRESENCE_DROP_MIN_RUNS:-0}" \
        nohup python manage.py runserver "0.0.0.0:${API_PORT}" \
        > .server.log 2>&1 &
    echo $! > .server.pid
    cd ..

    for _ in $(seq 1 20); do
        if curl -sf "http://127.0.0.1:${API_PORT}/v1/gems/catalog" >/dev/null 2>&1; then
            echo "API up: http://127.0.0.1:${API_PORT}/v1  (log: backend/.server.log)"
            return
        fi
        sleep 0.5
    done
    echo "API failed to start - see backend/.server.log"
    exit 1
}

stop_backend() {
    say "Stopping backend"
    # The pid file goes stale the moment runserver's auto-reloader replaces
    # its process, so kill by PORT — whatever is actually answering on 8000.
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
    fi
    PIDS=$(lsof -ti tcp:"$API_PORT" 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        echo "$PIDS" | xargs kill 2>/dev/null || true
        sleep 1
    fi
    if curl -sf "http://127.0.0.1:${API_PORT}/v1/gems/catalog" >/dev/null 2>&1; then
        echo "WARNING: something still answers on port ${API_PORT}."
    else
        echo "Stopped."
    fi
}

run_app() {
    say "iOS app: build + launch in the Simulator"
    [ "$(uname)" = "Darwin" ] || { echo "The iOS app needs macOS + Xcode."; exit 1; }
    command -v xcodebuild >/dev/null || { echo "Xcode is required (xcode-select --install)"; exit 1; }

    if ! command -v xcodegen >/dev/null; then
        echo "Installing XcodeGen..."
        # Skip Homebrew's auto-update + tap-trust checks so unrelated taps
        # (e.g. mongodb/brew, stripe/stripe-cli) don't break this install.
        HOMEBREW_NO_AUTO_UPDATE=1 \
        HOMEBREW_NO_INSTALL_CLEANUP=1 \
        HOMEBREW_NO_REQUIRE_TAP_TRUST=1 \
            brew install xcodegen || {
            echo
            echo "brew install xcodegen failed. Install it manually, e.g.:"
            echo "  brew trust mongodb/brew stripe/stripe-cli   # trust taps once"
            echo "  brew install xcodegen"
            echo "or grab the binary from https://github.com/yonaskolb/XcodeGen/releases"
            exit 1
        }
    fi
    xcodegen

    # XcodeGen 2.46 emits objectVersion 77 (Xcode 16). Downgrade to 63 so
    # Xcode 15.3+ can also open the project. Safe because project.yml doesn't
    # use Xcode-16-only features (file system synchronized groups, etc).
    XCODE_MAJOR=$(xcodebuild -version | awk '/^Xcode /{split($2,v,"."); print v[1]}')
    if [ "${XCODE_MAJOR:-0}" -lt 16 ]; then
        /usr/bin/sed -i '' 's/objectVersion = 77;/objectVersion = 63;/' \
            GemRun.xcodeproj/project.pbxproj
    fi

    UDID=$(xcrun simctl list devices available | grep -Eo 'iPhone [^(]*\(([0-9A-F-]+)\)' \
        | head -1 | grep -Eo '[0-9A-F-]{36}')
    [ -n "$UDID" ] && echo "Simulator: $UDID" \
        || { echo "No available iPhone simulator found."; exit 1; }

    say "Building (first build takes a few minutes)"
    xcodebuild build \
        -project GemRun.xcodeproj \
        -scheme GemRun \
        -destination "id=${UDID}" \
        -derivedDataPath build \
        CODE_SIGNING_ALLOWED=NO \
        -quiet

    APP_PATH="build/Build/Products/Debug-iphonesimulator/GemRun.app"
    [ -d "$APP_PATH" ] || { echo "Build product not found at $APP_PATH"; exit 1; }

    say "Launching"
    xcrun simctl boot "$UDID" 2>/dev/null || true
    open -a Simulator
    xcrun simctl install "$UDID" "$APP_PATH"
    # SIMCTL_CHILD_* forwards the env var into the app process: the UI reads
    # live data from the local Django API unless GEMRUN_API_URL says otherwise.
    SIMCTL_CHILD_GEMRUN_API_URL="${GEMRUN_API_URL:-http://127.0.0.1:${API_PORT}}" \
        xcrun simctl launch "$UDID" com.gemrun.GemRun

    echo
    echo "GemRun is running against ${GEMRUN_API_URL:-http://127.0.0.1:${API_PORT}}. Tips:"
    echo "  - Simulate a location: Simulator menu > Features > Location"
    echo "  - Live backend logs (spawns, Overpass, requests):  tail -f backend/.server.log"
    echo "  - Gem-chain health:  (cd backend && .venv/bin/python manage.py diagnose)"
    echo "  - In-app mock instead of the backend:  GEMRUN_API_URL=mock ./run.sh app"
    echo "  - Remove demo data: (cd backend && .venv/bin/python manage.py migrate && .venv/bin/python manage.py seed --clear)"
}

run_device() {
    say "iOS app: build + install on paired iPhone"
    [ "$(uname)" = "Darwin" ] || { echo "Device install needs macOS + Xcode."; exit 1; }
    command -v xcodebuild >/dev/null || { echo "Xcode is required."; exit 1; }

    if ! command -v xcodegen >/dev/null; then
        HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
        HOMEBREW_NO_REQUIRE_TAP_TRUST=1 brew install xcodegen
    fi

    # Mac's LAN IP so the phone can reach Django. GEMRUN_LAN_IP=<ip> overrides.
    LAN_IP="${GEMRUN_LAN_IP:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)}"
    [ -n "$LAN_IP" ] || { echo "Couldn't detect LAN IP. Set GEMRUN_LAN_IP=<ip>."; exit 1; }
    API_URL="http://${LAN_IP}:${API_PORT}"

    # Bake URL into Debug via xcconfig so tapping the icon later still works
    # (env-var override only fires when we launch through devicectl).
    # `//` in xcconfig starts a comment; $() breaks the parser.
    cat > Configs/DevAPI.xcconfig <<EOF
// AUTO-GENERATED by \`./run.sh device\` — do not edit by hand.
// Regenerate after joining a new Wi-Fi (the Mac's LAN IP changes).
GEMRUN_API_URL = http:/\$()/${LAN_IP}:${API_PORT}
EOF
    echo "Backend URL for the phone: ${API_URL}"

    xcodegen
    XCODE_MAJOR=$(xcodebuild -version | awk '/^Xcode /{split($2,v,"."); print v[1]}')
    if [ "${XCODE_MAJOR:-0}" -lt 16 ]; then
        /usr/bin/sed -i '' 's/objectVersion = 77;/objectVersion = 63;/' \
            GemRun.xcodeproj/project.pbxproj
    fi

    # devicectl uses a CoreDevice UUID (36 chars); xcodebuild wants the
    # hardware ECID (e.g. 00008120-000639261EF8201E) — they aren't the same.
    # `|| true` everywhere: devicectl exits non-zero when CoreDevice is
    # momentarily wedged, and set -e/pipefail would kill the script with
    # no message at all (it did). Detection failure must never be fatal —
    # the wait loop below is the recovery path.
    find_device() {
        { xcrun devicectl list devices 2>/dev/null || true; } \
            | awk '$0 ~ /available/ && $0 !~ /unavailable/ \
                   {for(i=1;i<=NF;i++)if($i~/^[0-9A-F-]{36}$/){print $i;exit}}'
    }
    DEVCTL_UDID=$(find_device)
    if [ -z "$DEVCTL_UDID" ]; then
        KNOWN=$({ xcrun devicectl list devices 2>/dev/null || true; } \
            | awk '/unavailable/{print $1; exit}')
        echo
        if [ -n "$KNOWN" ]; then
            echo "iPhone \"$KNOWN\" is paired but UNREACHABLE right now. To fix:"
        else
            echo "No iPhone is visible to this Mac yet. To fix:"
        fi
        echo "  1. Plug the iPhone in with a cable and UNLOCK it (most reliable), or"
        echo "  2. for wireless: wake + unlock it on the SAME Wi-Fi as this Mac,"
        echo "     with 'Connect via network' checked in Xcode > Window > Devices."
        echo "  (First time on a phone: accept 'Trust This Computer' and enable"
        echo "   Settings > Privacy & Security > Developer Mode.)"
        echo
        echo "Waiting up to 3 minutes for the phone to come online (Ctrl-C to stop)..."
        for _ in $(seq 1 36); do
            sleep 5
            DEVCTL_UDID=$(find_device)
            if [ -n "$DEVCTL_UDID" ]; then
                echo "Phone is online."
                break
            fi
            printf '.'
        done
        echo
    fi
    if [ -z "$DEVCTL_UDID" ]; then
        echo "Still no reachable iPhone. Raw device status (with errors shown):"
        xcrun devicectl list devices || true
        echo
        echo "If the phone is plugged in but absent/unavailable above, check:"
        echo "  - Does macOS even see it on USB?  system_profiler SPUSBDataType | grep -i iphone"
        echo "    (no output = cable/port problem — many cables are charge-only)"
        echo "  - Xcode > Window > Devices and Simulators — any yellow warning on the phone?"
        echo "    ('Developer Mode disabled' / 'not trusted' / 'preparing device')"
        echo "  - Wedged services: sudo pkill -f usbmuxd  (it restarts), then replug."
        exit 1
    fi
    # Match the iOS ECID pattern (8 hex, dash, 16 hex) — unique to iPhone/iPad.
    XCODE_UDID=$(xcrun xctrace list devices 2>&1 \
        | grep -Eo '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)
    [ -n "$XCODE_UDID" ] || { echo "Couldn't get hardware UDID from xctrace."; exit 1; }
    DEV_NAME=$(xcrun devicectl list devices 2>/dev/null | awk -v u="$DEVCTL_UDID" '$0 ~ u {print $1; exit}')
    echo "Device: ${DEV_NAME:-<unknown>}  (build id ${XCODE_UDID}, install id ${DEVCTL_UDID})"

    # Build outside Desktop/iCloud — the fileprovider daemon adds xattrs
    # (FinderInfo, fpfs#P) that codesign refuses to sign around.
    xattr -cr App Packages 2>/dev/null || true
    rm -rf /tmp/gemrun-build-device

    say "Building (signed for device — first build takes a few minutes)"
    xcodebuild build \
        -project GemRun.xcodeproj \
        -scheme GemRun \
        -destination "platform=iOS,id=${XCODE_UDID}" \
        -derivedDataPath /tmp/gemrun-build-device \
        -allowProvisioningUpdates \
        -quiet

    APP_PATH="/tmp/gemrun-build-device/Build/Products/Debug-iphoneos/GemRun.app"
    [ -d "$APP_PATH" ] || { echo "Build product not found at $APP_PATH"; exit 1; }

    say "Installing on device"
    xcrun devicectl device install app --device "$DEVCTL_UDID" "$APP_PATH"

    say "Launching"
    xcrun devicectl device process launch \
        --device "$DEVCTL_UDID" \
        --environment-variables "{\"GEMRUN_API_URL\":\"${API_URL}\"}" \
        com.gemrun.GemRun 2>/dev/null || \
    xcrun devicectl device process launch --device "$DEVCTL_UDID" com.gemrun.GemRun

    echo
    echo "GemRun is on ${DEV_NAME:-your iPhone} → ${API_URL}. Tips:"
    echo "  - First launch: tap 'Allow While Using App' when asked for location."
    echo "  - Phone must stay on the same Wi-Fi as the Mac (${LAN_IP})."
    echo "  - Backend logs:  tail -f backend/.server.log"
    echo "  - If iOS blocks the app: Settings > General > VPN & Device Management"
    echo "    > trust 'Apple Development: <your Apple ID>'."
}

case "$MODE" in
    all)      start_backend; run_app ;;
    backend)  start_backend ;;
    app)      run_app ;;
    device)   start_backend; run_device ;;
    stop)     stop_backend ;;
    *)        echo "Usage: ./run.sh [all|backend|app|device|stop]"; exit 1 ;;
esac
