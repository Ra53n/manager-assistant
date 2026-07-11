#!/usr/bin/env bash
# install-llm.sh — идемпотентная установка локальной LLM (Ollama) на VPS и
# защищённого прокси к ней. СТРОГО ДОБАВОЧНО: свой systemd-override, свой
# токен-файл, один маршрут Caddy (handle_path /llm/*). НЕ трогает VPN/docker/
# x-ui/xray, yougile-mcp, manager-agent и их маршруты (/mcp, /agent/*).
#
# Запускать на VPS от root:
#   sudo bash /opt/manager-agent-src/deploy/install-llm.sh [модель ...]
# Модели — аргументами (дефолт ниже); повторный запуск безопасен: пропускает
# готовое и печатает ТОТ ЖЕ токен.
#
# Что делает:
#   1) swap до ≥4 ГБ (страховка от OOM: 3.8 ГБ RAM впритык для 3–4B моделей);
#   2) ставит Ollama (официальный инсталлер) и проверяет bind ТОЛЬКО 127.0.0.1;
#   3) systemd-override под слабый VPS (1 параллельный запрос, 1 модель в RAM);
#   4) токен прокси в /etc/llm-proxy.token (0600);
#   5) маршрут Caddy: https://<домен>/llm/* → 127.0.0.1:11434, без токена — 401;
#   6) ollama pull моделей; 7) смоук-проверки.
#
# ВАЖНО (грабля): старый deploy.sh при ОТСУТСТВИИ /agent/ в Caddyfile переписывает
# файл с нуля и снесёт наш /llm-блок. Сейчас /agent/ есть → deploy.sh его пропускает;
# если когда-нибудь пересоздашь Caddyfile — перезапусти этот скрипт.

set -euo pipefail

OLLAMA_PORT=11434
TOKEN_FILE=/etc/llm-proxy.token
CADDYFILE=/etc/caddy/Caddyfile
OVERRIDE_DIR=/etc/systemd/system/ollama.service.d
OVERRIDE_FILE=$OVERRIDE_DIR/override.conf
SWAPFILE=/swapfile-llm
SWAP_TARGET_KB=$((4 * 1024 * 1024))   # хотим суммарно ≥4 ГБ swap

