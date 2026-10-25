#!/bin/bash
# On-demand G HUB diagnostics/control. No watchdog or extra background process.
set -euo pipefail

GHUB_UID=$(/usr/bin/id -u)
GHUB_GUI="gui/$GHUB_UID"
GHUB_AGENT=com.logi.ghub
GHUB_UPDATER=com.logi.ghub.updater
GHUB_AGENT_PLIST=/Library/LaunchAgents/com.logi.ghub.plist
GHUB_UPDATER_PLIST=/Library/LaunchDaemons/com.logi.ghub.updater.plist

lc() { /bin/launchctl "$@"; }
process_snapshot() { /bin/ps -axo pid=,uid=,comm=; }
process_details() { /bin/ps -p "$1" -o uid=,comm=; }
pause() { /bin/sleep "$1"; }
admin() { /usr/bin/sudo -- "$@"; }
prepare_admin() {
    echo '需要管理員權限來管理 G HUB 的系統更新服務或其 root 程序。'
    /usr/bin/sudo -v
}
is_ghub_path() {
    # Match executable paths, never command arguments or a loose "logi" search.
    case "$1" in
        /Applications/lghub.app/Contents/*|"$HOME/Applications/lghub.app/Contents/"*) return 0 ;;
        *) return 1 ;;
    esac
}
is_gui_label() {
    [[ "$1" == "$GHUB_AGENT" || "$1" =~ ^application\.com\.logi\.ghub\.[A-Za-z0-9_.-]+$ ]]
}
ghub_processes() {
    local pid owner executable snapshot
    snapshot=$(process_snapshot) || return 1
    while read -r pid owner executable; do
        [[ "$pid" =~ ^[0-9]+$ && "$owner" =~ ^[0-9]+$ ]] || continue
        if is_ghub_path "$executable"; then
            printf '%s\t%s\t%s\n' "$pid" "$owner" "$executable"
        fi
    done <<< "$snapshot"
}
gui_labels() {
    local jobs overrides candidate
    jobs=$(lc list) || return 1
    overrides=$(lc print-disabled "$GHUB_GUI") || return 1
    {
        echo "$GHUB_AGENT"
        while IFS= read -r candidate; do
            if is_gui_label "$candidate"; then echo "$candidate"; fi
        done < <(printf '%s\n%s\n' "$jobs" "$overrides" |
            /usr/bin/awk '/^[0-9-]+[[:space:]]/ {print $3} /=>/ {gsub(/"/, "", $1); print $1}')
    } | /usr/bin/sort -u
}
disabled_state() {
    local listing
    listing=$(lc print-disabled "$1") || return 1
    printf '%s\n' "$listing" | /usr/bin/awk -v key="\"$2\"" '
        $1 == key {print $3; found=1; exit} END {if (!found) print "default"}'
}
is_loaded() { lc print "$1" >/dev/null 2>&1; }
status() {
    local processes labels label disabled loaded
    processes=$(ghub_processes) || return 1
    echo 'G HUB 程序（PID / UID / 執行檔）：'
    if [ -n "$processes" ]; then printf '%s\n' "$processes"; else echo '未發現殘留程序。'; fi
    labels=$(gui_labels) || return 1
    echo 'G HUB launchd 服務（loaded=已載入；disabled=禁止自啟動）：'
    while IFS= read -r label; do
        disabled=$(disabled_state "$GHUB_GUI" "$label") || return 1
        loaded=no; if is_loaded "$GHUB_GUI/$label"; then loaded=yes; fi
        printf '%s: loaded=%s, startup=%s\n' "$GHUB_GUI/$label" "$loaded" "$disabled"
    done <<< "$labels"
    disabled=$(disabled_state system "$GHUB_UPDATER") || return 1
    loaded=no; if is_loaded "system/$GHUB_UPDATER"; then loaded=yes; fi
    printf 'system/%s: loaded=%s, startup=%s\n' "$GHUB_UPDATER" "$loaded" "$disabled"
    echo 'default 表示沒有停用覆寫，是否自啟動仍取決於安裝的服務設定。'
}
signal_one() {
    local pid="$1" signal="$2" details owner executable
    # Re-read the PID immediately before signalling; never trust a stale list.
    if ! details=$(process_details "$pid"); then return 0; fi
    read -r owner executable <<< "$details"
    if ! is_ghub_path "$executable"; then return 0; fi
    if [ "$owner" != "$GHUB_UID" ] && [ "$owner" != 0 ]; then
        echo "未停止其他使用者的 G HUB 程序 PID ${pid}（UID ${owner}）。" >&2
        return 1
    fi
    echo "傳送 $signal 給 G HUB PID ${pid}。"
    if [ "$owner" == 0 ]; then
        admin /bin/kill "-$signal" "$pid" || { ! process_details "$pid" >/dev/null 2>&1; }
    else
        /bin/kill "-$signal" "$pid" || { ! process_details "$pid" >/dev/null 2>&1; }
    fi
}
signal_remaining() {
    local signal="$1" processes pid owner executable failed=0
    processes=$(ghub_processes) || return 1
    while read -r pid owner executable; do
        [ -n "$pid" ] || continue
        if ! signal_one "$pid" "$signal"; then failed=1; fi
    done <<< "$processes"
    return "$failed"
}
wait_clear() {
    local n processes
    for ((n=0;n<25;n++)); do
        processes=$(ghub_processes) || return 1
        if [ -z "$processes" ]; then return 0; fi
        pause 0.2
    done
    return 1
}
stop_processes() {
    local force="$1"
    signal_remaining TERM || return 1
    if ! wait_clear; then
        if [ "$force" != yes ]; then
            echo '仍有殘留程序。可使用 ./ghub.sh stop --force 強制結束。' >&2
            return 1
        fi
        signal_remaining KILL || return 1
        if ! wait_clear; then echo '強制停止後仍有殘留程序。' >&2; return 1; fi
    fi
    pause 2
    local remaining
    remaining=$(ghub_processes) || return 1
    if [ -n "$remaining" ]; then
        printf '檢測到程序重新出現，停止未完成：\n%s\n' "$remaining" >&2
        return 1
    fi
}
stop_ghub() {
    local force="$1" labels processes owner pid executable disabled system_present=no need_admin=no label
    labels=$(gui_labels) || return 1
    processes=$(ghub_processes) || return 1
    disabled=$(disabled_state system "$GHUB_UPDATER") || return 1
    if [ -f "$GHUB_UPDATER_PLIST" ] || is_loaded "system/$GHUB_UPDATER"; then
        system_present=yes
        if [ "$disabled" != disabled ] || is_loaded "system/$GHUB_UPDATER"; then need_admin=yes; fi
    fi
    while read -r pid owner executable; do
        if [ "$owner" == 0 ]; then need_admin=yes; fi
    done <<< "$processes"
    # Obtain any required credentials before making changes to user services.
    if [ "$need_admin" == yes ]; then prepare_admin || return 1; fi
    if [ "$system_present" == yes ]; then
        if [ "$disabled" != disabled ]; then admin /bin/launchctl disable "system/$GHUB_UPDATER" || return 1; fi
        if is_loaded "system/$GHUB_UPDATER"; then admin /bin/launchctl bootout "system/$GHUB_UPDATER" || return 1; fi
    fi
    while IFS= read -r label; do
        lc disable "$GHUB_GUI/$label" || return 1
        if is_loaded "$GHUB_GUI/$label"; then lc bootout "$GHUB_GUI/$label" || return 1; fi
    done <<< "$labels"
    stop_processes "$force" || return 1
    # A running service can respawn a process even if it was killed successfully.
    labels=$(gui_labels) || return 1
    while IFS= read -r label; do
        if is_loaded "$GHUB_GUI/$label"; then echo "服務仍已載入：$label" >&2; return 1; fi
        disabled=$(disabled_state "$GHUB_GUI" "$label") || return 1
        if [ "$disabled" != disabled ]; then echo "服務尚未禁止自啟動：$label" >&2; return 1; fi
    done <<< "$labels"
    if is_loaded "system/$GHUB_UPDATER"; then echo '更新服務仍已載入。' >&2; return 1; fi
    if [ "$system_present" == yes ]; then
        disabled=$(disabled_state system "$GHUB_UPDATER") || return 1
        if [ "$disabled" != disabled ]; then echo '更新服務尚未禁止自啟動。' >&2; return 1; fi
    fi
    echo 'G HUB 已停止，已知自啟動服務已禁用；未發現殘留或立即重新啟動。'
}
restore_ghub() {
    local labels label
    labels=$(gui_labels) || return 1
    if [ -f "$GHUB_UPDATER_PLIST" ]; then prepare_admin || return 1; fi
    while IFS= read -r label; do lc enable "$GHUB_GUI/$label" || return 1; done <<< "$labels"
    if [ -f "$GHUB_UPDATER_PLIST" ]; then
        admin /bin/launchctl enable "system/$GHUB_UPDATER" || return 1
        if ! is_loaded "system/$GHUB_UPDATER"; then
            admin /bin/launchctl bootstrap system "$GHUB_UPDATER_PLIST" || return 1
        fi
    fi
    if [ -f "$GHUB_AGENT_PLIST" ] && ! is_loaded "$GHUB_GUI/$GHUB_AGENT"; then
        lc bootstrap "$GHUB_GUI" "$GHUB_AGENT_PLIST" || return 1
    fi
    echo '已解除 G HUB 自啟動限制並載入已安裝的服務。這是重新啟用，不是還原歷史設定快照。'
}
main() {
    if [ "$GHUB_UID" == 0 ]; then
        echo '請以目前登入的使用者執行，不要對整支腳本使用 sudo；需要時會單獨要求權限。' >&2; return 2
    fi
    case "${1:-status}" in
        status) [ "$#" -le 1 ] || return 2; status ;;
        stop)
            if [ "$#" == 1 ]; then stop_ghub no
            elif [ "$#" == 2 ] && [ "$2" == --force ]; then stop_ghub yes
            else echo '用法：./ghub.sh stop [--force]' >&2; return 2; fi ;;
        restore) [ "$#" == 1 ] || return 2; restore_ghub ;;
        -h|--help) echo '用法：./ghub.sh {status|stop [--force]|restore}' ;;
        *) echo '用法：./ghub.sh {status|stop [--force]|restore}' >&2; return 2 ;;
    esac
}
if [ "${BASH_SOURCE[0]}" == "$0" ]; then main "$@"; fi
