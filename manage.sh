#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
LABEL=local.keyboard-battery
SERVICE="gui/$(id -u)/$LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
BIN="$ROOT/bin/keyboard-battery"

build() {
    mkdir -p "$ROOT/bin" "$ROOT/runtime" "$ROOT/config"
    /usr/bin/clang -std=c11 -Wall -Wextra -O2 "$ROOT/src/keyboard-battery.c" \
        -framework IOKit -framework CoreFoundation -o "$BIN.new"
    mv "$BIN.new" "$BIN"
}
stop_service() {
    if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
        /bin/launchctl bootout "$SERVICE"
        for ((n=0;n<50;n++)); do
            if ! /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then return; fi
            sleep 0.1
        done
        echo 'Service is still stopping; retry shortly.' >&2
        return 1
    fi
}
check_owned_plist() {
    if [ -e "$PLIST" ]; then
        local existing
        existing=$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - "$PLIST")
        if [ "$existing" != "$BIN" ]; then
            echo "Refusing to overwrite a service owned by another project: $PLIST" >&2
            exit 1
        fi
    fi
}
install_service() {
    check_owned_plist
    build
    local generated="$ROOT/config/$LABEL.plist"
    /usr/bin/plutil -create xml1 "$generated"
    /usr/bin/plutil -insert Label -string "$LABEL" "$generated"
    /usr/bin/plutil -insert ProgramArguments -array "$generated"
    /usr/bin/plutil -insert ProgramArguments.0 -string "$BIN" "$generated"
    /usr/bin/plutil -insert ProgramArguments.1 -string '--run' "$generated"
    /usr/bin/plutil -insert ProgramArguments.2 -string "$ROOT/runtime/bridge.lock" "$generated"
    /usr/bin/plutil -insert WorkingDirectory -string "$ROOT" "$generated"
    /usr/bin/plutil -insert RunAtLoad -bool YES "$generated"
    /usr/bin/plutil -insert KeepAlive -bool YES "$generated"
    /usr/bin/plutil -insert ThrottleInterval -integer 15 "$generated"
    /usr/bin/plutil -insert ExitTimeOut -integer 10 "$generated"
    /usr/bin/plutil -insert ProcessType -string Background "$generated"
    /usr/bin/plutil -insert StandardOutPath -string "$ROOT/runtime/stdout.log" "$generated"
    /usr/bin/plutil -insert StandardErrorPath -string "$ROOT/runtime/bridge.log" "$generated"
    /usr/bin/plutil -lint "$generated"
    stop_service
    mkdir -p "$HOME/Library/LaunchAgents"
    /usr/bin/install -m 644 "$generated" "$PLIST"
    /bin/launchctl enable "$SERVICE"
    /bin/launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo 'Installed and started. It will start automatically at login.'
}
case "${1:-status}" in
    build) build ;;
    read) [ -x "$BIN" ] || build; "$BIN" --once ;;
    activity) [ -x "$BIN" ] || build; "$BIN" --activity ;;
    test)
        mkdir -p "$ROOT/bin"
        /usr/bin/clang -std=c11 -Wall -Wextra -Werror -O2 "$ROOT/tests/idle-test.c" \
            -framework IOKit -framework CoreFoundation -o "$ROOT/bin/idle-test"
        "$ROOT/bin/idle-test"
        /bin/bash "$ROOT/tests/ghub-test.sh" ;;
    install) install_service ;;
    stop)
        check_owned_plist
        /bin/launchctl disable "$SERVICE"
        stop_service
        echo 'Stopped and automatic startup disabled. Use start to resume.' ;;
    start)
        check_owned_plist
        if [ ! -f "$PLIST" ]; then install_service; else
            /bin/launchctl enable "$SERVICE"
            if ! /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
                /bin/launchctl bootstrap "gui/$(id -u)" "$PLIST"
            fi
            echo 'Started; automatic startup enabled.'
        fi ;;
    status)
        if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
            /bin/launchctl print "$SERVICE" | /usr/bin/awk '/state =|pid =|last exit code =/ {print}'
        else echo 'Service is not loaded.'; fi
        /bin/launchctl print-disabled "gui/$(id -u)" | /usr/bin/awk '/local.keyboard-battery/ {print}'
        /usr/bin/pmset -g accps ;;
    logs) tail -n 30 "$ROOT/runtime/bridge.log" ;;
    uninstall)
        check_owned_plist
        /bin/launchctl disable "$SERVICE"
        stop_service
        if [ -f "$PLIST" ]; then rm "$PLIST"; fi
        /bin/launchctl enable "$SERVICE"
        echo 'Autostart removed. Source, executable and logs are retained in this project.' ;;
    *) echo "Usage: $0 {build|read|activity|test|install|start|stop|status|logs|uninstall}" >&2; exit 2 ;;
esac