# Модели по умолчанию: qwen2.5:3b (~1.9 ГБ, безопасно) + qwen3 4B instruct
# (~2.5 ГБ, лучше качество, живёт за счёт swap). 7B на этот VPS НЕ влезает.
MODELS=("$@")
[ ${#MODELS[@]} -gt 0 ] || MODELS=(qwen2.5:3b qwen3:4b-instruct-2507-q4_K_M)

log()  { echo -e "\033[1;34m[llm]\033[0m $*"; }
warn() { echo -e "\033[1;33m[llm] ВНИМАНИЕ:\033[0m $*"; }
die()  { echo -e "\033[1;31m[llm] ОШИБКА:\033[0m $*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "Запускай от root (sudo)."

# ── 1. Swap ≥4 ГБ (добавочным файлом; существующий /swapfile 512M не трогаем) ──
swap_total_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
if [ "${swap_total_kb:-0}" -lt "$SWAP_TARGET_KB" ]; then
  if [ ! -f "$SWAPFILE" ]; then
    log "Swap ${swap_total_kb}kB < 4 ГБ — создаю $SWAPFILE (4 ГБ)"
    fallocate -l 4G "$SWAPFILE" 2>/dev/null || dd if=/dev/zero of="$SWAPFILE" bs=1M count=4096 status=none
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null
  fi
  swapon --show=NAME --noheadings | grep -qx "$SWAPFILE" || swapon "$SWAPFILE"
  grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
else
  log "Swap уже ${swap_total_kb}kB (≥4 ГБ) — пропускаю."
fi

# ── 2. Ollama ─────────────────────────────────────────────────────────────────
if ! command -v ollama >/dev/null; then
  log "Ставлю Ollama (официальный инсталлер)"
  curl -fsSL https://ollama.com/install.sh | sh || die "Не удалось установить Ollama."
else
  log "Ollama уже установлена: $(ollama --version 2>/dev/null || echo '?')"
fi

# ── 3. systemd-override под слабый VPS (2 CPU / 3.8 ГБ RAM) ───────────────────
mkdir -p "$OVERRIDE_DIR"
override_tmp="$(mktemp)"
cat > "$override_tmp" <<'EOF'
[Service]
# ТОЛЬКО loopback: наружу Ollama смотрит через Caddy /llm/* с токеном.
Environment="OLLAMA_HOST=127.0.0.1:11434"
# Слабый VPS: один запрос за раз (рой сериализуется на сервере), одна модель
# в памяти, держим её 30 минут (загрузка с диска — десятки секунд).
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=30m"
EOF
if ! cmp -s "$override_tmp" "$OVERRIDE_FILE" 2>/dev/null; then
  log "Пишу systemd-override ($OVERRIDE_FILE) и перезапускаю ollama"
  mv "$override_tmp" "$OVERRIDE_FILE"
  systemctl daemon-reload
  systemctl enable ollama >/dev/null 2>&1 || true
  systemctl restart ollama
else
  rm -f "$override_tmp"
  log "systemd-override уже актуален."
  systemctl enable --now ollama >/dev/null 2>&1 || true
fi

# Дождаться сервера и проверить bind: только 127.0.0.1, наружу порт торчать не должен.
for _ in $(seq 1 15); do
  curl -fsS "http://127.0.0.1:$OLLAMA_PORT/api/tags" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "http://127.0.0.1:$OLLAMA_PORT/api/tags" >/dev/null || die "Ollama не отвечает на 127.0.0.1:$OLLAMA_PORT."
if ss -ltn | awk '{print $4}' | grep -E "(^|\*|0\.0\.0\.0|\[::\]):$OLLAMA_PORT$" | grep -vq "127.0.0.1:$OLLAMA_PORT"; then
  die "Ollama слушает не только loopback — проверь OLLAMA_HOST в $OVERRIDE_FILE."
fi
log "Ollama жива на 127.0.0.1:$OLLAMA_PORT (только loopback)."

# ── 4. Токен прокси (переиспользуем при повторном запуске) ────────────────────
if [ ! -f "$TOKEN_FILE" ]; then
  log "Генерирую токен LLM-прокси → $TOKEN_FILE"
  ( umask 177 && openssl rand -hex 32 > "$TOKEN_FILE" ) || die "Не удалось создать токен."
fi
chmod 600 "$TOKEN_FILE"
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[ -n "$TOKEN" ] || die "$TOKEN_FILE пуст — удали его и перезапусти скрипт."

# ── 5. Маршрут Caddy: handle_path /llm/* с проверкой bearer-токена ────────────
patch_caddy() {
  [ -f "$CADDYFILE" ] || die "Caddyfile не найден ($CADDYFILE)."
  if grep -q 'handle_path /llm/' "$CADDYFILE"; then
    log "Caddy: маршрут /llm/* уже есть — пропускаю."
    return
  fi
  cp "$CADDYFILE" "$CADDYFILE.bak.$(date +%s)"
  log "Caddy: вставляю handle_path /llm/* → 127.0.0.1:$OLLAMA_PORT (перед fallback-handle)"
  # Вставка ПЕРЕД первым «голым» handle { (fallback на MCP) — файл обжитой,
  # целиком не переписываем (в отличие от bootstrap в deploy.sh).
  local tmp; tmp="$(mktemp)"
  if ! awk -v port="$OLLAMA_PORT" -v token="$TOKEN" '
    !ins && /^[[:space:]]*handle[[:space:]]*\{[[:space:]]*$/ {
      print "    handle_path /llm/* {"
      print "        @noauth not header Authorization \"Bearer " token "\""
      print "        respond @noauth \"unauthorized\" 401"
      print "        reverse_proxy 127.0.0.1:" port " {"
      print "            # Ollama отвергает чужой Host (403) — подменяем на upstream."
      print "            header_up Host 127.0.0.1:" port
      print "            flush_interval -1"
      print "        }"
      print "    }"
      ins=1
    }
    { print }
    END { exit ins ? 0 : 1 }
  ' "$CADDYFILE" > "$tmp"; then
    rm -f "$tmp"
    die "Не нашёл fallback-блок «handle {» в $CADDYFILE — добавь /llm-маршрут вручную."
  fi
  mv "$tmp" "$CADDYFILE"
  # Токен теперь в конфиге — сужаем права (caddy на Ubuntu бежит под user caddy).
  chown root:caddy "$CADDYFILE" 2>/dev/null || true
  chmod 640 "$CADDYFILE"
  if command -v caddy >/dev/null; then
    if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
      latest_bak="$(ls -t "$CADDYFILE".bak.* | head -1)"
      cp "$latest_bak" "$CADDYFILE"
      die "caddy validate не прошёл — откатил из $latest_bak, проверь вручную."
    fi
  fi
  systemctl reload caddy
}
patch_caddy

# ── 6. Модели ─────────────────────────────────────────────────────────────────
mem_avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
log "Доступно RAM: $((mem_avail_kb / 1024)) МБ (+swap). Ставлю модели: ${MODELS[*]}"
for model in "${MODELS[@]}"; do
  if ollama pull "$model"; then
    log "✓ $model"
  else
    warn "не удалось скачать «$model» (нет такого тега? реестр недоступен?) — пропускаю, остальное продолжаю."
  fi
done

# ── 7. Смоук-проверки ─────────────────────────────────────────────────────────
domain="$(awk 'NF && $0 !~ /^[[:space:]]*#/ {print $1; exit}' "$CADDYFILE")"
case "$domain" in
  ""|"{"|*"{") warn "не смог определить домен из Caddyfile — проверь https-доступ вручную."; domain="" ;;
esac
if [ -n "$domain" ]; then
  code_auth="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "https://$domain/llm/v1/models" || true)"
  code_noauth="$(curl -s -o /dev/null -w '%{http_code}' "https://$domain/llm/v1/models" || true)"
  code_agent="$(curl -s -o /dev/null -w '%{http_code}' "https://$domain/agent/health" || true)"
  [ "$code_auth" = "200" ]   && log "✓ /llm/v1/models с токеном: 200"   || warn "/llm/v1/models с токеном: $code_auth (ожидал 200)"
  [ "$code_noauth" = "401" ] && log "✓ /llm/v1/models без токена: 401"  || warn "/llm/v1/models без токена: $code_noauth (ожидал 401)"
  [ "$code_agent" = "200" ]  && log "✓ /agent/health не пострадал: 200" || warn "/agent/health: $code_agent (ожидал 200) — проверь Caddyfile!"
fi

echo
echo "==================================================================="
echo " LLM-прокси готов. Введи в приложении (⋯ → API-ключи → VPS (Ollama)):"
echo "   Адрес: https://${domain:-<домен-vps>}/llm"
echo "   Токен: $TOKEN"
echo " Модели: ${MODELS[*]}"
echo " Ротация токена: rm $TOKEN_FILE; убрать /llm-блок из $CADDYFILE;"
echo " перезапустить этот скрипт."
echo "==================================================================="
