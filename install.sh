#!/usr/bin/env bash
#
# install.sh
#
# Установка man-translate.
#

set -euo pipefail


PREFIX="/usr/local"
BIN_DIR="$PREFIX/bin"
SHARE_DIR="$PREFIX/share/man-translate"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROGRAM="$SCRIPT_DIR/man-translate.sh"
PROMPT="$SCRIPT_DIR/prompt.txt"


error()
{
    echo "Ошибка: $*" >&2
}


if [[ ! -f "$PROGRAM" ]]; then
    error "Не найден файл программы: $PROGRAM"
    exit 1
fi

if [[ ! -f "$PROMPT" ]]; then
    error "Не найден файл prompt: $PROMPT"
    exit 1
fi

if ! command -v sudo >/dev/null; then
    error "Команда sudo не найдена."
    exit 1
fi

if ! command -v install >/dev/null; then
    error "Команда install не найдена."
    exit 1
fi


echo "Установка man-translate..."
echo "Будут обновлены:"
echo "  $BIN_DIR/man-translate"
echo "  $SHARE_DIR/prompt.txt"

if ! sudo -v; then
    error "Не удалось получить права sudo."
    exit 1
fi

sudo install -d -m 0755 -- "$BIN_DIR"
sudo install -d -m 0755 -- "$SHARE_DIR"

sudo install -m 0755 -- "$PROGRAM" \
    "$BIN_DIR/man-translate"

sudo install -m 0644 -- "$PROMPT" \
    "$SHARE_DIR/prompt.txt"


echo
echo "Установлено."
echo
echo "Программа:"
echo "    $BIN_DIR/man-translate"
echo
echo "Prompt:"
echo "    $SHARE_DIR/prompt.txt"
echo
echo "Использование:"
echo
echo "    man-translate scp"
echo
echo "Пользовательский prompt можно разместить здесь:"
echo
echo "    ~/.config/man-translate/prompt.txt"
echo
