#!/bin/sh

set -eu

# admin 变体由管理服务接管。
if [ -f /app/.admin-mode ]; then
    echo "[admin] 检测到 admin 变体，启动 DSH 管理服务 ..."
    exec node /app/manager/index.js
fi

DSH_PORT="${DSH_PORT:-3079}"
PROXY_PORT="${PROXY_PORT:-3080}"
DSH_LOG_FILE="${DSH_LOG_FILE:-/app/.dsh-web.log}"

DSH_PID=""
TAIL_PID=""
PROXY_PID=""

cleanup() {
    exit_code=$?

    trap - EXIT INT TERM HUP

    echo "[entrypoint] 正在停止服务 ..."

    if [ -n "$PROXY_PID" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
        kill "$PROXY_PID" 2>/dev/null || true
    fi

    if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
        kill "$DSH_PID" 2>/dev/null || true
    fi

    if [ -n "$TAIL_PID" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
        kill "$TAIL_PID" 2>/dev/null || true
    fi

    if [ -n "$PROXY_PID" ]; then
        wait "$PROXY_PID" 2>/dev/null || true
    fi

    if [ -n "$DSH_PID" ]; then
        wait "$DSH_PID" 2>/dev/null || true
    fi

    if [ -n "$TAIL_PID" ]; then
        wait "$TAIL_PID" 2>/dev/null || true
    fi

    echo "[entrypoint] 服务已停止"
    exit "$exit_code"
}

handle_signal() {
    echo "[entrypoint] 收到退出信号"
    exit 0
}

trap cleanup EXIT
trap handle_signal INT TERM HUP

if [ "$DSH_PORT" = "$PROXY_PORT" ]; then
    echo "[entrypoint] 错误：DSH_PORT 和 PROXY_PORT 不能相同" >&2
    exit 1
fi

if ! command -v dsh >/dev/null 2>&1; then
    echo "[entrypoint] 错误：未找到 dsh 命令" >&2
    exit 1
fi

if [ ! -d /app/proxy ]; then
    echo "[entrypoint] 错误：未找到 /app/proxy" >&2
    exit 1
fi

# 必须先创建日志文件，避免 tail 因文件不存在而退出。
mkdir -p "$(dirname "$DSH_LOG_FILE")"
: > "$DSH_LOG_FILE"

echo "[dsh] 启动 DSH (dsh web --port $DSH_PORT) ..."

dsh web --port "$DSH_PORT" >"$DSH_LOG_FILE" 2>&1 &
DSH_PID=$!

echo "[dsh] DSH 进程 PID: $DSH_PID"

# -F 会在日志文件被删除或重新创建时继续等待。
tail -n +1 -F "$DSH_LOG_FILE" &
TAIL_PID=$!

echo "[dsh] 等待 DSH 就绪 (127.0.0.1:$DSH_PORT) ..."

ready=0
i=0

while [ "$i" -lt 120 ]; do
    if ! kill -0 "$DSH_PID" 2>/dev/null; then
        echo "[dsh] 错误：DSH 进程启动后退出" >&2
        wait "$DSH_PID" 2>/dev/null || true
        exit 1
    fi

    if node -e \
        "fetch('http://127.0.0.1:${DSH_PORT}/').then(() => process.exit(0)).catch(() => process.exit(1))" \
        >/dev/null 2>&1; then
        ready=1
        break
    fi

    i=$((i + 1))
    sleep 1
done

if [ "$ready" != "1" ]; then
    echo "[dsh] 错误：DSH 在 120 秒内未就绪" >&2
    echo "[dsh] 最后 100 行日志：" >&2
    tail -n 100 "$DSH_LOG_FILE" >&2 || true
    exit 1
fi

echo "[dsh] DSH 已就绪（PID $DSH_PID）"
echo "[proxy] 启动代理：0.0.0.0:$PROXY_PORT -> 127.0.0.1:$DSH_PORT"

cd /app/proxy
node index.js &
PROXY_PID=$!

echo "[proxy] 代理进程 PID: $PROXY_PID"

# 代理退出时容器退出，由 cleanup 同时停止 DSH。
set +e
wait "$PROXY_PID"
proxy_exit_code=$?
set -e

PROXY_PID=""

if [ "$proxy_exit_code" -ne 0 ]; then
    echo "[proxy] 错误：代理进程退出，退出码 $proxy_exit_code" >&2
else
    echo "[proxy] 代理进程已退出"
fi

exit "$proxy_exit_code"
