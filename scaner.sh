#!/bin/bash

# project_scanner.sh - Скрипт для подготовки проекта к анализу LLM

set -euo pipefail

# Конфигурация по умолчанию
OUTPUT_FILE="project_analysis.md"
MAX_FILE_SIZE=50000  # Максимальный размер файла в байтах
INCLUDE_EXTENSIONS="py js ts jsx tsx php java c cpp h cs go rs rb swift kt scala sh bash zsh fish ps1 html css scss sass less vue svelte md txt yml yaml json xml toml cfg ini conf config Dockerfile docker-compose"

# ------------------------- ИСКЛЮЧАЕМЫЕ ДИРЕКТОРИИ --------------------------------------------------
EXCLUDE_DIRS=".git .svn node_modules .next dist build coverage .pytest_cache __pycache__ .venv venv env .env target .idea .vscode .angular diagrams SvgIcons"

# ------------------------- ИСКЛЮЧАЕМЫЕ ФАЙЛЫ --------------------------------------------------
EXCLUDE_FILES="
.gitignore .gitkeep .DS_Store thumbs.db snapshot.jsonl 
collect_files.sh package-lock.json prompt.ts project_scanner.ps1 
README.md scaner.sh nodemon.json openapi.ts project_analysis.md
"  # Исключаемые файлы по умолчанию

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция помощи
show_help() {
    cat << EOF
Использование: $0 [ОПЦИИ] [ДИРЕКТОРИЯ]

Сканирует проект и создает файл, оптимизированный для анализа LLM.

ОПЦИИ:
    -o, --output FILE       Выходной файл (по умолчанию: $OUTPUT_FILE)
    -s, --max-size SIZE     Максимальный размер файла в байтах (по умолчанию: $MAX_FILE_SIZE)
    -e, --exclude DIRS      Дополнительные исключаемые директории
    -i, --include EXTS      Дополнительные расширения файлов
    -f, --exclude-files     Исключаемые файлы (по имени или пути)
    --exclude-file-list     Файл со списком исключаемых файлов (по одному на строку)
    -h, --help              Показать эту справку
    --tree-only             Создать только дерево проекта
    --no-content            Не включать содержимое файлов
    --stats                 Показать статистику проекта

ПРИМЕРЫ:
    $0                                    # Сканировать текущую директорию
    $0 /path/to/project                   # Сканировать указанную директорию
    $0 -o analysis.txt                    # Сохранить в указанный файл
    $0 -f "prompt.md .env config.local"   # Исключить конкретные файлы
    $0 --exclude-file-list exclude.txt    # Исключить файлы из списка
    $0 --tree-only                        # Создать только структуру проекта

ИСКЛЮЧЕНИЕ ФАЙЛОВ:
    Файлы можно исключать по точному имени (например, ".gitignore") или по 
    относительному пути от корня проекта (например, "src/config.local.js").
    
    Поддерживаются простые паттерны:
    - "*.log" исключит все .log файлы
    - "temp/*" исключит все файлы в директории temp
    - "**/node_modules" исключит node_modules в любой поддиректории

EOF
}

# Парсинг аргументов
TREE_ONLY=false
NO_CONTENT=false
SHOW_STATS=false
PROJECT_DIR="."
EXCLUDE_FILE_LIST=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -s|--max-size)
            MAX_FILE_SIZE="$2"
            shift 2
            ;;
        -e|--exclude)
            EXCLUDE_DIRS="$EXCLUDE_DIRS $2"
            shift 2
            ;;
        -i|--include)
            INCLUDE_EXTENSIONS="$INCLUDE_EXTENSIONS $2"
            shift 2
            ;;
        -f|--exclude-files)
            EXCLUDE_FILES="$EXCLUDE_FILES $2"
            shift 2
            ;;
        --exclude-file-list)
            EXCLUDE_FILE_LIST="$2"
            shift 2
            ;;
        --tree-only)
            TREE_ONLY=true
            shift
            ;;
        --no-content)
            NO_CONTENT=true
            shift
            ;;
        --stats)
            SHOW_STATS=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo -e "${RED}Неизвестная опция: $1${NC}" >&2
            exit 1
            ;;
        *)
            PROJECT_DIR="$1"
            shift
            ;;
    esac
done

# Загрузка списка исключаемых файлов из файла
if [[ -n "$EXCLUDE_FILE_LIST" && -f "$EXCLUDE_FILE_LIST" ]]; then
    echo -e "${BLUE}Загружается список исключаемых файлов из: $EXCLUDE_FILE_LIST${NC}" >&2
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Пропускаем пустые строки и комментарии
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        EXCLUDE_FILES="$EXCLUDE_FILES $line"
    done < "$EXCLUDE_FILE_LIST"
fi

# Проверка существования директории
if [[ ! -d "$PROJECT_DIR" ]]; then
    echo -e "${RED}Ошибка: Директория '$PROJECT_DIR' не существует${NC}" >&2
    exit 1
fi

