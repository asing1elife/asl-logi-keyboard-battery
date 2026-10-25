#!/bin/bash
# All launchctl/process/privileged operations are simulated in a temporary dir.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/ghub.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/state"
GHUB_AGENT_PLIST="$TEST_DIR/agent.plist"
GHUB_UPDATER_PLIST="$TEST_DIR/updater.plist"
touch "$GHUB_AGENT_PLIST" "$GHUB_UPDATER_PLIST"
DYNAMIC=application.com.logi.ghub.agent.123.456
key() { printf '%s' "$1" | tr / @; }
marker() { printf '%s/state/%s.%s' "$TEST_DIR" "$(key "$1")" "$2"; }
pause() { :; }
process_snapshot() { cat "$TEST_DIR/processes"; }
prepare_admin() {
    echo AUTH >> "$TEST_DIR/events"
    [ ! -e "$TEST_DIR/reject-auth" ]
}
admin() {
    [ "$1" == /bin/launchctl ] || { echo 'Unexpected privileged command' >&2; return 1; }
    shift; lc "$@"
}
lc() {
    local domain label target
    case "$1" in
        list)
            printf 'PID\tStatus\tLabel\n'
            for label in "$GHUB_AGENT" "$DYNAMIC"; do
                if [ -e "$(marker "$GHUB_GUI/$label" loaded)" ]; then printf '9000\t0\t%s\n' "$label"; fi
            done
            printf '300\t0\tcom.logi.optionsplus\n' ;;
        print-disabled)
            domain="$2"
            if [ "$domain" == system ]; then label="$GHUB_UPDATER"; else label="$GHUB_AGENT $DYNAMIC"; fi
            echo 'disabled services = {'
            for target in $label; do
                if [ -e "$(marker "$domain/$target" disabled)" ]; then printf ' "%s" => disabled\n' "$target"; fi
            done
            echo ' "com.logi.optionsplus" => disabled'
            echo '}' ;;
        print) [ -e "$(marker "$2" loaded)" ] ;;
        disable)
            if [ -e "$TEST_DIR/reject-disable" ]; then return 1; fi
            echo "DISABLE $2" >> "$TEST_DIR/events"; touch "$(marker "$2" disabled)" ;;
        enable) echo "ENABLE $2" >> "$TEST_DIR/events"; rm -f "$(marker "$2" disabled)" ;;
        bootout) echo "BOOTOUT $2" >> "$TEST_DIR/events"; rm -f "$(marker "$2" loaded)" ;;
        bootstrap)
            if [ "$2" == system ]; then target="system/$GHUB_UPDATER"; else target="$GHUB_GUI/$GHUB_AGENT"; fi
            echo "BOOTSTRAP $target" >> "$TEST_DIR/events"; touch "$(marker "$target" loaded)" ;;
        *) echo "Unexpected launchctl operation: $*" >&2; return 1 ;;
    esac
}
reset_case() {
    rm -f "$TEST_DIR/state/"* "$TEST_DIR/stubborn" "$TEST_DIR/reject-auth" "$TEST_DIR/reject-disable"
    : > "$TEST_DIR/events"
    cat > "$TEST_DIR/processes" <<EOF
90001 $GHUB_UID /Applications/lghub.app/Contents/MacOS/lghub_agent
90002 0 /Applications/lghub.app/Contents/MacOS/lghub_updater.app/Contents/MacOS/lghub_updater
90003 $GHUB_UID /Applications/logioptionsplus.app/Contents/MacOS/logioptionsplus
90004 $GHUB_UID /tmp/lghub_agent
90005 $GHUB_UID /bin/zsh /Applications/lghub.app/Contents/MacOS/lghub_agent
EOF
    touch "$(marker "$GHUB_GUI/$GHUB_AGENT" loaded)" "$(marker "$GHUB_GUI/$DYNAMIC" loaded)" "$(marker "system/$GHUB_UPDATER" loaded)"
}

