#!/usr/bin/env bash
# sjtu-pan MCP 启动包装 (opencode.json mcp.sjtu-pan.command 指向本脚本):
#   1. 确保 WebDAV 桥容器存活 (127.0.0.1:65472)
#   2. 同一应用镜像以 "mcp" 角色跑 stdio 会话容器
# 上游 mcp 地址保持 127.0.0.1:65472: 容器 network_mode=host, 直接命中宿主机回环映射
set -u

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# stdout 是 MCP JSON-RPC 协议通道: 一切诊断/状态输出强制走 stderr, 否则握手解析失败
"$BASE/tbox-webdav.sh" ensure 1>&2 || {
    echo "sjtu-pan MCP: WebDAV 桥容器启动失败, 详见: docker logs sjtu-pan-mcp-tbox-webdav-1" >&2
    exit 1
}

# 清扫泄漏尸体: 上代 wrapper 被 SIGKILL 时 trap 失效, 会话容器失去宿主.
# 容器名内嵌 wrapper PID (sjtu-pan-mcp-session-<pid>), PID 已不存在即为孤儿.
for c in $(docker ps -a --format '{{.Names}}' | grep '^sjtu-pan-mcp-session-'); do
    [ -d "/proc/${c##*-}" ] || docker rm -f "$c" >/dev/null 2>&1 &
done


# 容器随包装进程共存亡: docker CLI 被 SIGKILL 时 sig-proxy 失效会留下孤儿 stdio 容器,
# 故用后台 run + trap 主动回收 (opencode 正常 SIGTERM 生命周期两种都干净)
CNAME="sjtu-pan-mcp-session-$$"
trap 'docker kill "$CNAME" >/dev/null 2>&1 || true' EXIT INT TERM HUP

# 非交互 bash 会把未显式重定向 stdin 的后台命令接到 /dev/null (POSIX async 规则),
# 必须 <&0 显式透传包装进程 fd0, 否则 JSON-RPC 请求永远进不了容器
docker run -i --rm \
    --name "$CNAME" \
    --network host \
    -e WEBDAV_ROOT_URL="${WEBDAV_ROOT_URL:-http://127.0.0.1:65472}" \
    -e WEBDAV_ROOT_PATH="${WEBDAV_ROOT_PATH:-/}" \
    -e WEBDAV_AUTH_ENABLED="${WEBDAV_AUTH_ENABLED:-true}" \
    -e WEBDAV_USERNAME="${WEBDAV_USERNAME:-}" \
    -e WEBDAV_PASSWORD="${WEBDAV_PASSWORD:-}" \
    sjtu-pan/mcp-tbox:1.0.4-tbox1.0.1 mcp <&0 &
wait $!
