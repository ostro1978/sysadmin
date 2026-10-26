#!/usr/bin/env bash
# 07-record-config.sh — запись блока vpn в infra-config.json (Шаг 7 скилла).
#
# Зачем скрипт: раньше Шаг 7 был прозой, и блок vpn дописывал сам агент руками
# (запрещено C.9 — конфиги создают и меняют скрипты скиллов). Здесь запись
# детерминированная: бэкап, правка только полей vpn.*, проверка результата.
#
# Что НЕ делает:
#  - не пишет webBasePath в inventory и в отчёт: путь — второй уровень секрета
#    панели (см. references/panel-hardening.md), а inventory/ версионируется и
#    уходит на GitHub. В infra-config.json путь лежит осознанно: файл в
#    .gitignore папки инфры и нужен VPN-скиллам для вызовов API.
#  - не выводит значение пути в stdout.
#
# Вход через ENV:
#   CONFIG          — путь к infra-config.json (из find_sysadmin_config)
#   PANEL_URL       — публичный URL панели БЕЗ webBasePath
#                     (https://vpn.example.com, либо https://host:порт при прямом доступе)
#   WEB_BASE_PATH   — webBasePath (с слешами или без)
#   LOCATION        — ru-server | foreign-server
#   REALITY_DEST    — домен-донор Reality (по умолчанию www.cloudflare.com)
#
# Выход: 0 — записано и проверено; 1 — ошибка; 2 — неверные параметры.

set -euo pipefail

CONFIG="${CONFIG:?CONFIG обязателен (путь к infra-config.json)}"
PANEL_URL="${PANEL_URL:?PANEL_URL обязателен}"
WEB_BASE_PATH="${WEB_BASE_PATH:?WEB_BASE_PATH обязателен}"
LOCATION="${LOCATION:?LOCATION обязателен (ru-server | foreign-server)}"
REALITY_DEST="${REALITY_DEST:-www.cloudflare.com}"

command -v jq >/dev/null 2>&1 || {
    echo "ERROR: нужен jq. Установи его и повтори (суррогат конфига руками не делаю, C.9)." >&2
    exit 1
}
[ -f "$CONFIG" ] || { echo "ERROR: не найден $CONFIG" >&2; exit 1; }
jq empty "$CONFIG" >/dev/null 2>&1 || { echo "ERROR: $CONFIG — невалидный JSON" >&2; exit 1; }

case "$LOCATION" in
    ru-server|foreign-server) ;;
    *) echo "ERROR: LOCATION должен быть ru-server или foreign-server" >&2; exit 2 ;;
esac
case "$PANEL_URL" in
    https://*) ;;
    *) echo "ERROR: PANEL_URL должен начинаться с https://" >&2; exit 2 ;;
esac
# URL панели — без пути: путь живёт в отдельном поле
if [[ "$PANEL_URL" =~ ^https://[^/]+/.+ ]]; then
    echo "ERROR: PANEL_URL не должен содержать путь (webBasePath хранится отдельно)" >&2
    exit 2
fi

WBP="${WEB_BASE_PATH#/}"
WBP="${WBP%/}"
if [ "${#WBP}" -lt 6 ] || ! [[ "$WBP" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "ERROR: WEB_BASE_PATH — минимум 6 символов, только буквы и цифры" >&2
    exit 2
fi
# Слеши добавляет сам jq: на Windows (Git Bash) аргумент вида "/abc/" для jq.exe
# превращается в путь "C:/Program Files/Git/abc/" (конвертация путей MSYS).

BACKUP="${CONFIG}.bak.$(date +%s)"
cp -p "$CONFIG" "$BACKUP"
TMP="$(mktemp "${CONFIG}.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

jq --arg url "$PANEL_URL" --arg wbp "$WBP" --arg role "$LOCATION" --arg dest "$REALITY_DEST" '
    .vpn = ((.vpn // {}) + {
        enabled: true,
        panel_url: $url,
        panel_web_base_path: ("/" + $wbp + "/"),
        server_role: $role,
        server_proxy_enabled: (.vpn.server_proxy_enabled // false),
        upstream_kind: (.vpn.upstream_kind // "none"),
        default_reality_dest: (.vpn.default_reality_dest // $dest)
    })' "$CONFIG" > "$TMP"

# Проверка записанного: поля на месте, остальные ключи верхнего уровня не потеряны
jq -e --arg url "$PANEL_URL" --arg wbp "$WBP" \
    '.vpn.enabled == true and .vpn.panel_url == $url and .vpn.panel_web_base_path == ("/" + $wbp + "/")' \
    "$TMP" >/dev/null || { echo "ERROR: проверка записанного блока vpn не прошла, конфиг не тронут" >&2; exit 1; }
if [ "$(jq -S 'del(.vpn) | keys' "$CONFIG")" != "$(jq -S 'del(.vpn) | keys' "$TMP")" ]; then
    echo "ERROR: набор ключей верхнего уровня изменился, конфиг не тронут" >&2
    exit 1
fi

chmod --reference="$CONFIG" "$TMP" 2>/dev/null || true
mv "$TMP" "$CONFIG"
trap - EXIT

echo "[config] vpn.* записан в $CONFIG (бэкап: $BACKUP)"
echo "[config] panel_url=$PANEL_URL, server_role=$LOCATION, webBasePath записан (значение не выводится)"
exit 0
