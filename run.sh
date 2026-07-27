#!/usr/bin/env bash
# GemRun — one-command runner.
#
#   ./run.sh              start the Django API, then build + launch the iOS
#                         app in the Simulator (requires macOS + Xcode)
#   ./run.sh backend      start only the Django API (works on any OS)
#   ./run.sh app          build + launch only the iOS app
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
    python manage.py migrate --no-input | tail -1
    # Suggested demo routes: STREET-FOLLOWING (chained from real OSM walkable
    # ways, never circles), starting at the seed coordinate. Seeds nothing if
    # Overpass is unreachable; skips if already seeded. Opt out: SEED_DEMO=0.
    if [ "${SEED_DEMO:-1}" = "1" ]; then
        python manage.py seed
    fi
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
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE")" 2>/dev/null || true
        rm -f "$PID_FILE"
        echo "Stopped."
    else
        echo "No pid file - nothing to stop."
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
    echo "  - In-app mock instead of the backend:  GEMRUN_API_URL=mock ./run.sh app"
    echo "  - Remove demo data: (cd backend && .venv/bin/python manage.py migrate && .venv/bin/python manage.py seed --clear)"
}

case "$MODE" in
    all)      start_backend; run_app ;;
    backend)  start_backend ;;
    app)      run_app ;;
    stop)     stop_backend ;;
    *)        echo "Usage: ./run.sh [all|backend|app|stop]"; exit 1 ;;
esac
