#!/usr/bin/env bash
#
# man-translate
#
# Подготовка русской man-страницы для перевода LLM.
#
# Версия: 0.2
#

set -euo pipefail

VERSION="0.2"

WORKDIR="$HOME/man-ru-translate"
LANG_DIR="/usr/local/share/man/ru"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"


msg()
{
    echo -e "${GREEN}$*${RESET}"
}


warn()
{
    echo -e "${YELLOW}$*${RESET}"
}


error()
{
    echo -e "${RED}$*${RESET}" >&2
}


usage()
{
    cat <<EOF

Использование:

    $SCRIPT_NAME <сущность>

Пример:

    $SCRIPT_NAME scp
    $SCRIPT_NAME printf
    $SCRIPT_NAME rpc

EOF
}


case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
    --version|-V)
        echo "$SCRIPT_NAME $VERSION"
        exit 0
        ;;
esac


cleanup()
{
    if [[ -n "${TMPFILE:-}" && -f "$TMPFILE" ]]; then
        rm -f -- "$TMPFILE"
    fi
}

trap cleanup EXIT


#
# Проверка аргументов
#

if [[ $# -ne 1 ]]; then
    usage
    exit 1
fi


ENTITY="$1"


#
# Проверка зависимостей
#

require_command()
{
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Не найдена команда: $1"
        exit 1
    fi
}

require_command man
require_command groff
require_command gzip
require_command sha256sum
require_command mandb
require_command sudo
require_command mktemp
require_command install
require_command sed
require_command awk

#
# Поиск исходной man-страницы
#
# LC_ALL=C нужен, чтобы после установки перевода
# скрипт не выбирал русскую страницу как исходник.
#

MAN_FILE=$(LC_ALL=C man -w "$ENTITY" 2>/dev/null | sed -n '1p' || true)

if [[ -z "$MAN_FILE" ]]; then
    error "Man-страница для '$ENTITY' не найдена."
    exit 1
fi

if [[ ! -f "$MAN_FILE" ]]; then
    error "Найденный файл man-страницы не существует:"
    echo "  $MAN_FILE" >&2
    exit 1
fi

case "$MAN_FILE" in
    *.xz)
        require_command xz
        ;;
    *.bz2)
        require_command bzip2
        ;;
    *.zst)
        require_command zstd
        ;;
esac

#
# Извлечение имени и секции
#

BASENAME=$(basename "$MAN_FILE")

# Примеры:
#   scp.1.gz
#   rpc.5.gz
#   foo.3posix.gz
#   man.1
#
# Сначала удаляем поддерживаемое расширение сжатия,
# затем выделяем часть после последней точки как секцию.
#

MAN_FILENAME="$BASENAME"

case "$MAN_FILENAME" in
    *.gz)
        MAN_FILENAME="${MAN_FILENAME%.gz}"
        ;;
    *.xz)
        MAN_FILENAME="${MAN_FILENAME%.xz}"
        ;;
    *.bz2)
        MAN_FILENAME="${MAN_FILENAME%.bz2}"
        ;;
    *.zst)
        MAN_FILENAME="${MAN_FILENAME%.zst}"
        ;;
esac

NAME="${MAN_FILENAME%.*}"
SECTION="${MAN_FILENAME##*.}"

if [[ -z "$NAME" || -z "$SECTION" || "$NAME" == "$MAN_FILENAME" ]]; then
    error "Не удалось определить имя или секцию man-страницы."
    echo "  Файл: $BASENAME" >&2
    exit 1
fi


msg "Найдена страница:"
echo "  $MAN_FILE"
echo

msg "Сущность:"
echo "  $NAME"
echo

msg "Раздел:"
echo "  $SECTION"
echo


#
# Создание рабочего каталога
#

mkdir -p "$WORKDIR"

OUTFILE="$WORKDIR/${NAME}.${SECTION}.ru"

if [[ -f "$OUTFILE" ]]; then
    warn "Файл уже существует:"
    echo "  $OUTFILE"

    read -rp "Перезаписать? (y/N): " answer

    if [[ "$answer" != "y" ]]; then
        exit 0
    fi
fi

#
# Поиск prompt.txt
#
# Приоритет:
#   1. Пользовательский prompt.
#   2. prompt рядом со скриптом.
#   3. Prompt, установленный системой.
#   4. Встроенный prompt.
#

USER_PROMPT_FILE="$HOME/.config/man-translate/prompt.txt"
LOCAL_PROMPT_FILE="$SCRIPT_DIR/prompt.txt"
SYSTEM_PROMPT_FILE="/usr/local/share/man-translate/prompt.txt"

PROMPT_FILE=""

if [[ -f "$USER_PROMPT_FILE" ]]; then
    PROMPT_FILE="$USER_PROMPT_FILE"

elif [[ -f "$LOCAL_PROMPT_FILE" ]]; then
    PROMPT_FILE="$LOCAL_PROMPT_FILE"

