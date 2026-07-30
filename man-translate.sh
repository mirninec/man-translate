#!/usr/bin/env bash
#
# man-translate
#
# Подготовка русской man-страницы для перевода LLM.
#
# Версия: 0.5
#

set -euo pipefail

VERSION="0.5"

WORKDIR="$HOME/man-ru-translate"
LANG_DIR="/usr/local/share/man/ru"

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

#
# Определение каталога репозитория с переводами.
#
# После установки скрипт лежит в /usr/local/bin и оторван
# от git-клона, поэтому вычислять путь от SCRIPT_DIR нельзя.
# Путь к репозиторию задаётся явно, по приоритету:
#
#   1. Переменная окружения MAN_TRANSLATE_REPO.
#   2. Строка REPO=... в ~/.config/man-translate/config.
#   3. Каталог translations рядом со скриптом
#      (актуально при запуске прямо из клона до установки).
#
CONFIG_FILE="$HOME/.config/man-translate/config"

REPO_DIR=""

if [[ -n "${MAN_TRANSLATE_REPO:-}" ]]; then
    # Высший приоритет: переменная окружения.
    REPO_DIR="$MAN_TRANSLATE_REPO"

elif [[ -f "$CONFIG_FILE" ]]; then
    # Читаем строку вида: REPO=/home/user/man-translate
    # grep берёт первую строку REPO=, cut отрезает значение.
    # Кавычки по краям значения (если есть) убираем через sed.
    REPO_DIR=$(
        grep -E '^REPO=' "$CONFIG_FILE" \
        | head -n1 \
        | cut -d= -f2- \
        | sed -e 's/^"//' -e 's/"$//'
    )
fi

# Запасной вариант: запуск из клона репозитория.
if [[ -z "$REPO_DIR" && -d "$SCRIPT_DIR/translations" ]]; then
    REPO_DIR="$SCRIPT_DIR"
fi

# Итоговый каталог с переводами внутри репозитория
# (пустой, если репозиторий определить не удалось).
if [[ -n "$REPO_DIR" ]]; then
    REPO_TRANSLATIONS_DIR="$REPO_DIR/translations"
else
    REPO_TRANSLATIONS_DIR=""
fi


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


#
# Проверка зависимостей
#
# Определена рано, так как используется в do_sync,
# который вызывается из диспетчера подкоманд ниже.
#

require_command()
{
    if ! command -v "$1" >/dev/null 2>&1; then
        error "Не найдена команда: $1"
        exit 1
    fi
}


#
# ============================================================
# Синхронизация переводов с удалённым репозиторием
# ============================================================
#
# Команда: man-translate sync
#
# Двусторонняя синхронизация:
#   1. Забираем новые переводы с remote (git pull --ff-only)
#      и устанавливаем изменившиеся страницы в систему.
#   2. Показываем локальные коммиты, которых нет на remote,
#      и предлагаем их запушить.
#
# Принципы безопасности:
#   - только неразрушающие git-операции;
#   - pull строго --ff-only (без авто-merge/rebase);
#   - при расхождении историй или "грязном" дереве —
#     останавливаемся и просим разрулить вручную;
#   - все действия подтверждаются (по умолчанию "нет").
#

