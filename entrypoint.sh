#!/bin/sh
# 单镜像双角色: tbox = WebDAV 桥(常驻), mcp = stdio MCP server(会话级)
set -eu
case "${1:-tbox}" in
    tbox) exec /opt/tbox/TboxWebdav.Server.AspNetCore -c /app/config.yaml ;;
    mcp)  exec webdav-mcp-server ;;
    *)    exec "$@" ;;
esac
