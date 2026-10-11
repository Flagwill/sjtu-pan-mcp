#!/usr/bin/env bash
# 交大云盘 WebDAV 桥 (TboxWebdav, Docker 版) 控制脚本
# 用法: tbox-webdav.sh {start|stop|restart|status|ensure|check-config|doctor|install}
#
# 复盘约束 (勿改, 2026-09 实测):
#   - CacheSize 必须 <= 2147483647: TboxWebdav 按 int32 反序列化, 超了静默启动失败
#   - CacheSize 必须 >= 单文件上传大小: 否则大文件分块上传失败后无法重试 (整文件 HTTP 500)
#   - 存活检测用 /dev/tcp 探测, 不用 pgrep -f/pkill -f (模式含包名时会匹配到调用方自身)
#
# 就绪判定 (勿改, 2026-10-11 实测):
#   - alive() 只说明"应用在监听"(无凭证 401 也算活着), 说明不了云盘可达: 陈旧容器 DNS 失效时
#     alive=true 但 PROPFIND 全 404, 故 ready() 必须带凭证真打一次 PROPFIND 才算健康
#   - ready() 失败要分两种: 容器内 DNS 失效 -> restart 自愈; DNS 正常 -> 上游/凭证问题, 只告警不重启
set -u

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
COMPOSE_FILE="$BASE/docker-compose.yml"
CONF="$BASE/docker/config.yaml"
EXAMPLE="$BASE/config.yaml.example"
PROBE_HOST=127.0.0.1
CONTAINER="${TBOX_CONTAINER:-sjtu-pan-mcp-tbox-webdav-1}"   # 可被 TBOX_CONTAINER 覆盖(测试用)

die() { echo "sjtu-webdav: $*" >&2; exit 1; }
log() { echo "sjtu-webdav: $*" >&2; }   # 必须 stderr: 本脚本输出可经 run-mcp.sh 汇入 MCP stdio 协议管道

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

conf_get() { # conf_get <file> <key> [default]
    local v
    # 前缀可带 "- " (YAML 列表项): Users: 下的 UserName 就是 "- UserName: xxx", 不兼容就取不到
    v=$(sed -n "s/^[[:space:]]*-*[[:space:]]*$2:[[:space:]]*\([^[:space:]#]*\).*/\1/p" "$1" 2>/dev/null | head -1)
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

# ---- 就绪判定 (alive 只证明进程在听端口, ready 才证明云盘真能打通) ----
dav_cred() { printf '%s:%s' "${WEBDAV_USERNAME:-$(conf_get "$CONF" UserName davuser)}" \
                             "${WEBDAV_PASSWORD:-$(conf_get "$CONF" PassWord "")}"; }

dav_code() { # 带凭证 PROPFIND 根目录, 输出 HTTP 状态码; 207=健康, 401=凭证, 000=不通
    local code
    [ -n "${WEBDAV_PASSWORD:-$(conf_get "$CONF" PassWord "")}" ] || { echo 000; return 1; }
    command -v curl >/dev/null 2>&1 || { echo 000; return 1; }
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -u "$(dav_cred)" \
           -X PROPFIND -H 'Depth: 0' "http://$PROBE_HOST:$PORT/" 2>/dev/null)
    echo "${code:-000}"
}

ready() { [ "$(dav_code)" = "207" ]; }

wait_ready() {
    local t=0
    while [ "$t" -lt "$1" ]; do ready && return 0; sleep 1; t=$((t+1)); done
    return 1
}

# 容器内出网自检: 镜像没有 curl, 但有 node; 这是"陈旧容器 DNS 失效"与"上游真挂"的区分依据
container_dns_ok() {
    docker exec "$CONTAINER" node -e 'require("dns").resolve4("pan.sjtu.edu.cn",(e)=>process.exit(e?1:0))' >/dev/null 2>&1
}

# 自愈: 容器在听端口但云盘 API 不通时, 陈旧容器(DNS 失效)重启一次即可恢复
self_heal() {
    ready && return 0
    if container_dns_ok; then
        log "警告: 云盘 API 不通, 但容器内 DNS 正常 (PROPFIND=$(dav_code)) — 不重启, 疑似上游/UserToken 问题, 执行 '$0 doctor'"
        return 1
    fi
    log "检出陈旧容器: 容器内 DNS 失效 (PROPFIND=$(dav_code)), 自动 restart 自愈 ..."
    compose restart tbox-webdav >&2 || true
    wait_up 30 || { log "restart 后桥未监听: docker logs $CONTAINER"; return 1; }
    wait_ready 20 || { log "restart 后仍未就绪 (PROPFIND=$(dav_code)), 执行 '$0 doctor'"; return 1; }
    log "自愈完成: 云盘 API 已恢复 (PROPFIND 207)"
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
    [ "$(conf_get "$CONF" Host "")" = "0.0.0.0" ] || die "容器内 Host 必须为 0.0.0.0 (当前 '$(conf_get "$CONF" Host "")')，否则宿主机映射不到"
    log "config OK ($CONF: port=$port, CacheSize=$cache)"
}

