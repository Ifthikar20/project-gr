#!/usr/bin/env bash
# GemRun — one-command runner.
#
#   ./run.sh              start the Django API, then build + launch the iOS
#                         app in the Simulator (requires macOS + Xcode)
#   ./run.sh backend      start only the Django API (works on any OS)
#   ./run.sh app          build + launch only the iOS app
#   ./run.sh stop         stop the background Django API
#
# The app talks to its built-in mock API by default. To point it at the local
# Django server, set AppConfig.apiBaseURL to http://127.0.0.1:8000 in
# Packages/GemRunCore/Sources/CoreNetworking/GemRunAPI.swift and re-run.

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
    python manage.py seed
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
        brew install xcodegen
    fi
    xcodegen

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
    xcrun simctl launch "$UDID" com.gemrun.GemRun

    echo
    echo "GemRun is running. Tips:"
    echo "  - Simulate a location: Simulator menu > Features > Location"
    echo "  - Watch API calls in the Xcode console ([MockAPI] lines)"
    echo "  - Using the local backend? Set AppConfig.apiBaseURL and re-run."
}

case "$MODE" in
    all)      start_backend; run_app ;;
    backend)  start_backend ;;
    app)      run_app ;;
    stop)     stop_backend ;;
    *)        echo "Usage: ./run.sh [all|backend|app|stop]"; exit 1 ;;
esac
