# Security Policy

## 报告问题

请通过 GitHub Security Advisories 私下报告：

<https://github.com/Flagwill/sjtu-pan-mcp/security/advisories/new>

不要在公开 issue 中粘贴 `UserToken`、WebDAV 密码、容器日志中的认证头或完整回调 URL。

## 凭据

- `docker/config.yaml` 含 WebDAV `PassWord` 和云盘 `UserToken`，权限必须是 `0600`。
- 该文件、`.env` 和 `docker/config.yaml.*` 备份都已加入 `.gitignore`，不要强制添加。
- `UserToken` 等同云盘访问凭据；怀疑泄漏时重新登录 `cloud.sjtu.edu.cn` 轮换。
- `run-mcp.sh` 从配置文件读取凭据，并通过 `docker run -e NAME` 传递，避免密码出现在
  `docker run` 的进程参数/`ps` 输出中。
- 不要提交 `Logging__LogLevel__System.Net.Http.HttpClient: Trace` 等调试配置；
  Trace 可能记录请求头/URL。

## 网络边界

- compose 只把 WebDAV 桥发布到 `127.0.0.1`。
- 远程访问应通过 VPN/TLS 或额外的反向代理认证；不要把 Basic Auth 直接暴露到公网。
- MCP stdio 会话容器使用 `--network host` 访问宿主机回环桥；不要在该容器内运行不可信进程。