# Создание списков для find
EXCLUDE_FIND_ARGS=""
for dir in $EXCLUDE_DIRS; do
    EXCLUDE_FIND_ARGS="$EXCLUDE_FIND_ARGS -name '$dir' -prune -o"
done

INCLUDE_FIND_ARGS=""
for ext in $INCLUDE_EXTENSIONS; do
    if [[ -z "$INCLUDE_FIND_ARGS" ]]; then
        INCLUDE_FIND_ARGS="-name '*.$ext'"
    else
        INCLUDE_FIND_ARGS="$INCLUDE_FIND_ARGS -o -name '*.$ext'"
    fi
done

# Функция для проверки, должен ли файл быть исключен
should_exclude_file() {
    local file="$1"
    local relative_path="${file#$PROJECT_DIR/}"
    local basename_file=$(basename "$file")
    
    # Проверяем каждый паттерн исключения
    for pattern in $EXCLUDE_FILES; do
        # Убираем кавычки если они есть
        pattern=$(echo "$pattern" | sed 's/^["'\'']*//;s/["'\'']*$//')
        
        # Проверка по точному имени файла
        if [[ "$basename_file" == "$pattern" ]]; then
            return 0  # исключить
        fi
        
        # Проверка по относительному пути
        if [[ "$relative_path" == "$pattern" ]]; then
            return 0  # исключить
        fi
        
        # Проверка по паттерну с wildcards
        if [[ "$basename_file" == $pattern ]]; then
            return 0  # исключить
        fi
        
        if [[ "$relative_path" == $pattern ]]; then
            return 0  # исключить
        fi
        
        # Проверка паттернов типа "dir/*"
        if [[ "$pattern" == *"/*" ]]; then
            local dir_pattern="${pattern%/*}"
            if [[ "$relative_path" == $dir_pattern/* ]]; then
                return 0  # исключить
            fi
        fi
        
        # Проверка паттернов типа "**/pattern"
        if [[ "$pattern" == "**/"* ]]; then
            local file_pattern="${pattern#**/}"
            if [[ "$relative_path" == *"/$file_pattern" || "$basename_file" == "$file_pattern" ]]; then
                return 0  # исключить
            fi
        fi
    done
    
    return 1  # не исключать
}

# Функция для создания дерева проекта
create_project_tree() {
    echo -e "# СТРУКТУРА ПРОЕКТА\n\`\`\`plain"

    if command -v tree >/dev/null 2>&1; then
        # Создаем аргументы исключения для tree
        TREE_EXCLUDE=""
        for dir in $EXCLUDE_DIRS; do
            TREE_EXCLUDE="$TREE_EXCLUDE -I '$dir'"
        done

        eval "tree '$PROJECT_DIR' $TREE_EXCLUDE -a --charset=ascii" 2>/dev/null || {
            echo "Используется упрощенное дерево (tree недоступен с нужными опциями):"
            find "$PROJECT_DIR" -type f | head -50 | sed 's|^|  |'
        }
    else
        echo "Структура проекта (упрощенная):"
        eval "find '$PROJECT_DIR' $EXCLUDE_FIND_ARGS -type f \( $INCLUDE_FIND_ARGS \) -print" | \
        while IFS= read -r file; do
            if ! should_exclude_file "$file"; then
                echo "$file"
            fi
        done | \
        head -50 | \
        sed "s|^$PROJECT_DIR/||" | \
        sort | \
        sed 's|^|  |'
    fi

    echo
    echo -e "\`\`\`\n---"
    echo
}

# Функция для получения статистики
get_project_stats() {
    local total_files=0
    local total_lines=0
    local excluded_files=0

    echo "# СТАТИСТИКА ПРОЕКТА"
    echo

    # Подсчет файлов по расширениям
    declare -A ext_count
    declare -A ext_lines

    while IFS= read -r -d '' file; do
        if [[ -f "$file" && $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0) -le $MAX_FILE_SIZE ]]; then
            
            # Проверяем, не исключен ли файл
            if should_exclude_file "$file"; then
                excluded_files=$((excluded_files + 1))
                continue
            fi
            
            ext="${file##*.}"
            [[ "$file" == *.* ]] || ext="no-extension"

            ext_count["$ext"]=$((${ext_count["$ext"]:-0} + 1))

            if [[ -r "$file" ]]; then
                lines=$(wc -l < "$file" 2>/dev/null || echo 0)
                ext_lines["$ext"]=$((${ext_lines["$ext"]:-0} + lines))
                total_lines=$((total_lines + lines))
            fi

            total_files=$((total_files + 1))
        fi
    done < <(eval "find '$PROJECT_DIR' $EXCLUDE_FIND_ARGS -type f \( $INCLUDE_FIND_ARGS \) -print0")

    echo "Общее количество файлов: $total_files"
    echo "Исключено файлов: $excluded_files"
    echo "Общее количество строк: $total_lines"
    echo
    echo "Распределение по типам файлов:"

    for ext in $(printf '%s\n' "${!ext_count[@]}" | sort); do
        printf "  %-15s: %5d файлов, %8d строк\n" "$ext" "${ext_count[$ext]}" "${ext_lines[$ext]}"
    done

    echo
    echo "---"
    echo
}

# Функция для обработки файла
process_file() {
    local file="$1"
    local relative_path="${file#$PROJECT_DIR/}"

    # Проверка размера файла
    local file_size
    file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)

    if [[ $file_size -gt $MAX_FILE_SIZE ]]; then
        echo "## $relative_path"
        echo
        echo "*Файл слишком большой ($file_size байт), показаны только первые строки:*"
        echo
        echo '```'
        head -50 "$file" 2>/dev/null || echo "[Не удается прочитать файл]"
        echo '```'
        echo
        echo "---"
        echo
        return
    fi

    # Определение типа файла для подсветки синтаксиса
    local lang=""
    case "${file##*.}" in
        py) lang="python" ;;
        js|jsx) lang="javascript" ;;
        ts|tsx) lang="typescript" ;;
        php) lang="php" ;;
        java) lang="java" ;;
        c|h) lang="c" ;;
        cpp|cc|cxx) lang="cpp" ;;
        cs) lang="csharp" ;;
        go) lang="go" ;;
        rs) lang="rust" ;;
        rb) lang="ruby" ;;
        swift) lang="swift" ;;
        kt) lang="kotlin" ;;
        scala) lang="scala" ;;
        sh|bash) lang="bash" ;;
        html) lang="html" ;;
        css) lang="css" ;;
        scss|sass) lang="scss" ;;
        vue) lang="vue" ;;
        json) lang="json" ;;
        xml) lang="xml" ;;
        yml|yaml) lang="yaml" ;;
        md) lang="markdown" ;;
        sql) lang="sql" ;;
        Dockerfile) lang="dockerfile" ;;
        *) lang="" ;;
    esac

    echo "## $relative_path"
    echo

    if [[ -r "$file" ]]; then
        echo "\`\`\`$lang"
        cat "$file" 2>/dev/null || echo "[Не удается прочитать файл]"
        echo '```'
    else
        echo "*Файл недоступен для чтения*"
    fi

    echo
    echo "---"
    echo
}

