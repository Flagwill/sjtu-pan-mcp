SHELL := /bin/bash
COMPOSE ?= docker compose
SCRIPT := ./tbox-webdav.sh

.PHONY: help install start stop restart status doctor logs config client-config test lint compose-config

help:
	@printf '%s\n' \
	  'make install        生成 .env 和 docker/config.yaml 模板' \
	  'make start          启动桥容器' \
	  'make stop           停止桥容器' \
	  'make restart        重启桥容器' \
	  'make status         查看 READY/DEGRADED/DOWN' \
	  'make doctor         容器、凭证、DNS 体检' \
	  'make logs           查看桥日志' \
	  'make config         查看脱敏配置' \
	  'make client-config  输出 MCP 客户端 JSON' \
	  'make test           语法检查 + 无 Docker 单元测试' \
	  'make lint           语法与 compose 配置检查'

install:
	$(SCRIPT) install

start:
	$(SCRIPT) start

stop:
	$(SCRIPT) stop

restart:
	$(SCRIPT) restart

status:
	$(SCRIPT) status

doctor:
	$(SCRIPT) doctor

logs:
	$(SCRIPT) logs

config:
	$(SCRIPT) config

client-config:
	$(SCRIPT) client-config

test:
	bash -n entrypoint.sh run-mcp.sh tbox-webdav.sh tests/test_cli.sh
	bash tests/test_cli.sh

lint:
	bash -n entrypoint.sh run-mcp.sh tbox-webdav.sh tests/test_cli.sh
	$(COMPOSE) config --quiet

compose-config:
	$(COMPOSE) config
