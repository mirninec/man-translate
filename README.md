# man-translate

`man-translate` — небольшая Bash-утилита для подготовки man-страниц GNU/Linux к переводу с помощью LLM и установки готового русского перевода в локальную man-базу.

Скрипт:

1. Находит исходную man-страницу.
2. Извлекает её исходный roff-текст.
3. Создаёт рабочий файл с prompt для LLM и текстом оригинала.
4. Ожидает, пока пользователь заменит содержимое файла готовым переводом.
5. Проверяет roff-разметку через `groff`.
6. Сжимает перевод и устанавливает его в:
   ```text
   /usr/local/share/man/ru/man<секция>/
   ```
7. Обновляет базу `man` через `mandb`.

Локальные переводы устанавливаются в `/usr/local/share/man`, а не в `/usr/share/man`, поэтому они не должны перезаписываться при обновлении системных пакетов.

---

## Возможности

- подготовка man-страницы для перевода LLM;
- поиск исходной страницы в locale `C`, чтобы не переводить уже установленный перевод;
- поддержка несжатых man-файлов и архивов:
  - `.gz`;
  - `.xz`;
  - `.bz2`;
  - `.zst`;
- проверка результата через `groff`;
- проверка, что файл действительно был изменён;
- защита от случайной установки файла с исходным prompt и служебными разделителями;
- установка с корректными правами `0644`;
- пользовательский prompt;
- установленный системный prompt;
- `--help` и `--version`.

---

## Требования

Скрипт рассчитан на GNU/Linux с `man-db`.

Необходимы следующие программы:

```text
bash
man
groff
gzip
sha256sum
mandb
sudo
mktemp
install
sed
awk
grep
```

Для man-страниц, сжатых альтернативными алгоритмами, могут также понадобиться:

```text
xz
bzip2
zstd
```

На Debian/Ubuntu базовые зависимости обычно можно установить так:

```bash
sudo apt install man-db groff gzip coreutils
```

На Arch Linux:

```bash
sudo pacman -S man-db groff gzip coreutils
```

---

## Установка

Клонируйте репозиторий:

```bash
git clone https://github.com/mirninec/man-translate.git
```

Перейдите в каталог проекта:

```bash
cd man-translate
```

Сделайте установщик исполняемым:

```bash
chmod +x install.sh
```

Установите программу:

```bash
./install.sh
```

Установщик разместит файлы в следующих местах:

```text
/usr/local/bin/man-translate
/usr/local/share/man-translate/prompt.txt
```

После этого команду можно запускать из любого каталога:

```bash
man-translate scp
```

---

## Использование

Общий вид команды:

```bash
man-translate <имя-man-страницы>
```

Примеры:

```bash
man-translate pwd
man-translate scp
man-translate printf
man-translate rpc
```

Справка:

```bash
man-translate --help
```

Версия:

```bash
man-translate --version
```

---

## Процесс перевода

Например, для перевода страницы `scp`:

```bash
man-translate scp
```

Скрипт найдёт исходную страницу и создаст рабочий файл, например:

```text
~/man-ru-translate/scp.1.ru
```

Далее:

1. Откройте созданный файл.
2. Скопируйте его содержимое.
3. Передайте текст LLM.
4. Попросите LLM перевести man-страницу на русский язык с сохранением roff-разметки.
5. Полностью замените содержимое рабочего файла ответом LLM.
6. Вернитесь в терминал и нажмите `Enter`.
7. Скрипт проверит roff-файл, сожмёт его, установит и обновит базу man-страниц.

После успешной установки перевод будет находиться примерно здесь:

```text
/usr/local/share/man/ru/man1/scp.1.gz
```

Проверка:

```bash
LANG=ru_RU.UTF-8 man scp
```

---

## Prompt для LLM

По умолчанию `man-translate` ищет `prompt.txt` в следующем порядке:

1. Пользовательский prompt:

   ```text
   ~/.config/man-translate/prompt.txt
   ```

2. `prompt.txt` рядом с запускаемым скриптом.

   Это удобно при запуске из каталога разработки:

   ```bash
   ./man-translate.sh scp
   ```

3. Системный prompt, установленный через `install.sh`:

   ```text
   /usr/local/share/man-translate/prompt.txt
   ```

4. Встроенный prompt.

Чтобы использовать собственный prompt:

```bash
mkdir -p ~/.config/man-translate
cp prompt.txt ~/.config/man-translate/prompt.txt
```

После этого отредактируйте файл:

```bash
nano ~/.config/man-translate/prompt.txt
```

Пользовательский prompt имеет наивысший приоритет.

---

## Русская locale

Для автоматического выбора русской man-страницы должна быть доступна русская locale:

```bash
locale -a | grep -i ru
```

Обычно требуется:

```text
ru_RU.utf8
```

Проверить, какой файл будет выбран:

```bash
LANG=ru_RU.UTF-8 man -aw scp
```

После установки локального перевода первым должен отображаться путь вида:

```text
/usr/local/share/man/ru/man1/scp.1.gz
```

Если русский каталог man-страниц не выбирается автоматически для `ru_RU.UTF-8`, можно создать символические ссылки:

```bash
sudo ln -s ru /usr/local/share/man/ru_RU
sudo ln -s ru /usr/local/share/man/ru_RU.UTF-8
sudo mandb -q
```

Проверка:

```bash
LANG=ru_RU.UTF-8 man scp
```

---

## Структура проекта

```text
.
├── install.sh
├── man-translate.sh
└── prompt.txt
```

| Файл | Назначение |
|---|---|
| `man-translate.sh` | Основной скрипт подготовки, проверки и установки перевода. |
| `install.sh` | Установщик программы в `/usr/local`. |
| `prompt.txt` | Prompt для LLM, используемый при подготовке перевода. |

---

## Удаление

Удалить установленную программу и системный prompt:

```bash
sudo rm -f /usr/local/bin/man-translate
sudo rm -rf /usr/local/share/man-translate
```

Локально установленные переводы находятся в:

```text
/usr/local/share/man/ru/
```

Чтобы удалить все переводы, установленные этой утилитой:

```bash
sudo rm -rf /usr/local/share/man/ru
sudo mandb -q
```

Рабочие файлы переводов находятся в:

```text
~/man-ru-translate/
```

Их можно удалить отдельно:

```bash
rm -rf ~/man-ru-translate
```

---

## Лицензия

Проект распространяется по лицензии [MIT](LICENSE).