# Основная функция
main() {
    echo -e "${BLUE}Сканирование проекта: $PROJECT_DIR${NC}"
    echo -e "${BLUE}Выходной файл: $OUTPUT_FILE${NC}"
    
    if [[ -n "$EXCLUDE_FILES" ]]; then
        echo -e "${YELLOW}Исключаемые файлы: $EXCLUDE_FILES${NC}"
    fi
    echo

    # Создание выходного файла
    {
        echo  "# АНАЛИЗ ПРОЕКТА"
        # echo
        # echo "**Проект:** $(basename "$(realpath "$PROJECT_DIR")")"
        # echo "**Дата сканирования:** $(date)"
        # echo "**Сканированная директория:** $(realpath "$PROJECT_DIR")"
        
        # if [[ -n "$EXCLUDE_FILES" ]]; then
        #     echo "**Исключенные файлы:** $EXCLUDE_FILES"
        # fi
        
        echo
        echo "---"
        echo

        # Статистика (если запрошена)
        if [[ "$SHOW_STATS" == true ]]; then
            get_project_stats
        fi

        # Дерево проекта
        create_project_tree

        # Содержимое файлов (если не отключено)
        if [[ "$TREE_ONLY" == false && "$NO_CONTENT" == false ]]; then
            echo "# СОДЕРЖИМОЕ ФАЙЛОВ"
            echo

            local file_count=0
            local excluded_count=0
            
            while IFS= read -r -d '' file; do
                if [[ -f "$file" ]]; then
                    # Проверяем, не исключен ли файл
                    if should_exclude_file "$file"; then
                        excluded_count=$((excluded_count + 1))
                        echo -e "${RED}Исключен: ${file#$PROJECT_DIR/}${NC}" >&2
                        continue
                    fi
                    
                    echo -e "${YELLOW}Обработка: ${file#$PROJECT_DIR/}${NC}" >&2
                    process_file "$file"
                    file_count=$((file_count + 1))
                fi
            done < <(eval "find '$PROJECT_DIR' $EXCLUDE_FIND_ARGS -type f \( $INCLUDE_FIND_ARGS \) -print0" | sort -z)

            echo -e "${GREEN}Обработано файлов: $file_count${NC}" >&2
            if [[ $excluded_count -gt 0 ]]; then
                echo -e "${YELLOW}Исключено файлов: $excluded_count${NC}" >&2
            fi
        fi

    } > "$OUTPUT_FILE"

    echo -e "${GREEN}✓ Анализ завершен!${NC}"
    echo -e "${GREEN}✓ Результат сохранен в: $OUTPUT_FILE${NC}"

    # Показать размер выходного файла
    local output_size
    output_size=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null || echo 0)
    echo -e "${BLUE}Размер файла: $(numfmt --to=iec $output_size 2>/dev/null || echo "$output_size байт")${NC}"
}

# Запуск основной функции
main