#!/bin/sh

API_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=30"
ARCHIVE_NAME="sing-box-latest.tar.gz"
DEST_FILE="/usr/bin/sing-box"

R="\033[1;31m"
G="\033[1;32m"
Y="\033[1;33m"
C="\033[1;36m"
N="\033[0m"

trap 'printf "\n${R}[!] Установка прервана.${N}\n"; [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"; [ "$SERVICE_STOPPED" = "1" ] && service "$SERVICE_NAME" start 2>/dev/null; exit 1' INT TERM

fail() {
    printf "${R}[!] ОШИБКА: %s${N}\n" "$1"
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    [ "$SERVICE_STOPPED" = "1" ] && service "$SERVICE_NAME" start 2>/dev/null
    exit 1
}

if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL --insecure --connect-timeout 15"
    DOWNLOAD="curl -fsSL --insecure --connect-timeout 15 -o"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO- --no-check-certificate --timeout=15"
    DOWNLOAD="wget -q --no-check-certificate --timeout=15 -O"
else
    printf "${R}[!] ОШИБКА: Не найден curl или wget.${N}\n"
    exit 1
fi

if [ -f "/opt/etc/init.d/podkop" ] || [ -f "/etc/init.d/podkop" ]; then
    SERVICE_NAME="podkop"
else
    SERVICE_NAME="sing-box"
fi

USE_PKG="0"
if [ -f "/etc/openwrt_release" ]; then
    if command -v apk >/dev/null 2>&1 && [ "$(command -v apk)" != "/opt/bin/apk" ]; then
        USE_PKG="1"
        PKG_MANAGER="apk"
        PKG_EXT="apk"
    elif command -v opkg >/dev/null 2>&1 && [ "$(command -v opkg)" != "/opt/bin/opkg" ]; then
        USE_PKG="1"
        PKG_MANAGER="opkg"
        PKG_EXT="ipk"
    fi
fi
HOST_ARCH=$(uname -m)

if [ -f "/etc/openwrt_release" ]; then
    DISTRIB_ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
    case "$DISTRIB_ARCH" in
        *mipsel* | *mipsle*) HOST_ARCH="mipsel" ;;
        *mips64el* | *mips64le*) HOST_ARCH="mips64el" ;;
    esac
fi

case $HOST_ARCH in
  aarch64)               ARCH_SUFFIX="arm64" ;;
  armv7*)                 ARCH_SUFFIX="armv7" ;;
  armv6*)                 ARCH_SUFFIX="armv6" ;;
  x86_64)                 ARCH_SUFFIX="amd64" ;;
  i386 | i686)            ARCH_SUFFIX="386" ;;
  mips)                   ARCH_SUFFIX="mips-softfloat" ;;
  mipsel | mipsle)        ARCH_SUFFIX="mipsle-softfloat" ;;
  mips64)                 ARCH_SUFFIX="mips64" ;;
  mips64el | mips64le)    ARCH_SUFFIX="mips64le" ;;
  riscv64)                ARCH_SUFFIX="riscv64" ;;
  s390x)                  ARCH_SUFFIX="s390x" ;;
  *)
    printf "${R}[!] ОШИБКА: Архитектура $HOST_ARCH не поддерживается.${N}\n"
    exit 1
    ;;
esac

CURRENT_VER=""
if [ -f "$DEST_FILE" ]; then
    CURRENT_VER=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
fi

printf "${C}[*] Получаю список последних версий...${N}\n"
API_RESPONSE=$($FETCH "$API_URL" 2>/dev/null) || true

if [ -z "$API_RESPONSE" ]; then
    fail "Не удалось подключиться к GitHub API. Проверьте соединение."
fi

RELEASES=$(echo "$API_RESPONSE" \
  | tr ',' '\n' \
  | grep '"tag_name"' \
  | awk -F '"' '{print $4}' \
  | grep -v -i "rc" \
  | grep -v -i "beta" \
  | grep -v -i "alpha" \
  | head -n 3)

if [ -z "$RELEASES" ]; then
    fail "Не удалось получить список стабильных релизов из API."
fi

printf "\n${C}[*] Доступные стабильные версии для установки:${N}\n"
i=1
for tag in $RELEASES; do
    printf "  ${Y}%d)${N} %s\n" "$i" "$tag"
    i=$((i+1))
done
printf "  ${Y}0)${N} Отмена\n"

printf "\n${C}[?] Выберите версию (0-$((i-1))): ${N}"
read -r choice

if [ "$choice" = "0" ] || [ -z "$choice" ]; then
    printf "${G}[*] Установка отменена.${N}\n"
    exit 0
