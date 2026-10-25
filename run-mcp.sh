#!/usr/bin/env bash
# sjtu-pan MCP 启动包装 (MCP 客户端 command 指向本脚本):
#   1. 确保 WebDAV 桥容器存活 (默认 127.0.0.1:65472)
#   2. 同一应用镜像以 "mcp" 角色跑 stdio 会话容器
# 上游 mcp 地址保持 127.0.0.1:65472: 容器 network_mode=host, 直接命中宿主机回环映射
#
# 默认从 docker/config.yaml 读取 WebDAV 用户名/密码和端口，因此 MCP 客户端配置里
# 不需要再写 WEBDAV_PASSWORD。仍可用同名环境变量覆盖（适合连接远程/独立桥）。
set -u

BASE="${SJTU_PAN_BASE:-$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)}"
CONF="${SJTU_PAN_CONFIG:-$BASE/docker/config.yaml}"
export SJTU_PAN_BASE="$BASE"
export SJTU_PAN_CONFIG="$CONF"

env_get() { # 读取 .env 中的非敏感配置，不 source 文件
    [ -f "$BASE/.env" ] || return 0
    sed -n "s/^$1=//p" "$BASE/.env" | tail -1
}

conf_get() { # conf_get <file> <key> [default]
    local v
    v=$(sed -n "s/^[[:space:]]*-*[[:space:]]*$2:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$1" 2>/dev/null | head -1)
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "${3-}"
}

PROJECT="${COMPOSE_PROJECT_NAME:-$(env_get COMPOSE_PROJECT_NAME)}"
PROJECT="${PROJECT:-sjtu-pan-mcp}"
IMAGE="${TBOX_IMAGE:-$(env_get TBOX_IMAGE)}"
IMAGE="${IMAGE:-sjtu-pan/mcp-tbox:1.0.4-tbox1.0.1}"

# stdout 是 MCP JSON-RPC 协议通道: 一切诊断/状态输出强制走 stderr, 否则握手解析失败
"$BASE/tbox-webdav.sh" ensure 1>&2 || {
    echo "sjtu-pan MCP: WebDAV 桥容器启动失败, 详见: docker logs ${PROJECT}-tbox-webdav-1" >&2
    exit 1
}

# 清扫泄漏尸体: 上代 wrapper 被 SIGKILL 时 trap 失效, 会话容器失去宿主.
# 容器名内嵌 wrapper PID (${PROJECT}-session-<pid>), PID 已不存在即为孤儿.
for c in $(docker ps -a --format '{{.Names}}' | grep "^${PROJECT}-session-"); do
    [ -d "/proc/${c##*-}" ] || docker rm -f "$c" >/dev/null 2>&1 &
done

# 容器随包装进程共存亡: docker CLI 被 SIGKILL 时 sig-proxy 失效会留下孤儿 stdio 容器,
# 故用后台 run + trap 主动回收 (客户端正常 SIGTERM 生命周期两种都干净)
CNAME="${PROJECT}-session-$$"
trap 'docker kill "$CNAME" >/dev/null 2>&1 || true' EXIT INT TERM HUP

# 桥的 Basic Auth 与端口以 docker/config.yaml 为准；环境变量优先，便于接远程 WebDAV。
PORT=$(conf_get "$CONF" Port 65472)
export WEBDAV_ROOT_URL="${WEBDAV_ROOT_URL:-http://127.0.0.1:${PORT}}"
export WEBDAV_ROOT_PATH="${WEBDAV_ROOT_PATH:-/}"
export WEBDAV_AUTH_ENABLED="${WEBDAV_AUTH_ENABLED:-true}"
export WEBDAV_USERNAME="${WEBDAV_USERNAME:-$(conf_get "$CONF" UserName davuser)}"
export WEBDAV_PASSWORD="${WEBDAV_PASSWORD:-$(conf_get "$CONF" PassWord "")}"

# 非交互 bash 会把未显式重定向 stdin 的后台命令接到 /dev/null (POSIX async 规则),
# 必须 <&0 显式透传包装进程 fd0, 否则 JSON-RPC 请求永远进不了容器。
# 用 -e NAME（不带值）传递，避免密码出现在 docker run 的进程参数/ps 输出中。
docker run -i --rm \
    --name "$CNAME" \
    --network host \
    -e WEBDAV_ROOT_URL \
    -e WEBDAV_ROOT_PATH \
    -e WEBDAV_AUTH_ENABLED \
    -e WEBDAV_USERNAME \
    -e WEBDAV_PASSWORD \
    "$IMAGE" mcp <&0 &
wait $!
