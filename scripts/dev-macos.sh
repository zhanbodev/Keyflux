#!/bin/sh
# Build and supervise an isolated local development session; no installation.
set -eu

usage() {
    cat <<'HELP'
Usage: ./scripts/dev-macos.sh [options]

Build the Debug app, start a simulated core, and open native settings.
Close the menu bar app or press Ctrl+C to stop this development session.

  --demo             Cycle synthetic working/thinking/output/tool/approval states
  --no-ui            Run only the simulated core (useful for CLI testing)
  --no-build         Reuse the existing Debug bundle
  --check            Build, run core/integration tests, and exit without a UI
  --state-dir PATH   Override the isolated development data directory
  --help, -h         Show this help

Requires macOS, Zig 0.17.0, and Xcode Command Line Tools / Swift 6+.
Python 3 is required only for --check. Physical lighting remains disabled.
HELP
}

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
dev_root="$root/.build/macos-dev"
app="$dev_root/Keyflux Dev.app"
core="$app/Contents/MacOS/keyflux"
project_id=$(printf '%s' "$root" | cksum | awk '{print $1}')
state_dir="/private/tmp/keyflux-dev-$(id -u)-$project_id"
demo=0
no_ui=0
no_build=0
check=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --demo) demo=1 ;;
        --no-ui) no_ui=1 ;;
        --no-build) no_build=1 ;;
        --check) check=1 ;;
        --state-dir)
            shift
            [ "$#" -gt 0 ] && [ -n "$1" ] || { printf '%s\n' 'Missing --state-dir path.' >&2; exit 1; }
            state_dir=$1
            ;;
        --help|-h) usage; exit 0 ;;
        *) printf '%s\n' "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

[ "$(uname -s)" = Darwin ] || { printf '%s\n' 'This launcher requires macOS.' >&2; exit 1; }
for tool in zig swiftc xcrun codesign; do
    command -v "$tool" >/dev/null 2>&1 || { printf '%s\n' "Missing tool: $tool" >&2; exit 1; }
