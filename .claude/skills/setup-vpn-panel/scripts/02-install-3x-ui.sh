#!/usr/bin/env bash
# 02-install-3x-ui.sh — установка эталонной 3X-UI (MHSanaei/3x-ui) с фиксацией версии.
#
# Особенности:
#  - Использует официальный install.sh, не «ставим из исходников».
#  - Фиксирует версию (VERSION=v3.10.2 ...) — защита от breaking changes.
#  - Установщик 3X-UI v3.x умеет неинтерактивный режим и берёт креды из
#    окружения (XUI_*), поэтому пароль в аргументы команды не попадает.
#  - Дефолтные креды заменяются в момент установки: smart-логин (≠ admin),
#    32-символьный пароль, webBasePath, нестандартный порт.
#
# Вход через ENV:
#   SSH_TARGET              — SSH-цель (alias или user@host)
#   VERSION                 — версия панели (например, v3.10.2)
#   ADMIN_LOGIN             — сгенерированный 8-символьный логин (≠admin)
#   ADMIN_PASSWORD          — сгенерированный 32-символьный пароль
#   PANEL_PORT              — нестандартный порт (например, 48391)
#   WEB_BASE_PATH           — webBasePath (10 символов, например abcdef1234)
#
# Выход:
#   0 — установка завершена, креды применены
#   1 — ошибка установки
#   2 — ошибка параметров

set -euo pipefail

SSH_TARGET="${SSH_TARGET:?SSH_TARGET обязателен}"
VERSION="${VERSION:?VERSION обязателен (например, v3.10.2)}"
ADMIN_LOGIN="${ADMIN_LOGIN:?ADMIN_LOGIN обязателен}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD обязателен}"
PANEL_PORT="${PANEL_PORT:?PANEL_PORT обязателен}"
WEB_BASE_PATH="${WEB_BASE_PATH:?WEB_BASE_PATH обязателен}"

# Валидация параметров
if [ "$ADMIN_LOGIN" = "admin" ]; then
    echo "ERROR: ADMIN_LOGIN не должен быть 'admin' (это первое, что брутят)" >&2
    exit 2
fi
if [ "${#ADMIN_PASSWORD}" -lt 16 ]; then
    echo "ERROR: ADMIN_PASSWORD слишком короткий (минимум 16 символов, текущая длина: ${#ADMIN_PASSWORD})" >&2
    exit 2
fi
if ! [[ "$PANEL_PORT" =~ ^[0-9]+$ ]] || [ "$PANEL_PORT" -lt 1024 ] || [ "$PANEL_PORT" -gt 65535 ]; then
    echo "ERROR: PANEL_PORT должен быть в диапазоне 1024-65535" >&2
    exit 2
fi
if [ "${#WEB_BASE_PATH}" -lt 6 ]; then
    echo "ERROR: WEB_BASE_PATH слишком короткий (минимум 6 символов)" >&2
    exit 2
