# MCP 客户端配置

先完成：

```bash
cd /absolute/path/sjtu-pan-mcp
./tbox-webdav.sh install
# 编辑 docker/config.yaml，填入 PassWord 和 UserToken
./tbox-webdav.sh start
./tbox-webdav.sh client-config
```

`run-mcp.sh` 会在每次会话启动时确保桥容器可用，并从 `docker/config.yaml`
读取 WebDAV 用户名、密码和端口。因此客户端配置里**不需要再写密码**。

把 `/absolute/path/sjtu-pan-mcp` 换成实际路径。若客户端找不到 `docker`，
把 `command` 改成 `which docker` 的绝对路径；`run-mcp.sh` 本身也需要可执行权限。

## Claude Desktop / Cursor

```json
{
  "mcpServers": {
    "sjtu-pan": {
      "command": "/absolute/path/sjtu-pan-mcp/run-mcp.sh",
      "args": []
    }
  }
}
```

## VS Code

项目内 `.vscode/mcp.json`：

```json
{
  "servers": {
    "sjtu-pan": {
      "type": "stdio",
      "command": "/absolute/path/sjtu-pan-mcp/run-mcp.sh",
      "args": []
    }
  }
}
```

## Codex

`~/.codex/config.toml`：

```toml
[mcp_servers.sjtu-pan]
command = "/absolute/path/sjtu-pan-mcp/run-mcp.sh"
args = []
```

## opencode

`opencode.json`：

```json
{
  "mcp": {
    "sjtu-pan": {
      "type": "local",
      "command": ["/absolute/path/sjtu-pan-mcp/run-mcp.sh"],
      "enabled": true
    }
  }
}
```

## 连接远程或独立 WebDAV 桥

默认连接本机 `http://127.0.0.1:65472`。如果桥在另一台机器或另一个端口，
在客户端环境里设置：

```json
{
  "mcpServers": {
    "sjtu-pan": {
      "command": "/absolute/path/sjtu-pan-mcp/run-mcp.sh",
      "env": {
        "WEBDAV_ROOT_URL": "http://192.0.2.10:65472",
        "WEBDAV_USERNAME": "davuser",
        "WEBDAV_PASSWORD": "..."
      }
    }
  }
}
```

环境变量优先级高于 `docker/config.yaml`。远程访问时请自行加 TLS/VPN，
不要把带 Basic Auth 的 WebDAV 直接暴露到公网。

## 常见问题

- **客户端提示 server unavailable**：先手动运行 `./run-mcp.sh` 看 stderr；
  它会把所有诊断写到 stderr，stdout 只留给 MCP 协议。
- **桥未就绪**：运行 `./tbox-webdav.sh status` 或 `doctor`。`READY` 表示
  WebDAV 探活返回 207；`DEGRADED` 表示端口在听但云盘不可达。
- **密码/Token 过期**：编辑 `docker/config.yaml` 后运行 `./tbox-webdav.sh restart`。
- **多实例**：在各自的 `.env` 里设置不同的 `COMPOSE_PROJECT_NAME`，并给桥分配不同端口。
