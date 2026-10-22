#!/bin/bash
# Contract: callers own the child PID and install EXIT/TERM traps.
daemon_wait_ready() {
    local pid="$1" seconds="${2:-30}" deadline
    deadline=$((SECONDS + seconds))
    while (( SECONDS < deadline )); do
        kill -0 "$pid" 2>/dev/null || { echo '错误: strongSwan 在就绪前退出' >&2; return 1; }
        if timeout 1 swanctl --stats >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "错误: 等待 strongSwan VICI 就绪超时 (${seconds}s)" >&2
    return 1
}

daemon_stop() {
    local pid="$1" seconds="${2:-8}" deadline
    [[ -n "$pid" ]] || return 0
    kill -TERM "$pid" 2>/dev/null || true
    deadline=$((SECONDS + seconds))
    while kill -0 "$pid" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.2; done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    wait "$pid" 2>/dev/null || true
}