ensure_env() {
    # compose 的 user: 缺 .env 时回退 uid 2000 -> 读不了 0600 挂载配置且 exit 0 不触发重启,
    # 故 start/ensure 前自动生成, 保证新机器零手工步骤
    [ -f "$BASE/.env" ] || printf 'TBOX_UID=%s\nTBOX_GID=%s\n' "$(id -u)" "$(id -g)" > "$BASE/.env"
}

do_start() {
    ensure_env
    check_config
    compose up -d tbox-webdav
    wait_up 30 || die "启动超时: $PROBE_HOST:$PORT 未就绪, 看: docker logs $CONTAINER"
    # 每个 MCP 会话都会经 run-mcp.sh 走到这里: 陈旧容器在这一步自动修掉, 无需人工 restart
    if ! ready; then
        self_heal || log "警告: 桥未就绪, MCP 工具此刻会返回 404; 执行 '$0 doctor' 诊断"
    fi
    log "已启动 ($PROBE_HOST:$PORT)"
}

do_stop() {
    docker_ready
    compose stop tbox-webdav
    log "已停止"
}

do_status() {
    if ! alive; then
        log "DOWN     $PROBE_HOST:$PORT"
        docker ps -a --filter "name=sjtu-pan-mcp-tbox-webdav" --format '  container: {{.Status}}' 2>/dev/null
        return 3
    fi
    docker ps --filter "name=sjtu-pan-mcp-tbox-webdav" --format '  container: {{.Status}}'
    if ready; then
        log "READY    $PROBE_HOST:$PORT (PROPFIND 207: 云盘可达, MCP 工具可用)"
        return 0
    fi
    # 关键: 以前这里只报 RUNNING, "监听正常但云盘 404" 会被当成健康
    log "DEGRADED $PROBE_HOST:$PORT (监听正常但云盘 API 不通, PROPFIND=$(dav_code): MCP 工具此刻全 404)"
    if container_dns_ok; then
        log "  容器内 DNS 正常 → 上游/凭证问题, 执行 '$0 doctor'"
    else
        log "  容器内 DNS 失效 → 陈旧容器, 执行 '$0 restart' (run-mcp.sh 也会自动修)"
    fi
    return 3
}

do_doctor() {
    docker_ready
    [ -f "$CONF" ] || die "缺少 $CONF, 先执行: $0 install"
    log "--- 容器 ---"
    docker ps -a --filter "name=sjtu-pan-mcp-tbox-webdav" --format '  {{.Names}}: {{.Status}}' 2>/dev/null
    log "--- 探活 ---"
    alive && log "  alive: 是" || log "  alive: 否"
    log "  PROPFIND(带凭证): $(dav_code)   [207=云盘可达, 401=凭证, 000=不通]"
    log "--- 容器网络 ---"
    local rc line
    rc=$(docker exec "$CONTAINER" sh -c 'grep -E "^(nameserver|# NO EXTERNAL)" /etc/resolv.conf' 2>/dev/null)
    if [ -n "$rc" ]; then while IFS= read -r line; do log "  $line"; done <<< "$rc"
    else log "  (取不到 resolv.conf: 容器未运行?)"; fi
    if container_dns_ok; then log "  容器内 DNS (pan.sjtu.edu.cn): 正常"
    else log "  容器内 DNS (pan.sjtu.edu.cn): 失败 ← 陈旧容器特征"; fi
    log "--- 宿主机侧 ---"
    local hn
    hn=$(getent hosts pan.sjtu.edu.cn 2>/dev/null | head -1)
    log "  宿主机解析 pan.sjtu.edu.cn: ${hn:-失败}"
    log "--- 结论 ---"
    if ready; then log "  一切正常"
    elif ! alive; then log "  桥未运行: $0 start"
    elif ! container_dns_ok; then log "  陈旧容器 DNS 失效: $0 restart"
    else log "  DNS 正常但云盘 API 不通: 查 UserToken 是否过期 — docker logs $CONTAINER"
    fi
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
    ensure)       ensure_env; do_start ;;
    doctor)       do_doctor ;;
    install)      do_install ;;
    *)            die "用法: $0 {start|stop|restart|status|ensure|check-config|doctor|install}" ;;
esac