done
case "$state_dir" in
    /*) ;;
    *) state_dir="$PWD/$state_dir" ;;
esac
cd "$root"
if [ "$check" -eq 1 ]; then
    command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'Python 3 is required for --check.' >&2; exit 1; }
    check_core="$root/.build/macos-check/Keyflux Check.app/Contents/MacOS/keyflux"
    if [ "$no_build" -eq 0 ]; then
        sh "$root/scripts/package-macos.sh" --check
    fi
    [ -x "$check_core" ] || { printf '%s\n' 'Check bundle missing. Run --check without --no-build.' >&2; exit 1; }
    python3 "$root/scripts/validate-keyboard-previews.py"
    python3 "$root/tests/preview_layouts.py"
    zig build test
    python3 "$root/tests/integration.py" "$check_core"
    printf '%s\n' 'Independent development build and checks passed.'
    exit 0
fi

mkdir -p "$dev_root/logs"
lock="$dev_root/launcher.lock"
if ! mkdir "$lock" 2>/dev/null; then
    owner=$(cat "$lock/pid" 2>/dev/null || printf '')
    case "$owner" in
        ''|*[!0-9]*) printf '%s\n' "Development lock is incomplete: $lock" >&2; exit 1 ;;
    esac
    if kill -0 "$owner" 2>/dev/null; then
        printf '%s\n' "A development launcher is already running (PID $owner). Stop it with Ctrl+C first." >&2
        exit 1
    fi
    rm -f "$lock/pid"
    rmdir "$lock"
    mkdir "$lock"
fi
printf '%s\n' "$$" > "$lock/pid"
core_pid=''
ui_pid=''
demo_pid=''
owns_instance=0
cleanup() {
    result=$?
    trap - EXIT INT TERM
    set +e
    [ -z "$demo_pid" ] || kill "$demo_pid" 2>/dev/null
    if [ "$owns_instance" -eq 1 ]; then
        "$core" stop --state-dir "$state_dir" >/dev/null 2>&1
    fi
    [ -z "$ui_pid" ] || kill "$ui_pid" 2>/dev/null
    [ -z "$core_pid" ] || kill "$core_pid" 2>/dev/null
    [ -z "$ui_pid" ] || wait "$ui_pid" 2>/dev/null
    [ -z "$core_pid" ] || wait "$core_pid" 2>/dev/null
    [ -z "$demo_pid" ] || wait "$demo_pid" 2>/dev/null
    rm -f "$lock/pid"
    rmdir "$lock" 2>/dev/null
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$state_dir"
state_dir=$(CDPATH= cd -- "$state_dir" && pwd -P)
if [ -x "$core" ] && "$core" status --state-dir "$state_dir" >/dev/null 2>&1; then
    printf '%s\n' "An existing core owns $state_dir. Stop that instance or choose another --state-dir." >&2
    exit 1
fi
if [ "$no_build" -eq 0 ]; then
    sh "$root/scripts/package-macos.sh" --debug
fi
[ -x "$core" ] && [ -x "$app/Contents/MacOS/KeyfluxApp" ] || {
    printf '%s\n' 'Debug bundle missing. Run again without --no-build.' >&2; exit 1;
}

core_log="$dev_root/logs/core-$$.log"
ui_log="$dev_root/logs/ui-$$.log"
"$core" serve --simulate --state-dir "$state_dir" > "$core_log" 2>&1 &
core_pid=$!
attempt=0
until grep -q '"ready":true' "$core_log" && "$core" status --state-dir "$state_dir" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 40 ] || ! kill -0 "$core_pid" 2>/dev/null; then
        printf '%s\n' "Core startup failed. See $core_log" >&2
        cat "$core_log" >&2
        exit 1
    fi
    sleep 0.1
done
owns_instance=1
printf '%s\n' "App: $app" "State: $state_dir" "Core log: $core_log" 'Simulated lighting only. Press Ctrl+C to stop.'

emit_demo() {
    stamp=$(($(date +%s) * 1000000000))
    request=''
    case "$1" in
        tool_started|tool_finished|attention|attention_resolved) request=",\"request_id\":\"call-$turn\"" ;;
    esac
    printf '{"schema_version":1,"provider":"keyflux.dev","session_id":"demo-%s","turn_id":"turn-%s","event_id":"%s-%s","timestamp_ns":%s,"kind":"%s"%s}\n' \
        "$$" "$turn" "$turn" "$1" "$stamp" "$1" "$request" |
        "$core" emit --state-dir "$state_dir" >/dev/null
}
demo_loop() {
    trap - EXIT INT TERM
    demo_sleep_pid=''
    stop_demo() {
        trap - INT TERM
        set +e
        [ -z "$demo_sleep_pid" ] || kill "$demo_sleep_pid" 2>/dev/null
        [ -z "$demo_sleep_pid" ] || wait "$demo_sleep_pid" 2>/dev/null
        exit 0
    }
    trap stop_demo INT TERM
    pause_demo() {
        sleep "$1" &
        demo_sleep_pid=$!
        wait "$demo_sleep_pid"
        demo_sleep_pid=''
    }
    turn=0
    while :; do
        turn=$((turn + 1))
        for phase in turn_started thinking output tool_started attention attention_resolved tool_finished turn_completed; do
            emit_demo "$phase" || return
            pause_demo 2
        done
        pause_demo 3
    done
}
if [ "$demo" -eq 1 ]; then
    printf '%s\n' 'Demo: cycling synthetic agent events (not a Codex connection).'
    demo_loop >> "$core_log" 2>&1 &
    demo_pid=$!
fi
if [ "$no_ui" -eq 0 ]; then
    "$app/Contents/MacOS/KeyfluxApp" --core "$core" --state-dir "$state_dir" > "$ui_log" 2>&1 &
    ui_pid=$!
    printf '%s\n' "UI log: $ui_log"
    wait "$ui_pid"
else
    wait "$core_pid"
fi
