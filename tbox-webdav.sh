#!/usr/bin/env bash
# 交大云盘 WebDAV 桥 (TboxWebdav, Docker 版) 控制脚本
# 用法: tbox-webdav.sh {start|stop|restart|status|ensure|check-config|install}
#
# 复盘约束 (勿改, 2026-09 实测):
#   - CacheSize 必须 <= 2147483647: TboxWebdav 按 int32 反序列化, 超了静默启动失败
#   - CacheSize 必须 >= 单文件上传大小: 否则分块失败后块数据已被缓存逐出, 无法重试 -> 整文件 HTTP 500
#   - 存活检测用 /dev/tcp 探测, 不用 pgrep -f/pkill -f (模式含包名时会匹配到调用方自身)
set -u

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
COMPOSE_FILE="$BASE/docker-compose.yml"
CONF="$BASE/docker/config.yaml"
EXAMPLE="$BASE/config.yaml.example"
PROBE_HOST=127.0.0.1

die() { echo "sjtu-webdav: $*" >&2; exit 1; }
log() { echo "sjtu-webdav: $*"; }

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

conf_get() { # conf_get <file> <key> [default]
    local v
    v=$(sed -n "s/^[[:space:]]*$2:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$1" 2>/dev/null | head -1)
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "${3-}"
}

PORT=$(conf_get "$CONF" Port 65472)

# 探活必须走 HTTP: 宿主机 docker-proxy 会先完成 TCP 握手, 纯 TCP 探测在容器内应用崩溃时误报存活.
# 任意 HTTP 状态码 (含 401) 都说明应用真的在响应; 000 = 不通.
alive() {
    if command -v curl >/dev/null 2>&1; then
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$PROBE_HOST:$PORT/" 2>/dev/null)
        [ "$code" != "000" ] && [ -n "$code" ] && return 0
        return 1
    fi
    ( exec 3<>"/dev/tcp/$PROBE_HOST/$PORT" ) 2>/dev/null && { exec 3>&-; return 0; } || return 1
}

wait_up() {
    local t=0
    while [ "$t" -lt "$1" ]; do alive && return 0; sleep 1; t=$((t+1)); done
    return 1
}

docker_ready() {
    command -v docker >/dev/null 2>&1 || die "docker 未安装"
    docker info >/dev/null 2>&1 || die "docker daemon 不可用或未授权 (groups?) 且 sudo usermod -aG docker \$USER 后重新登录"
}

check_config() {
    docker_ready
    [ -f "$CONF" ] || die "缺少 $CONF, 先执行: $0 install"
    local cache port
    cache=$(conf_get "$CONF" CacheSize "")
    [[ "$cache" =~ ^[0-9]+$ ]] || die "CacheSize 缺失或非数字: '$cache'"
    [ "$cache" -le 2147483647 ] || die "CacheSize=$cache 超过 int32 上限 2147483647, 会 'Exception during deserialization' 启动失败"
    [ "$cache" -ge 20971520 ] || log "警告: CacheSize=$cache 过小, 大文件上传失败后无法重试, 建议 2147483647"
    port=$(conf_get "$CONF" Port "")
    [[ "$port" =~ ^[0-9]+$ ]] || die "Port 配置非法: '$port'"
    [ "$(conf_get "$CONF" Host "")" = "0.0.0.0" ] || log "提示: 容器内 Host 应为 0.0.0.0 (当前 '$(conf_get "$CONF" Host "")'), 否则宿主机映射不到"
    log "config OK ($CONF: port=$port, CacheSize=$cache)"
}

do_start() {
    check_config
    compose up -d tbox-webdav
    wait_up 30 || die "启动超时: $PROBE_HOST:$PORT 未就绪, 看: docker logs sjtu-pan-mcp-tbox-webdav-1"
    log "已启动 ($PROBE_HOST:$PORT)"
}

do_stop() {
    docker_ready
    compose stop tbox-webdav
    log "已停止"
}

do_status() {
    if alive; then
        log "RUNNING  $PROBE_HOST:$PORT"
        docker ps --filter "name=sjtu-pan-mcp-tbox-webdav" --format '  container: {{.Status}}'
        return 0
    fi
    log "DOWN     $PROBE_HOST:$PORT"
    docker ps -a --filter "name=sjtu-pan-mcp-tbox-webdav" --format '  container: {{.Status}}' 2>/dev/null
    return 3
}

do_install() {
    if [ ! -f "$BASE/.env" ]; then
        printf 'TBOX_UID=%s\nTBOX_GID=%s\n' "$(id -u)" "$(id -g)" > "$BASE/.env"
        log "已生成 .env (uid=$(id -u) gid=$(id -g))"
    fi
    [ -f "$CONF" ] && { log "$CONF 已存在, 不覆盖"; return 0; }
    mkdir -p "$BASE/docker"
    cp "$EXAMPLE" "$CONF"
    chmod 600 "$CONF"
    log "已生成 $CONF — 编辑填入 PassWord / UserToken 后再 start"
}

case "${1:-}" in
    check-config) check_config ;;
    start)        do_start ;;
    stop)         do_stop ;;
    restart)      do_stop; do_start ;;
    status)       do_status ;;
    ensure)       docker_ready && compose up -d tbox-webdav 2>/dev/null; wait_up 30 || die "确保运行失败" ;;
    install)      do_install ;;
    *)            die "用法: $0 {start|stop|restart|status|ensure|check-config|install}" ;;
esac
