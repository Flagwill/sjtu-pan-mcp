# sjtu-pan-mcp

交大云盘 (cloud.sjtu.edu.cn) 的 MCP 化部署：把云盘映射为 WebDAV，再以 `webdav-mcp-server`
(stdio) 提供给 opencode / Claude 等 MCP 客户端。全链路 Docker 化，密钥不进仓库。

```
MCP 客户端 (opencode)
  └─ run-mcp.sh ── docker run -i (stdio) ──> sjtu-pan/mcp (node:22-alpine, webdav-mcp-server)
                          │ HTTP (host network)
                          ▼
              sjtu-pan/tbox-webdav (:127.0.0.1:65472 → 容器 :65472)
                TboxWebdav 桥, 自包含 .NET 8 于 native-deps:8.0
                          │ HTTPS
                          ▼
                   交大云盘 Tbox API
```

## 部署

```bash
cp config.yaml.example docker/config.yaml   # 或 ./tbox-webdav.sh install
# 编辑 docker/config.yaml: 填入 WebDAV 密码与云盘 UserToken (文件已 gitignore)
./tbox-webdav.sh start                       # 首次会触发镜像构建
./tbox-webdav.sh status
```

MCP 客户端配置 (opencode.json)：

```json
"mcp": {
  "sjtu-pan": {
    "type": "local",
    "command": ["<绝对路径>/run-mcp.sh"],
    "environment": {
      "WEBDAV_ROOT_URL": "http://127.0.0.1:65472",
      "WEBDAV_USERNAME": "...", "WEBDAV_PASSWORD": "***"
    }
  }
}
```

## 运维

| 命令 | 作用 |
|---|---|
| `tbox-webdav.sh start/stop/restart/status` | 桥容器生命周期 |
| `tbox-webdav.sh ensure` | 幂等拉起 (run-mcp.sh 内部使用) |
| `tbox-webdav.sh check-config` | 配置预检 (int32 上限 / 最小值 / 端口) |
| `docker logs -f sjtu-pan-mcp-tbox-webdav-1` | 桥日志 |

- 自启与守护：桥容器 `restart: unless-stopped`，随 dockerd 开机拉起、崩溃自动重启，无需 systemd。
- MCP 容器不常驻：每个客户端会话由 `run-mcp.sh` 起一个 `--rm` 的 stdio 容器，退出即回收。
- 大文件上传走宿主机 `curl -T` 直传 WebDAV 端点，不要经由 MCP 工具 (字符串 content 会撑爆上下文)。

## 已知坑 (实测结论，勿回退)

1. **`CacheSize` 必须是 ≤ 2147483647 的 int32**：写成 3GB (3221225472) 会在启动时抛
   `Exception during deserialization` 且几乎无日志。
2. **`CacheSize` 必须 ≥ 单个上传文件大小**：TboxWebdav 把上传分块 (~4MiB/块) 缓存在内存里用于
   失败重试；默认 20MB 时 2.17GB 文件 (517 块) 重试块数据早已被逐出 → Chunk 0 永远失败 →
   整文件 HTTP 500。实测 10MB 文件 (3 块) 通过、2.17GB 失败、CacheSize=2147483647 通过。
   容器已配 `mem_limit: 4g` 兜底。
3. **容器内 `Host` 必须为 `0.0.0.0`**：写 `127.0.0.1` 时 Kestrel 只绑容器回环，宿主机端口映射
   连不通。对外暴露面由 compose 的 `127.0.0.1:65472:65472` 收窄到本机回环。
4. **别用 `pkill -f <包名>` 管理进程**：模式会匹配到发起命令自身的命令行导致误杀；本项目的脚本
   统一走 docker 生命周期 + `/dev/tcp` 探活。

## 镜像

| 镜像 | 基础 | 来源 |
|---|---|---|
| `sjtu-pan/tbox-webdav:1.0.1` | `mcr.microsoft.com/dotnet/runtime-deps:8.0` (轻量应用镜像，仅 ICU/OpenSSL/zlib) | GitHub Release `1357310795/TboxWebdav` v1.0.1 自包含 linux-x64，`ADD` 自动解压 |
| `sjtu-pan/mcp:1.0.4` | `node:22-alpine` | npm `webdav-mcp-server@1.0.4` |

构建：`docker compose build`。换 TboxWebdav 版本改 compose 与 Dockerfile 的 `TBOX_VERSION`。

## 备份约定

云盘 `/docker-images/` 存放归档镜像 tar 时，同目录放 `<name>.sha256` sidecar；
恢复：`zstd -d x.tar.zst && docker load -i x.tar`。