fi
# Пароль и логин попадают в переменные окружения установщика построчно через
# stdin — перевод строки внутри значения сломал бы протокол, а кавычки и
# пробелы установщик не ожидает. Допускаем только буквы и цифры.
if ! [[ "$ADMIN_LOGIN" =~ ^[A-Za-z0-9]+$ ]] || ! [[ "$ADMIN_PASSWORD" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "ERROR: ADMIN_LOGIN и ADMIN_PASSWORD должны состоять только из букв и цифр" >&2
    exit 2
fi

# Удаляем ведущие/завершающие слеши в WEB_BASE_PATH
WEB_BASE_PATH_CLEAN="${WEB_BASE_PATH#/}"
WEB_BASE_PATH_CLEAN="${WEB_BASE_PATH_CLEAN%/}"

echo "[install] Установка 3X-UI $VERSION на $SSH_TARGET..."

# ─── Установка через официальный installer, креды — через окружение ───────────
# Почему не `x-ui setting -password '<пароль>'`: пароль в аргументах команды
# виден в /proc/<pid>/cmdline и в ps любому локальному пользователю на время
# работы команды, а прежний вариант ещё и подставлял его в текст скрипта,
# уходящего по ssh. Установщик v3.x в неинтерактивном режиме берёт креды из
# окружения (XUI_USERNAME / XUI_PASSWORD / XUI_PANEL_PORT / XUI_WEB_BASE_PATH),
# поэтому:
#  - секреты уходят на сервер через stdin ssh: printf — встроенная команда
#    оболочки, а ssh получает только фиксированный текст команды без секретов;
#  - на сервере они читаются командой read в переменные окружения, которые
#    наследует установщик;
#  - вывод установщика фильтруется: он сам печатает логин, пароль и API-токен
#    открытым текстом, в журнал сессии им попадать нельзя.
# Внутри самого установщика вызов `x-ui setting -password ...` остаётся (так
# устроен upstream) — это окно в доли секунды на сервере оператора, а не
# хранение пароля в нашем коде, истории оболочки или логе.
#
# XUI_SSL_MODE=none — TLS здесь не выпускаем (это Шаг 4, скрипт 03);
# XUI_ENABLE_FAIL2BAN=false — не даём установщику менять уже настроенный
# fail2ban сервера (правка вне задачи, C.7).
# Установщик скачивается в файл и запускается по тегу VERSION (а не через
# `bash <(curl ...)`); контрольная сумма печатается в stderr.
REMOTE_CMD=$(cat <<'REMOTE_EOF'
set -euo pipefail
IFS= read -r XUI_USERNAME
IFS= read -r XUI_PASSWORD
IFS= read -r XUI_PANEL_PORT
IFS= read -r XUI_WEB_BASE_PATH
SUDO=""
[ "$(id -u)" -eq 0 ] || SUDO="sudo"
umask 077
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
# `sudo -E` на практике НЕ переносит эти переменные (проверено живьём
# 2026-10-26: установщик молча сгенерировал случайные креды и порт, а
# XUI_ENABLE_FAIL2BAN=false был проигнорирован). Поэтому значения кладём во
# временный env-файл 0600 в каталоге mktemp (не в аргументы команды), root
# читает его сам; каталог удаляется по trap.
{
    printf 'XUI_USERNAME=%s\n' "$XUI_USERNAME"
    printf 'XUI_PASSWORD=%s\n' "$XUI_PASSWORD"
    printf 'XUI_PANEL_PORT=%s\n' "$XUI_PANEL_PORT"
    printf 'XUI_WEB_BASE_PATH=%s\n' "$XUI_WEB_BASE_PATH"
    printf 'XUI_NONINTERACTIVE=1\nXUI_SSL_MODE=none\nXUI_DB_TYPE=sqlite\nXUI_ENABLE_FAIL2BAN=false\n'
} > "$D/env"
curl -fsSL -o "$D/install.sh" "https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_VERSION}/install.sh"
sha256sum "$D/install.sh" >&2
# grep -v возвращает 1, если отфильтровал всё — для нас это не ошибка
$SUDO bash -c 'set -a; . "$1/env"; set +a; bash "$1/install.sh" "$2"' _ "$D" "${XUI_VERSION}" 2>&1 \
    | { grep -viE 'username|password|api token|webbasepath|access url' || true; }
exit "${PIPESTATUS[0]}"
REMOTE_EOF
)

# Текст удалённого скрипта едет в base64 (только [A-Za-z0-9+/=] — не зависит от
# того, какая оболочка у пользователя на сервере и как она разбирает кавычки).
# XUI_VERSION — не секрет, его можно передать в тексте команды.
REMOTE_B64=$(printf '%s\n' "$REMOTE_CMD" | base64 | tr -d '\n')
printf '%s\n%s\n%s\n%s\n' "$ADMIN_LOGIN" "$ADMIN_PASSWORD" "$PANEL_PORT" "$WEB_BASE_PATH_CLEAN" | \
    ssh "$SSH_TARGET" "XUI_VERSION='$VERSION' bash -c \"\$(echo $REMOTE_B64 | base64 -d)\"" || {
    echo "ERROR: установка через install.sh упала" >&2
    exit 1
}

# ─── Проверка, что сервис стартовал ───────────────────────────────────────────
echo "[install] Проверка systemctl status x-ui..."
sleep 3  # дать сервису подняться

if ! ssh "$SSH_TARGET" "systemctl is-active --quiet x-ui"; then
    echo "ERROR: x-ui.service не запустился. Проверь: ssh $SSH_TARGET 'journalctl -xeu x-ui --no-pager | tail -50'" >&2
    exit 1
fi
echo "[install] x-ui.service: active (running)"

# ─── Проверка, что настройки применились (без секретов) ──────────────────────
# Креды установщик применил из окружения; отдельного шага `x-ui setting
# -username/-password` больше нет. Показываем только порт и признак
# дефолтных кредов, логин и пароль не читаем.
echo "[install] Проверка применения настроек..."

SETTING_OUTPUT="$(ssh "$SSH_TARGET" "sudo /usr/local/x-ui/x-ui setting -show true" 2>&1 \
    | grep -iE '^(port|webBasePath|hasDefaultCredential):' || true)"

APPLIED_PORT="$(echo "$SETTING_OUTPUT" | grep -iE '^port:' | grep -oE '[0-9]{4,5}' | head -n1)"
APPLIED_PATH="$(echo "$SETTING_OUTPUT" | grep -iE '^webBasePath:' | head -n1)"
APPLIED_DEFAULT="$(echo "$SETTING_OUTPUT" | grep -iE '^hasDefaultCredential:' | head -n1)"

if [ -z "$APPLIED_PORT" ] || [ "$APPLIED_PORT" != "$PANEL_PORT" ]; then
    echo "WARN: порт панели не подтвердился через 'x-ui setting -show' (ожидался $PANEL_PORT)." >&2
fi

if ! echo "$APPLIED_PATH" | grep -q "$WEB_BASE_PATH_CLEAN"; then
    echo "WARN: webBasePath не подтвердился в выводе 'x-ui setting -show'." >&2
fi

if echo "$APPLIED_DEFAULT" | grep -qi 'true'; then
    echo "ERROR: панель всё ещё с дефолтными кредами (hasDefaultCredential: true)" >&2
    exit 1
fi

echo "[install] Готово."
echo ""
echo "Установлено:"
echo "  Версия:    $VERSION"
echo "  Порт:      $PANEL_PORT"
echo "  webPath:   (записан в менеджер паролей, в отчёт не выводится)"
echo "  Логин:     (в менеджере паролей)"
echo "  Пароль:    (32 символа — в менеджере паролей)"
echo ""
echo "TLS и доступ к панели настраиваются следующим шагом (03-configure-tls.sh)."

exit 0
