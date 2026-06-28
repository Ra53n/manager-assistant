# Координаты инстанса агента — ШАБЛОН (этот файл КОММИТИТСЯ, без секретов)

Скопируй в `instance.local.md` (он в `.gitignore`, не попадёт на GitHub) и заполни конкретными значениями.
Сюда (в `*.example.md`, который коммитится) реальные адреса/домены/секреты НЕ вписывать.

```
VPS_HOST   = <ip-или-хост VPS>
DOMAIN     = <публичный домен, напр. xxx.sslip.io>
BASE_URL   = https://<DOMAIN>/agent          # публичная база REST API (за Caddy)
SSH        = <способ доступа: ключ / root по паролю>   # сам пароль/ключ ЗДЕСЬ НЕ ХРАНИМ

# Пути на VPS
APP_DIR    = /opt/manager-agent               # dist + node_modules
SRC_DIR    = /opt/manager-agent-src           # зеркало исходника для deploy.sh
DB         = /opt/manager-agent/data/agent.db
ENV_FILE   = /etc/manager-agent.env           # bootstrap; AGENT_API_TOKEN печатает deploy.sh
SERVICE    = manager-agent.service            # systemd (рестарт только --no-block)

# Секреты живут ТОЛЬКО в ENV_FILE на VPS и у владельца:
#   AGENT_API_TOKEN      — bearer для приложения/API
#   (LLM-ключ, YouGile MCP-токен — в БД, задаются из приложения)
```

Грабли передеплоя и end-to-end проверка — в `agent/README.md`, секция
«Передеплой надёжно — грабли и проверка».