# Match paths precisely; support HOME paths with spaces, exclude unrelated Logi.
is_ghub_path '/Applications/lghub.app/Contents/Frameworks/G HUB Helper.app/Contents/MacOS/G HUB Helper'
is_ghub_path "$HOME/Applications/lghub.app/Contents/MacOS/lghub"
if is_ghub_path '/Applications/lghub.app.fake/Contents/MacOS/lghub'; then exit 1; fi
if is_ghub_path '/Applications/logioptionsplus.app/Contents/MacOS/logioptionsplus'; then exit 1; fi
if is_ghub_path '/bin/zsh /Applications/lghub.app/Contents/MacOS/lghub'; then exit 1; fi
if is_gui_label application.com.logi.ghub.agent/evil; then exit 1; fi
is_gui_label "$DYNAMIC"

# The real signal function must reject a PID whose executable changed.
process_details() { printf '%s /Applications/Other.app/Contents/MacOS/Other\n' "$GHUB_UID"; }
signal_one 90001 KILL
# The real signal function must not stop another logged-in user's process.
process_details() { printf '99999 /Applications/lghub.app/Contents/MacOS/lghub_agent\n'; }
if signal_one 90001 KILL; then exit 1; fi

# Remaining tests replace signalling; no actual process receives a signal.
signal_one() {
    local pid="$1" sig="$2" target
    for target in "$GHUB_GUI/$GHUB_AGENT" "$GHUB_GUI/$DYNAMIC" "system/$GHUB_UPDATER"; do
        [ ! -e "$(marker "$target" loaded)" ] || return 1
        [ -e "$(marker "$target" disabled)" ] || return 1
    done
    echo "$sig $pid" >> "$TEST_DIR/events"
    if [ "$sig" == KILL ] || [ ! -e "$TEST_DIR/stubborn" ]; then
        /usr/bin/awk -v pid="$pid" '$1 != pid' "$TEST_DIR/processes" > "$TEST_DIR/next"
        mv "$TEST_DIR/next" "$TEST_DIR/processes"
    fi
}

reset_case
[ "$(ghub_processes | wc -l | tr -d ' ')" == 2 ]
status > "$TEST_DIR/status"
[ ! -s "$TEST_DIR/events" ]
stop_ghub no
[ -z "$(ghub_processes)" ]
if /usr/bin/grep -q '^KILL' "$TEST_DIR/events"; then exit 1; fi
/usr/bin/grep -q '90003' "$TEST_DIR/processes"

reset_case; touch "$TEST_DIR/stubborn"
if stop_ghub no; then exit 1; fi
if /usr/bin/grep -q '^KILL' "$TEST_DIR/events"; then exit 1; fi
[ -n "$(ghub_processes)" ]

reset_case; touch "$TEST_DIR/stubborn"
stop_ghub yes
/usr/bin/grep -q '^KILL 90001$' "$TEST_DIR/events"
/usr/bin/grep -q '^KILL 90002$' "$TEST_DIR/events"
[ -z "$(ghub_processes)" ]
stop_ghub yes # already disabled and empty: no extra administrator request
[ "$(/usr/bin/grep -c '^AUTH$' "$TEST_DIR/events")" == 1 ]

restore_ghub
is_loaded "system/$GHUB_UPDATER"
is_loaded "$GHUB_GUI/$GHUB_AGENT"
[ "$(disabled_state "$GHUB_GUI" "$DYNAMIC")" == default ]

reset_case; touch "$TEST_DIR/reject-auth"
if stop_ghub yes; then exit 1; fi
[ "$(cat "$TEST_DIR/events")" == AUTH ]

reset_case; touch "$TEST_DIR/reject-disable"
if stop_ghub yes; then exit 1; fi
if /usr/bin/grep -Eq '^(TERM|KILL) ' "$TEST_DIR/events"; then exit 1; fi

echo 'PASS: precise process matching, PID revalidation, other-user protection, service shutdown before signals, TERM/KILL fallback, idempotency, restore and failure handling.'