fi

SELECTED_TAG=""
i=1
for tag in $RELEASES; do
    if [ "$choice" = "$i" ]; then
        SELECTED_TAG="$tag"
        break
    fi
    i=$((i+1))
done

if [ -z "$SELECTED_TAG" ]; then
    fail "Неверный выбор. Пожалуйста, введите корректный номер из списка."
fi

SELECTED_VER=$(echo "$SELECTED_TAG" | sed 's/^v//')

printf "\n${C}[?] Выберите тип сборки sing-box extended:${N}\n"
printf "  ${Y}1)${N} Стандартная (Standard)\n"
printf "  ${Y}2)${N} Сжатая (Compressed, UPX)\n"
printf "\n${C}[?] Ваш выбор (1-2, по умолчанию 1): ${N}"
read -r type_choice

if [ "$type_choice" = "2" ]; then
    ARCH_SUFX="-compressed"
    USE_PKG="0"
else
    ARCH_SUFX=""
fi

printf "\n${C}[*] Текущая: ${Y}${CURRENT_VER:-не установлен}${C} | Выбранная: ${Y}${SELECTED_VER}${N}\n"

if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$SELECTED_VER" ]; then
    printf "${Y}[!] Эта версия уже установлена. Выполняю переустановку...${N}\n"
fi

printf "${C}[*] Ищу ссылку на скачивание для версии $SELECTED_TAG...${N}\n"

RELEASE_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/tags/$SELECTED_TAG"
RELEASE_RESPONSE=$($FETCH "$RELEASE_URL" 2>/dev/null) || true

IS_PKG_INSTALL="0"
if [ "$USE_PKG" = "1" ]; then
    DISTRIB_ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
    FILE_PATTERN="sing-box-extended_.*_openwrt_${DISTRIB_ARCH}\.${PKG_EXT}"
    DOWNLOAD_URL=$(echo "$RELEASE_RESPONSE" \
      | tr ',' '\n' \
      | grep "browser_download_url" \
      | grep "$FILE_PATTERN" \
      | head -n 1 \
      | awk -F '"' '{print $4}')
    if [ -n "$DOWNLOAD_URL" ]; then
        IS_PKG_INSTALL="1"
    fi
fi

if [ "$IS_PKG_INSTALL" = "0" ]; then
    FILE_PATTERN="linux-$ARCH_SUFFIX${ARCH_SUFX}\.tar.gz"
    DOWNLOAD_URL=$(echo "$RELEASE_RESPONSE" \
      | tr ',' '\n' \
      | grep "browser_download_url" \
      | grep "$FILE_PATTERN" \
      | head -n 1 \
      | awk -F '"' '{print $4}')
fi

if [ -z "$DOWNLOAD_URL" ]; then
    fail "Файл для архитектуры '$HOST_ARCH' ($ARCH_SUFFIX${ARCH_SUFX} / ${DISTRIB_ARCH:-н/д}) не найден в релизе $SELECTED_TAG."
fi

# === ИЗМЕНЕНИЕ: Останавливаем службу ДО замеров памяти и скачивания ===
printf "${Y}[*] Освобождаю оперативную память (остановка $SERVICE_NAME)...${N}\n"
SERVICE_STOPPED="1"
service "$SERVICE_NAME" stop 2>/dev/null || true
sleep 2

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
# =====================================================================

if [ "$IS_PKG_INSTALL" = "1" ]; then
    ARCHIVE_NAME="sing-box-latest.${PKG_EXT}"
else
    ARCHIVE_NAME="sing-box-latest.tar.gz"
fi

REQ_TEMP_KB=40960
REQ_DEST_KB=25600

get_free_space_kb() {
    local space
    space=$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}')
    case "$space" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$space" ;;
    esac
}

DEST_DIR=$(dirname "$DEST_FILE")
DEST_FREE_KB=$(get_free_space_kb "$DEST_DIR")
EXISTING_SIZE_KB=0
if [ -f "$DEST_FILE" ]; then
    EXISTING_SIZE_KB=$(du -k "$DEST_FILE" 2>/dev/null | awk '{print $1}')
    case "$EXISTING_SIZE_KB" in
        ''|*[!0-9]*) EXISTING_SIZE_KB=0 ;;
    esac
fi
TOTAL_DEST_AVAILABLE=$((DEST_FREE_KB + EXISTING_SIZE_KB))

if [ "$TOTAL_DEST_AVAILABLE" -lt "$REQ_DEST_KB" ]; then
    fail "Недостаточно места в $DEST_DIR. Доступно: $((TOTAL_DEST_AVAILABLE / 1024)) МБ, требуется: $((REQ_DEST_KB / 1024)) МБ."
