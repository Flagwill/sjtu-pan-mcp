#!/usr/bin/env bash
# sjtu-pan MCP 启动包装 (opencode.json mcp.sjtu-pan.command 指向本脚本):
#   1. 确保 WebDAV 桥容器存活 (127.0.0.1:65472)
#   2. 以 stdio 容器方式运行 webdav-mcp-server
# 上游 mcp 地址保持 127.0.0.1:65472: 容器 network_mode=host, 直接命中宿主机回环映射
set -u

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

"$BASE/tbox-webdav.sh" ensure || {
    echo "sjtu-pan MCP: WebDAV 桥容器启动失败, 详见: docker logs sjtu-pan-mcp-tbox-webdav-1" >&2
    exit 1
}

# 容器随包装进程共存亡: docker CLI 被 SIGKILL 时 sig-proxy 失效会留下孤儿 stdio 容器,
# 故用后台 run + trap 主动回收 (opencode 正常 SIGTERM 生命周期两种都干净)
CNAME="sjtu-pan-mcp-session-$$"
trap 'docker kill "$CNAME" >/dev/null 2>&1 || true' EXIT INT TERM HUP

docker run -i --rm \
    --name "$CNAME" \
    --network host \
    -e WEBDAV_ROOT_URL="${WEBDAV_ROOT_URL:-http://127.0.0.1:65472}" \
    -e WEBDAV_ROOT_PATH="${WEBDAV_ROOT_PATH:-/}" \
    -e WEBDAV_AUTH_ENABLED="${WEBDAV_AUTH_ENABLED:-true}" \
    -e WEBDAV_USERNAME="${WEBDAV_USERNAME:-}" \
    -e WEBDAV_PASSWORD="${WEBDAV_PASSWORD:-}" \
    sjtu-pan/mcp:1.0.4 &
wait $!