#
# Установка одной страницы из репозитория в систему.
# Аналог логики в install.sh: проверка roff, gzip, install.
#
# Аргументы: <путь-к-файлу> <секция> <имя-файла>
#
sync_install_page()
{
    local src="$1"
    local section="$2"
    local filename="$3"

    local target_dir="$LANG_DIR/man$section"
    local target="$target_dir/${filename}.gz"

    if ! groff -mandoc -Tutf8 -- "$src" >/dev/null 2>&1; then
        error "Ошибка roff, страница пропущена: $src"
        return 1
    fi

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/man-translate-sync.XXXXXX.gz")

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
# Устанавливает в систему все страницы, изменившиеся между
# двумя git-ревизиями (old..new) внутри каталога translations.
#
# Аргументы: <старая-ревизия> <новая-ревизия>
#
sync_install_changed()
{
    local old="$1"
    local new="$2"

    # Относительный путь каталога translations внутри репозитория.
    # git diff отдаёт пути относительно корня репозитория,
    # поэтому фильтруем по 'translations/'.
    local changed
    changed=$(
        git -C "$REPO_DIR" diff --name-only --diff-filter=ACMR \
            "$old" "$new" -- translations/ 2>/dev/null || true
    )

    if [[ -z "$changed" ]]; then
        warn "Изменившихся файлов переводов не обнаружено."
        return 0
    fi

    echo
    msg "Установка обновлённых переводов в систему..."

    if ! sudo -v; then
        error "Не удалось получить права sudo."
        return 1
    fi

    local installed=0
    local skipped=0
    local rel abs filename mandir section

    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue

        abs="$REPO_DIR/$rel"

        # Файл мог быть удалён — устанавливаем только существующие.
        if [[ ! -f "$abs" ]]; then
            continue
        fi

        filename=$(basename "$rel")
        mandir=$(basename "$(dirname "$rel")")
        section="${mandir#man}"

        if [[ -z "$section" || "$mandir" == "$section" ]]; then
            error "Не удалось определить секцию для: $rel"
            skipped=$((skipped + 1))
            continue
        fi

        if sync_install_page "$abs" "$section" "$filename"; then
            installed=$((installed + 1))
        else
            skipped=$((skipped + 1))
        fi
    done <<< "$changed"

    echo
    echo "Установлено: $installed, пропущено: $skipped"

    if [[ "$installed" -gt 0 ]]; then
        echo
        msg "Обновление базы man..."
        if ! sudo mandb -q; then
            warn "Не удалось обновить mandb. Выполните: sudo mandb -q"
        fi
    fi
}


do_sync()
{
    # Проверка зависимостей, нужных именно для sync.
    require_command git
    require_command groff
    require_command gzip
    require_command mandb
    require_command sudo
    require_command mktemp
    require_command install

    # Репозиторий должен быть определён.
    if [[ -z "$REPO_DIR" ]]; then
        error "Репозиторий переводов не настроен."
        error "См. настройку REPO в ~/.config/man-translate/config"
        error "или переменную MAN_TRANSLATE_REPO."
        exit 1
    fi

    # Каталог должен быть git-репозиторием.
    if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree \
            >/dev/null 2>&1; then
        error "Каталог не является git-репозиторием:"
        error "  $REPO_DIR"
        exit 1
    fi

    # Рабочее дерево не должно быть "грязным":
    # незакоммиченные правки в translations/ мешают
    # безопасному pull/push.
    if [[ -n "$(git -C "$REPO_DIR" status --porcelain -- translations/)" ]]
    then
        error "В каталоге translations есть незакоммиченные изменения."
        error "Закоммитьте или отмените их перед синхронизацией:"
        error "  git -C $REPO_DIR status"
        exit 1
    fi

    msg "Репозиторий:"
    echo "  $REPO_DIR"
    echo

    # Определяем имя текущей ветки.
    local branch
    branch=$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)

    # Проверяем, что у ветки настроен upstream (remote-ветка).
    if ! git -C "$REPO_DIR" rev-parse --abbrev-ref \
            --symbolic-full-name '@{upstream}' >/dev/null 2>&1
    then
        error "Для ветки '$branch' не настроен upstream (remote)."
        error "Настройте, например:"
        error "  git -C $REPO_DIR push -u origin $branch"
        exit 1
    fi

    # Забираем свежую информацию с remote (без изменения файлов).
    msg "Получение данных с remote (git fetch)..."
    if ! git -C "$REPO_DIR" fetch; then
        error "Не удалось выполнить git fetch."
        error "Проверьте сеть и доступ к репозиторию."
        exit 1
    fi

    # Ревизии: локальная, удалённая и точка их расхождения.
    local local_rev remote_rev base_rev
    local_rev=$(git -C "$REPO_DIR" rev-parse @)
    remote_rev=$(git -C "$REPO_DIR" rev-parse '@{upstream}')
    base_rev=$(git -C "$REPO_DIR" merge-base @ '@{upstream}')

    #
    # Четыре возможных состояния:
    #
    #   local == remote          -> всё синхронизировано
    #   local == base            -> remote ушёл вперёд (нужен pull)
    #   remote == base           -> мы ушли вперёд (нужен push)
    #   иначе                    -> истории разошлись (diverged)
    #

    if [[ "$local_rev" == "$remote_rev" ]]; then
        msg "Всё синхронизировано с remote. Новых переводов нет."
        return 0
    fi

    # --- Входящие изменения (remote -> локально) ---

    if [[ "$local_rev" == "$base_rev" ]]; then
        echo
        msg "На remote есть новые переводы:"
        echo

        git -C "$REPO_DIR" diff --name-only --diff-filter=ACMR \
            "$local_rev" "$remote_rev" -- translations/ \
        | sed 's/^/  /'

        echo
        read -rp "Загрузить их и установить? (y/N): " ans

        if [[ "$ans" == "y" ]]; then
            msg "Загрузка (git pull --ff-only)..."

            if git -C "$REPO_DIR" pull --ff-only; then
                sync_install_changed "$local_rev" "$remote_rev"
            else
                error "git pull --ff-only не удался."
                error "Возможно, истории разошлись — разрулите вручную."
            fi
        else
            echo "Загрузка отменена."
        fi

        return 0
    fi

    # --- Исходящие изменения (локально -> remote) ---

    if [[ "$remote_rev" == "$base_rev" ]]; then
        echo
        msg "На этой машине есть переводы, которых нет на remote:"
        echo

        git -C "$REPO_DIR" diff --name-only --diff-filter=ACMR \
            "$remote_rev" "$local_rev" -- translations/ \
        | sed 's/^/  /'

        echo
        read -rp "Залить их на remote (git push)? (y/N): " ans

        if [[ "$ans" == "y" ]]; then
            msg "Отправка (git push)..."

            if git -C "$REPO_DIR" push; then
                msg "Изменения запушены."
            else
                error "git push не удался."
                error "Проверьте сеть, доступ и аутентификацию."
            fi
        else
            echo "Отправка отменена."
        fi

        return 0
    fi

    # --- Истории разошлись ---

    error "Локальная и удалённая истории разошлись."
    error "Автоматическая синхронизация небезопасна."
    error "Разрулите вручную, например:"
    error "  git -C $REPO_DIR pull --rebase"
    error "  git -C $REPO_DIR push"
    exit 1
}


