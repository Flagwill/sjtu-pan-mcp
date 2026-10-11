# sjtu-pan-mcp

交大云盘 (cloud.sjtu.edu.cn) 的 MCP 化部署：把云盘映射为 WebDAV，再以 `webdav-mcp-server`
(stdio) 提供给 opencode / Claude 等 MCP 客户端。全链路 Docker 化，密钥不进仓库。

```
MCP 客户端 (opencode)
  └─ run-mcp.sh ── docker run -i (stdio) ──> sjtu-pan/mcp-tbox ... mcp   [webdav-mcp-server]
                          │ HTTP (host network)
                          ▼
              sjtu-pan-mcp-tbox-webdav-1 (127.0.0.1:65472 → 容器 :65472)
                同一镜像的 tbox 角色: TboxWebdav 桥 (musl 自包含 .NET 8)
                          │ HTTPS
                          ▼
                   交大云盘 Tbox API
```

单镜像双角色（`entrypoint.sh` 按第一个参数分派 `tbox`/`mcp`）：桥是 compose 常驻服务，
MCP 是每个客户端会话按需拉起的 stdio 容器。

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
| `tbox-webdav.sh start/stop/restart/status` | 桥容器生命周期；`status` 分 READY/DEGRADED/DOWN (exit 3) |
| `tbox-webdav.sh ensure` | 幂等拉起 (run-mcp.sh 内部使用)，含就绪检查与陈旧容器自愈 |
| `tbox-webdav.sh check-config` | 配置预检 (int32 上限 / 最小值 / 端口) |
| `tbox-webdav.sh doctor` | 一键体检：容器 + 带凭证 PROPFIND + 容器内 DNS + 宿主机解析 + 结论 |
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
4. **别用 `pkill -f <名字>` 管理进程**：模式会匹配到发起命令自身的命令行导致误杀（脚本文件名、
   内联参数都算污染源）；本项目脚本统一走 docker 生命周期 + HTTP 探活。
5. **stdio 会话容器必须显式回收**：`webdav-mcp-server` 收到 stdin EOF 不退出，docker CLI 被
   SIGKILL 时 `--rm`/sig-proxy 全部失效会留下孤儿容器；`run-mcp.sh` 用后台 run + trap 按名 kill。
6. **MCP 包装脚本的 stdout 就是协议通道**：(a) 一切诊断必须走 stderr（`tbox-webdav.sh` 的 log 已改
   stderr，`run-mcp.sh` 还把 ensure 输出 `1>&2` 双保险）；(b) 非交互 bash 里后台命令若未显式重定向
   stdin，会被 POSIX 规则强制接到 `/dev/null` —— `docker run -i ... <&0 &` 的 `<&0` 不可删，
   否则 initialize 请求进不了容器，客户端表现为 "server unavailable" 且日志毫无异常。
7. **桥容器“陈旧”会静默失联：DNS 要在容器重启后才刷新**。Docker 只在容器**创建**时生成
   `/etc/resolv.conf`。若建容器时宿主机 resolv.conf 里没有可用 nameserver（切网/VPN/systemd-resolved
   都可能导致），容器里会写着 `# NO EXTERNAL NAMESERVERS DEFINED`，嵌入式 DNS `127.0.0.11` 查不动 ——
   **之后宿主机 DNS 恢复，运行中的容器也不会自愈**。症状（2026-10-11 实测）：宿主机解析正常、同网络新容器
   解析正常、容器内 `EAI_AGAIN` 且每次请求卡 5s；云盘 API 全部不可达 → TboxWebdav 拿不到 folder info →
   PROPFIND 一律 404（**是 404，不是 401/502**，MCP 层表现为 `Invalid response: 404 Not Found`，
   极易误判成 token 失效或路径写错）。判定手势：容器内 `node -e 'require("dns").resolve4("pan.sjtu.edu.cn",(e,a)=>console.log(e||a))'`
   （镜像里没 curl，但有 node）。**修复：`./tbox-webdav.sh restart`**，DNS 与 PROPFIND 立刻恢复
   （注意 stop+start 不必 recreate，Docker 会在容器启动时按宿主机 resolv.conf 重写该文件）。
   别浪费时间验证 UserToken：token 没过期时先查容器出网。
   **现已内置自动自愈**：`run-mcp.sh` 每次拉起会话都会走 `ensure` → 带凭证做一次 PROPFIND 就绪检查
   （旧版只探"端口通不通"，无凭证 401 也算活着，于是把这种半死状态误报成健康）。检查不过且容器内 DNS 失效时
   自动 `restart` 一次；DNS 正常却仍不通则判定为上游/凭证问题，只告警不重启。
   `status` 从此分三态：`READY`(PROPFIND 207) / `DEGRADED`(在听但云盘不通，exit 3) / `DOWN`(exit 3)。
   一键体检：`./tbox-webdav.sh doctor`（容器状态、带凭证 PROPFIND、容器 resolv.conf、容器内 DNS、宿主机解析、结论）。

## 镜像

| 镜像 | 基础 | 内容 |
|---|---|---|
| `sjtu-pan/mcp-tbox:1.0.4-tbox1.0.1` | `node:22-alpine` | 上游 GitHub Release `1357310795/TboxWebdav` v1.0.1 的 **linux-musl 自包含 .NET 8** 二进制 (alpine extract 阶段拉取解压) + npm `webdav-mcp-server@1.0.4` |

- 选 musl 版 .NET 才能与 alpine 上的 node 合并成单镜像 (~300MB)；glibc 版必须配 Debian 系
  `dotnet/runtime-deps` 基座，两个运行时栈无法共存一个镜像。
- musl 版不捆绑 ICU，需 `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1` (Dockerfile 已内置)。
- 构建：`docker compose build`。换版本改 compose 的 `TBOX_VERSION` / `MCP_VERSION`。

## 备份约定

云盘 `/docker-images/` 存放归档镜像 tar 时，同目录放 `<name>.sha256` sidecar；
恢复：`zstd -d x.tar.zst && docker load -i x.tar`。
