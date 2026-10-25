#!/usr/bin/env bash
# 无 Docker 的 CLI 回归：配置脱敏、客户端 JSON、run-mcp.sh 的凭据传递方式。
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$TMP/docker" "$TMP/bin" "$TMP/base"
cat > "$TMP/config.yaml" <<'YAML'
Host: 0.0.0.0
Port: 65472
CacheSize: 2147483647
AuthMode: Custom
AccessMode: Full
Users:
  - UserName: testuser
    PassWord: test-password-123
    UserToken: test-token-456
    AccessMode: Full
YAML
chmod 600 "$TMP/config.yaml"

echo '--- version'
out=$("$ROOT/tbox-webdav.sh" version)
[[ "$out" == sjtu-pan-mcp* ]] || fail "version: $out"

echo '--- ignore rules protect credentials'
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$ROOT" check-ignore -q docker/config.yaml.bak.test || fail "config backup is not ignored"
    if git -C "$ROOT" check-ignore -q .env.example; then fail ".env.example must stay tracked"; fi
fi

echo '--- config redacts secrets'
out=$(SJTU_PAN_CONFIG="$TMP/config.yaml" "$ROOT/tbox-webdav.sh" config)
grep -q 'password: <set>' <<<"$out" || fail "password not reported as set"
grep -q 'user_token: <set>' <<<"$out" || fail "token not reported as set"
grep -q 'user: testuser' <<<"$out" || fail "user missing"
if grep -q 'test-password-123' <<<"$out"; then fail "password leaked"; fi
if grep -q 'test-token-456' <<<"$out"; then fail "token leaked"; fi

echo '--- client-config is valid JSON'
out=$(SJTU_PAN_BASE="$ROOT" "$ROOT/tbox-webdav.sh" client-config)
python3 -m json.tool <<<"$out" >/dev/null || fail "client-config is not JSON"
grep -q 'run-mcp.sh' <<<"$out" || fail "client-config lacks run-mcp.sh"

echo '--- run-mcp.sh reads config and does not put the password in argv'
cp "$ROOT/run-mcp.sh" "$TMP/base/run-mcp.sh"
cat > "$TMP/base/tbox-webdav.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/base/tbox-webdav.sh" "$TMP/base/run-mcp.sh"

cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "run" ]; then
    printf 'ARGS %s\n' "$*" >> "$DOCKER_LOG"
    printf 'ENV WEBDAV_USERNAME=%s\n' "${WEBDAV_USERNAME:-}" >> "$DOCKER_LOG"
    printf 'ENV WEBDAV_PASSWORD=%s\n' "${WEBDAV_PASSWORD:-}" >> "$DOCKER_LOG"
    printf 'ENV WEBDAV_ROOT_URL=%s\n' "${WEBDAV_ROOT_URL:-}" >> "$DOCKER_LOG"
fi
exit 0
SH
chmod +x "$TMP/bin/docker"

DOCKER_LOG="$TMP/docker.log"
export DOCKER_LOG
export SJTU_PAN_CONFIG="$TMP/config.yaml"
export PATH="$TMP/bin:$PATH"
export COMPOSE_PROJECT_NAME=testproj
export TBOX_IMAGE=example.invalid/mcp-tbox:test

timeout 10 bash "$TMP/base/run-mcp.sh" 2>"$TMP/run.err" || {
    cat "$TMP/run.err" >&2
    fail "run-mcp.sh failed"
}

grep -q '^ARGS .*--name testproj-session-' "$DOCKER_LOG" || fail "project name not used"
grep -q '^ARGS .*example.invalid/mcp-tbox:test mcp' "$DOCKER_LOG" || fail "image not used"
grep -q '^ARGS .* -e WEBDAV_PASSWORD' "$DOCKER_LOG" || fail "-e WEBDAV_PASSWORD missing"
grep -q '^ENV WEBDAV_USERNAME=testuser' "$DOCKER_LOG" || fail "username not read from config"
grep -q '^ENV WEBDAV_PASSWORD=test-password-123' "$DOCKER_LOG" || fail "password not read from config"
grep -q '^ENV WEBDAV_ROOT_URL=http://127.0.0.1:65472' "$DOCKER_LOG" || fail "port not read from config"
if grep '^ARGS' "$DOCKER_LOG" | grep -q 'test-password-123'; then
    fail "password leaked into docker argv"
fi

echo 'all CLI tests passed'