usage()
{
    cat <<EOF

Использование:

    $SCRIPT_NAME <сущность>       Перевести и установить man-страницу.
    $SCRIPT_NAME sync             Синхронизировать переводы с remote.

Примеры:

    $SCRIPT_NAME scp
    $SCRIPT_NAME printf
    $SCRIPT_NAME rpc
    $SCRIPT_NAME sync

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
    sync)
        # Подкоманда синхронизации с remote.
        # Обрабатывается отдельно и завершает работу скрипта.
        do_sync
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
# Сохранение перевода в репозиторий проекта
#
# Копируем НЕсжатый перевод (чистый roff) в каталог
# translations/ru/manN/имя.N внутри репозитория.
#
# Хранение в несжатом виде удобно для git:
#   - видны нормальные диффы;
#   - переводы можно закоммитить и запушить;
#   - при переустановке системы install.sh их восстановит.
#
# Путь к репозиторию определён выше (REPO_TRANSLATIONS_DIR).
# Если он не задан — шаг пропускается с подсказкой,
# как настроить репозиторий.
#

if [[ -n "$REPO_TRANSLATIONS_DIR" ]]; then

    REPO_TARGET_DIR="$REPO_TRANSLATIONS_DIR/ru/man$SECTION"
    REPO_TARGET="$REPO_TARGET_DIR/${NAME}.${SECTION}"

    if mkdir -p "$REPO_TARGET_DIR" 2>/dev/null; then
        # cp без sudo: репозиторий принадлежит пользователю.
        cp -- "$OUTFILE" "$REPO_TARGET"

        msg "Перевод сохранён в репозиторий:"
        echo "  $REPO_TARGET"
        echo

        #
        # Предложение закоммитить и запушить изменения.
        #
        # Действуем осторожно:
        #   - git должен быть установлен;
        #   - REPO_DIR должен быть git-репозиторием;
        #   - в индекс добавляем ТОЛЬКО файл перевода,
        #     а не 'git add .' (чтобы не захватить чужие правки);
        #   - ошибки push не роняют скрипт (set -e обходим).
        #

        git_hint()
        {
            # Показывается, когда авто-commit невозможен
            # или пользователь отказался.
            warn "Не забудьте закоммитить и запушить:"
            echo "  cd $REPO_DIR"
            echo "  git add translations/"
            echo "  git commit -m 'Add translation: ${NAME}.${SECTION}'"
            echo "  git push"
            echo
        }

        if ! command -v git >/dev/null 2>&1; then
            warn "git не установлен — изменения не закоммичены."
            git_hint

        elif ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree \
                >/dev/null 2>&1; then
            warn "Каталог репозитория не является git-репозиторием:"
            warn "  $REPO_DIR"
            git_hint

        else
            read -rp "Закоммитить и запушить изменения? (y/N): " git_answer

            if [[ "$git_answer" == "y" ]]; then

                msg "Коммит изменений..."

                # Добавляем только этот файл перевода.
                # git -C выполняет команду в каталоге репозитория,
                # не меняя текущий каталог скрипта.
                if git -C "$REPO_DIR" add -- "$REPO_TARGET"; then

                    # Коммитим. Если коммитить нечего
                    # (файл не изменился), git commit вернёт
                    # ненулевой код — обрабатываем это мягко.
                    if git -C "$REPO_DIR" commit \
                        -m "Add translation: ${NAME}.${SECTION}"
                    then
                        msg "Коммит создан."

                        msg "Push..."

                        if git -C "$REPO_DIR" push; then
                            msg "Изменения запушены."
                        else
                            warn "Не удалось выполнить push."
                            warn "Возможные причины: нет remote,"
                            warn "нет сети или требуется аутентификация."
                            warn "Выполните вручную: git -C $REPO_DIR push"
                        fi
                    else
                        warn "Коммит не создан"
                        warn "(возможно, нечего коммитить)."
                    fi
                else
                    error "Не удалось выполнить git add."
                    git_hint
                fi
            else
                git_hint
            fi
        fi
    else
        warn "Не удалось записать перевод в репозиторий:"
        warn "  $REPO_TARGET_DIR"
        warn "Проверьте права доступа к каталогу репозитория."
    fi

else
    warn "Репозиторий переводов не настроен —"
    warn "перевод только установлен в систему, но не сохранён в git."
    echo
    warn "Чтобы переводы сохранялись автоматически, укажите путь"
    warn "к клону репозитория одним из способов:"
    echo
    echo "  1) Переменная окружения (например, в ~/.bashrc):"
    echo "       export MAN_TRANSLATE_REPO=\"$HOME/man-translate\""
    echo
    echo "  2) Файл конфигурации ~/.config/man-translate/config:"
    echo "       REPO=$HOME/man-translate"
    echo
fi



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