elif [[ -f "$SYSTEM_PROMPT_FILE" ]]; then
    PROMPT_FILE="$SYSTEM_PROMPT_FILE"
fi


if [[ -n "$PROMPT_FILE" ]]; then
    PROMPT=$(<"$PROMPT_FILE")

    msg "Используется prompt:"
    echo "  $PROMPT_FILE"

else
    warn "prompt.txt не найден; используется встроенный prompt."

    PROMPT='
Ты — опытный переводчик технической документации GNU/Linux.

Переведи эту man-страницу на русский язык.

Сохрани формат roff.
Не изменяй макросы.
Не переводи имена команд,
опции, пути, переменные,
примеры команд и программный код.

Выведи только готовый roff-файл.
'
fi



#
# Создание файла для передачи LLM
#

msg "Создание файла перевода..."

{
    echo "$PROMPT"
    echo

    echo "================================================="
    echo "НАЧАЛО ОРИГИНАЛЬНОЙ MAN-СТРАНИЦЫ"
    echo "================================================="

    case "$MAN_FILE" in
        *.gz)
            gzip -cd -- "$MAN_FILE"
            ;;
        *.xz)
            xz -cd -- "$MAN_FILE"
            ;;
        *.bz2)
            bzip2 -cd -- "$MAN_FILE"
            ;;
        *.zst)
            zstd -cdq -- "$MAN_FILE"
            ;;
        *)
            cat -- "$MAN_FILE"
            ;;
    esac

    echo "================================================="
    echo "КОНЕЦ ОРИГИНАЛЬНОЙ MAN-СТРАНИЦЫ"
    echo "================================================="
} > "$OUTFILE"


BEFORE_HASH=$(sha256sum "$OUTFILE" | awk '{print $1}')


msg ""
msg "Готов файл:"
echo
echo "  $OUTFILE"
echo


cat <<EOF

Следующие действия:

1. Откройте файл.
2. Скопируйте содержимое.
3. Передайте его вашей LLM.
4. Полностью замените содержимое файла ответом LLM.
   В итоговом файле не должны остаться prompt и разделители.
5. Сохраните файл.

Когда закончите — нажмите ENTER.

Для отмены нажмите Ctrl+C.

EOF

read -r


#
# Проверка изменения файла
#

while true
do
    if [[ ! -s "$OUTFILE" ]]; then
        error "Файл пуст."
        exit 1
    fi

    AFTER_HASH=$(sha256sum "$OUTFILE" | awk '{print $1}')

    if [[ "$BEFORE_HASH" != "$AFTER_HASH" ]]; then
        break
    fi

    warn "Файл не изменился."

    read -rp \
        "Нажмите ENTER после вставки перевода или Ctrl+C: "
done


#
# Проверка roff
#

if grep -Fq \
    -e "НАЧАЛО ОРИГИНАЛЬНОЙ MAN-СТРАНИЦЫ" \
    -e "КОНЕЦ ОРИГИНАЛЬНОЙ MAN-СТРАНИЦЫ" \
    "$OUTFILE"
then
    error "В файле остались служебные разделители."
    error "Полностью замените содержимое файла готовым roff-переводом."
    exit 1
fi

msg "Проверка roff..."

if ! groff -mandoc -Tutf8 -- "$OUTFILE" >/dev/null 2>&1; then
    error "Ошибка roff."
    echo
    echo "Файл оставлен:"
    echo "  $OUTFILE"
    exit 1
fi

msg "roff OK"


#
# Проверка sudo до начала установки
#

msg "Проверка прав sudo..."

if ! sudo -v; then
    error "Не удалось получить права sudo."
    exit 1
fi


#
# Создание каталога назначения
#

TARGET_DIR="$LANG_DIR/man$SECTION"

sudo install -d -m 0755 -- "$TARGET_DIR"

msg "Каталог назначения:"
echo "  $TARGET_DIR"


#
# Архивация
#

TMPFILE=$(mktemp "${TMPDIR:-/tmp}/man-translate.XXXXXX.gz")

gzip -9 -c -- "$OUTFILE" > "$TMPFILE"

if [[ ! -s "$TMPFILE" ]]; then
    error "Не удалось создать архив man-страницы."
    exit 1
fi

#
# Установка
#

TARGET="$TARGET_DIR/${NAME}.${SECTION}.gz"

msg "Установка:"
echo "  $TARGET"

sudo install -m 0644 -- "$TMPFILE" "$TARGET"


#
# Обновление базы man
#

msg "Обновление базы man..."

if ! sudo mandb -q; then
    warn "Man-страница установлена, но обновить базу mandb не удалось."
    warn "Попробуйте выполнить вручную: sudo mandb -q"
fi

#
# Завершение
#

msg ""
msg "Готово!"

echo
echo "Проверьте:"
echo
echo "    LANG=ru_RU.UTF-8 man $ENTITY"
echo

exit 0
