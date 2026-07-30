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

#
# Базовый каталог, куда устанавливаются русские man-страницы.
# Должен совпадать с LANG_DIR в man-translate.sh.
#
LANG_DIR="$PREFIX/share/man/ru"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PROGRAM="$SCRIPT_DIR/man-translate.sh"
PROMPT="$SCRIPT_DIR/prompt.txt"

#
# Каталог с готовыми переводами внутри репозитория.
#
TRANSLATIONS_DIR="$SCRIPT_DIR/translations"


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


#
# ============================================================
# Установка готовых переводов из каталога translations
# ============================================================
#
# Если в репозитории есть каталог translations с переводами,
# предлагаем установить их в систему.
#
# Структура каталога:
#
#   translations/
#   └── ru/
#       ├── man1/
#       │   └── scp.1
#       └── man5/
#           └── rpc.5
#
# Файлы хранятся НЕсжатыми (чистый roff). При установке
# каждый файл сжимается gzip-ом и копируется в
#   /usr/local/share/man/ru/manN/имя.N.gz
# аналогично тому, как это делает man-translate.sh.
#


#
# install_one_translation <путь-к-файлу> <секция> <имя-файла>
#
# Проверяет roff, сжимает и устанавливает одну страницу.
# Возвращает 0 при успехе, 1 при ошибке (страница пропускается).
#
install_one_translation()
{
    local src="$1"
    local section="$2"
    local filename="$3"

    local target_dir="$LANG_DIR/man$section"
    local target="$target_dir/${filename}.gz"

    # Проверка синтаксиса roff перед установкой.
    # Битые страницы не устанавливаем, чтобы не сломать man.
    if ! groff -mandoc -Tutf8 -- "$src" >/dev/null 2>&1; then
        error "Ошибка roff, страница пропущена: $src"
        return 1
    fi

    # Временный файл под сжатую страницу.
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/man-translate-install.XXXXXX.gz")

    if ! gzip -9 -c -- "$src" > "$tmp"; then
        error "Не удалось сжать: $src"
        rm -f -- "$tmp"
        return 1
    fi

    sudo install -d -m 0755 -- "$target_dir"
    sudo install -m 0644 -- "$tmp" "$target"

    rm -f -- "$tmp"

    echo "  Установлено: $target"
    return 0
}


#
# Основная логика установки переводов.
#

if [[ -d "$TRANSLATIONS_DIR" ]]; then

    #
    # Собираем список всех переводов.
    #
    # Ищем обычные файлы внутри translations/<lang>/man<N>/.
    # Используем find + while-read с разделителем NUL,
    # чтобы корректно обрабатывать любые имена.
    #
    translations=()

    while IFS= read -r -d '' f; do
        translations+=("$f")
    done < <(
        find "$TRANSLATIONS_DIR" \
            -type f \
            -path '*/man*/*' \
            -print0 \
        | sort -z
    )

    if [[ ${#translations[@]} -eq 0 ]]; then
        echo
        echo "Каталог translations найден, но переводов в нём нет."
    else
        echo
        echo "================================================="
        echo "Найдены готовые переводы (${#translations[@]}):"
        echo "================================================="
        echo

        # Показываем список в удобочитаемом виде: язык / секция / имя.
        for f in "${translations[@]}"; do
            # Пример пути:
            #   .../translations/ru/man1/scp.1
            # Вырезаем часть после каталога translations,
            # чтобы показать компактный относительный путь.
            rel="${f#"$TRANSLATIONS_DIR"/}"
            echo "  $rel"
        done

        echo
        read -rp "Установить эти переводы в систему? (y/N): " answer

        if [[ "$answer" == "y" ]]; then

            # Права sudo уже получены выше (sudo -v),
            # но кэш мог истечь — обновим на всякий случай.
            if ! sudo -v; then
                error "Не удалось получить права sudo."
                exit 1
            fi

            echo
            echo "Установка переводов..."
            echo

            installed=0
            skipped=0

            for f in "${translations[@]}"; do
                # Извлекаем имя файла и секцию из пути.
                #
                #   translations/ru/man1/scp.1
                #                  ^^^^  ^^^^^
                #                  dir   filename
                #
                # Секцию берём из имени каталога manN,
                # а не из расширения файла — это надёжнее
                # (например, для страниц вида foo.3posix).

                filename=$(basename "$f")

                # Каталог верхнего уровня: man1, man5, man3posix и т.д.
                mandir=$(basename "$(dirname "$f")")

                # Убираем префикс "man" -> получаем номер секции.
                section="${mandir#man}"

                if [[ -z "$section" || "$mandir" == "$section" ]]; then
                    error "Не удалось определить секцию для: $f"
                    skipped=$((skipped + 1))
                    continue
                fi

                if install_one_translation "$f" "$section" "$filename"; then
                    installed=$((installed + 1))
                else
                    skipped=$((skipped + 1))
                fi
            done

            echo
            echo "Итог установки переводов:"
            echo "  Установлено: $installed"
            echo "  Пропущено:   $skipped"

            #
            # Обновляем базу man один раз в конце,
            # после установки всех страниц.
            #
            if [[ "$installed" -gt 0 ]]; then
                echo
                echo "Обновление базы man..."

                if ! command -v mandb >/dev/null 2>&1; then
                    echo "Предупреждение: команда mandb не найдена."
                    echo "Обновите базу вручную после установки mandb."
                elif ! sudo mandb -q; then
                    echo "Предупреждение: не удалось обновить базу mandb."
                    echo "Выполните вручную: sudo mandb -q"
                fi
            fi
        else
            echo "Переводы не установлены."
        fi
    fi
fi


echo
echo "Использование:"
echo
echo "    man-translate scp"
echo
echo "Пользовательский prompt можно разместить здесь:"
echo
echo "    ~/.config/man-translate/prompt.txt"
echo

