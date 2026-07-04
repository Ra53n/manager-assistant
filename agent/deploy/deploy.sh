#!/usr/bin/env bash
# deploy.sh — идемпотентная установка агента рутин на VPS. СТРОГО ДОБАВОЧНО:
# новый порт 3100, отдельный systemd-юнит, один маршрут Caddy. НЕ трогает
# VPN/docker/x-ui/xray, существующий yougile-mcp.service и его маршрут.
#
# Запускать на VPS от root из распакованного исходника агента:
#   sudo bash /opt/manager-agent-src/deploy/deploy.sh
#
# Перед запуском dist/ должен быть собран (npm run build). Скрипт ставит prod-
# зависимости на месте (npm ci --omit=dev) — better-sqlite3 соберётся под Node VPS.

set -euo pipefail

APP_USER=manageragent
APP_DIR=/opt/manager-agent
DATA_DIR=$APP_DIR/data
ENV_FILE=/etc/manager-agent.env
UNIT_FILE=/etc/systemd/system/manager-agent.service
CADDYFILE=/etc/caddy/Caddyfile
AGENT_PORT=3100

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(dirname "$SCRIPT_DIR")"

log() { echo -e "\033[1;34m[deploy]\033[0m $*"; }
die() { echo -e "\033[1;31m[deploy] ОШИБКА:\033[0m $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Запускай от root (sudo)."
[ -f "$SRC_DIR/dist/index.js" ] || die "Нет $SRC_DIR/dist/index.js — сначала собери: npm ci && npm run build"
command -v node >/dev/null || die "Не найден node."

# ── 1. Пользователь и каталоги ───────────────────────────────────────────────
if ! id "$APP_USER" >/dev/null 2>&1; then
  log "Создаю системного пользователя $APP_USER"
  useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
fi
mkdir -p "$APP_DIR" "$DATA_DIR" "$APP_DIR/.npm" "$APP_DIR/.cache"

# ── 2. Выкладка приложения (data/ НЕ трогаем) ────────────────────────────────
log "Копирую dist/ и манифесты в $APP_DIR"
rm -rf "$APP_DIR/dist"
cp -r "$SRC_DIR/dist" "$APP_DIR/dist"
cp "$SRC_DIR/package.json" "$APP_DIR/package.json"
[ -f "$SRC_DIR/package-lock.json" ] && cp "$SRC_DIR/package-lock.json" "$APP_DIR/package-lock.json"

log "Ставлю prod-зависимости (npm ci --omit=dev)"
( cd "$APP_DIR" && npm ci --omit=dev --no-audit --no-fund )

# ── 3. Bootstrap-окружение (секреты не перезаписываем) ───────────────────────
if [ ! -f "$ENV_FILE" ]; then
  TOKEN="$(openssl rand -hex 32 2>/dev/null || head -c32 /dev/urandom | xxd -p | tr -d '\n')"
  log "Создаю $ENV_FILE c новым AGENT_API_TOKEN"
  cat > "$ENV_FILE" <<EOF
AGENT_API_TOKEN=$TOKEN
AGENT_HOST=127.0.0.1
AGENT_PORT=$AGENT_PORT
AGENT_DB_PATH=$DATA_DIR/agent.db
AGENT_DEFAULT_TZ=Europe/Moscow
LOG_LEVEL=info
EOF
  chown root:"$APP_USER" "$ENV_FILE"
  chmod 0640 "$ENV_FILE"
  echo
  echo "==================================================================="
  echo " AGENT_API_TOKEN (введи его в приложении, Подключение к VPS → токен):"
  echo "   $TOKEN"
  echo "==================================================================="
  echo
else
  log "$ENV_FILE уже есть — не трогаю (секреты сохранены)."
fi

chown -R "$APP_USER":"$APP_USER" "$APP_DIR"

# ── 4. systemd-юнит ───────────────────────────────────────────────────────────
log "Устанавливаю systemd-юнит"
cp "$SCRIPT_DIR/manager-agent.service" "$UNIT_FILE"
systemctl daemon-reload
systemctl enable manager-agent >/dev/null 2>&1 || true
systemctl restart manager-agent

# ── 5. Маршрут Caddy (идемпотентно, с бэкапом и валидацией) ───────────────────
patch_caddy() {
  [ -f "$CADDYFILE" ] || { log "Caddyfile не найден ($CADDYFILE) — пропускаю маршрут."; return; }
  if grep -q '/agent/' "$CADDYFILE"; then
    log "Caddy: маршрут /agent/* уже есть — пропускаю."
    return
  fi
  local domain upstream
  domain="$(awk 'NF && $0 !~ /^[[:space:]]*#/ {print $1; exit}' "$CADDYFILE")"
  case "$domain" in
    ""|"{"|*"{") die "Не смог определить домен из $CADDYFILE — добавь маршрут вручную (см. Caddyfile.snippet)." ;;
  esac
  upstream="$(awk '/reverse_proxy/ {for(i=1;i<=NF;i++) if($i ~ /127\.0\.0\.1:/){print $i; exit}}' "$CADDYFILE")"
  [ -n "$upstream" ] || upstream="127.0.0.1:3000"

  cp "$CADDYFILE" "$CADDYFILE.bak.$(date +%s)"
  log "Caddy: добавляю handle /agent/* → 127.0.0.1:$AGENT_PORT (домен $domain, MCP $upstream)"
  cat > "$CADDYFILE" <<EOF
$domain {
    encode gzip
    handle /agent/* {
        reverse_proxy 127.0.0.1:$AGENT_PORT
    }
    handle {
        reverse_proxy $upstream
    }
}
EOF
  if command -v caddy >/dev/null; then
    caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1 \
      || die "caddy validate не прошёл — откати $CADDYFILE.bak.* и проверь вручную."
  fi
  systemctl reload caddy
}
patch_caddy

# ── 6. Смоук-проверка ─────────────────────────────────────────────────────────
sleep 1
log "Смоук: локальный /agent/health"
curl -fsS "http://127.0.0.1:$AGENT_PORT/agent/health" && echo
log "Статус сервиса:"
systemctl --no-pager --lines=5 status manager-agent || true
log "Готово. Не забудь задать провайдера/ключ/YouGile в приложении (Настройки агента)."
