FROM alpine:3.20 AS tbox

ARG TBOX_VERSION=1.0.1
ARG TBOX_ASSET=TboxWebdav.Server.AspNetCore-linux-musl-x64-with-runtime.zip

RUN wget -q -O /tmp/tbox.zip \
      "https://github.com/1357310795/TboxWebdav/releases/download/v${TBOX_VERSION}/${TBOX_ASSET}" \
    && mkdir -p /tmp/x && unzip -q /tmp/tbox.zip -d /tmp/x \
    && SRC="$(dirname "$(find /tmp/x -type f -name TboxWebdav.Server.AspNetCore | head -1)")" \
    && mv "$SRC" /opt/tbox \
    && chmod +x /opt/tbox/TboxWebdav.Server.AspNetCore

FROM node:22-alpine

ARG MCP_VERSION=1.0.4

# musl 自包含 .NET 不捆绑 ICU, 以 invariant 模式运行 (服务逻辑不依赖区域性, 实测 Kestrel/TLS 正常)
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1

COPY --from=tbox /opt/tbox /opt/tbox
COPY entrypoint.sh /usr/local/bin/sjtu-pan-entrypoint
RUN npm install -g webdav-mcp-server@${MCP_VERSION} \
    && chmod +x /usr/local/bin/sjtu-pan-entrypoint

USER node
EXPOSE 65472
ENTRYPOINT ["sjtu-pan-entrypoint"]
CMD ["tbox"]