fi

FREE_RAM_KB=$(awk '/MemFree/ {print $2}' /proc/meminfo)
case "$FREE_RAM_KB" in
    ''|*[!0-9]*) FREE_RAM_KB=0 ;;
esac

HOME_DIR="${HOME:-/root}"
DIR_RAM="/tmp/sing-box-install"
DIR_DISK="$HOME_DIR/sing-box-install_tmp"

if [ "$FREE_RAM_KB" -gt 81920 ]; then
    PREF_DIR="$DIR_RAM"
    PREF_PARENT="/tmp"
    ALT_DIR="$DIR_DISK"
    ALT_PARENT="$HOME_DIR"
else
    PREF_DIR="$DIR_DISK"
    PREF_PARENT="$HOME_DIR"
    ALT_DIR="$DIR_RAM"
    ALT_PARENT="/tmp"
fi

WORK_DIR=""
PREF_FREE_KB=$(get_free_space_kb "$PREF_PARENT")
if [ "$PREF_FREE_KB" -ge "$REQ_TEMP_KB" ]; then
    WORK_DIR="$PREF_DIR"
else
    ALT_FREE_KB=$(get_free_space_kb "$ALT_PARENT")
    if [ "$ALT_FREE_KB" -ge "$REQ_TEMP_KB" ]; then
        WORK_DIR="$ALT_DIR"
    fi
fi

if [ -z "$WORK_DIR" ]; then
    RAM_FREE_MB=$(( $(get_free_space_kb "/tmp") / 1024 ))
    DISK_FREE_MB=$(( $(get_free_space_kb "$HOME_DIR") / 1024 ))
    fail "Недостаточно свободного места для установки. В /tmp (ОЗУ) доступно: ${RAM_FREE_MB} МБ, в $HOME_DIR (диск) доступно: ${DISK_FREE_MB} МБ. Требуется минимум: $((REQ_TEMP_KB / 1024)) МБ."
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" || fail "Не удалось создать временную директорию $WORK_DIR."
cd "$WORK_DIR" || fail "Не удалось перейти во временную директорию $WORK_DIR."

printf "${C}[*] Скачиваю и устанавливаю...${N}\n"
$DOWNLOAD "$ARCHIVE_NAME" "$DOWNLOAD_URL" || fail "Не удалось скачать файл."

if [ ! -s "$ARCHIVE_NAME" ]; then
    fail "Скачанный файл пустой."
fi

if [ "$IS_PKG_INSTALL" = "1" ]; then
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk del sing-box >/dev/null 2>&1 || true
        apk del sing-box-extended >/dev/null 2>&1 || true
        apk add --allow-untrusted "$ARCHIVE_NAME" || fail "Не удалось установить apk-пакет."
    else
        opkg remove sing-box 2>/dev/null || true
        opkg install --force-reinstall --force-overwrite "$ARCHIVE_NAME" || fail "Не удалось установить ipk-пакет."
    fi
    rm -f "$ARCHIVE_NAME"

    if [ ! -f "$DEST_FILE" ]; then
        for path in /usr/bin/sing-box-extended /usr/sbin/sing-box-extended /usr/sbin/sing-box; do
            if [ -f "$path" ]; then
                ln -sf "$path" "$DEST_FILE"
                break
            fi
        done
    fi

    if [ "$SERVICE_NAME" = "podkop" ]; then
        service sing-box stop >/dev/null 2>&1 || true
        service sing-box disable >/dev/null 2>&1 || true
        service sing-box-extended stop >/dev/null 2>&1 || true
        service sing-box-extended disable >/dev/null 2>&1 || true
    fi
else
    tar -xzf "$ARCHIVE_NAME" || fail "Не удалось распаковать архив."
    rm -f "$ARCHIVE_NAME"

    BINARY_PATH=$(find . -type f -name sing-box | head -n 1)
    if [ -z "$BINARY_PATH" ]; then
        fail "Бинарник не найден в архиве."
    fi

    mv -f "$BINARY_PATH" "$DEST_FILE" || fail "Не удалось заменить файл."
    chmod +x "$DEST_FILE"
fi

NEW_VERSION=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true

cd /
rm -rf "$WORK_DIR"
WORK_DIR=""

SERVICE_STOPPED=""
service "$SERVICE_NAME" start

printf "${G}[+] Готово: ${Y}${CURRENT_VER:-н/д}${G} -> ${Y}${NEW_VERSION:-н/д}${N}\n"
