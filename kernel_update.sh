#!/bin/bash
set -e

# use curl
# bash <(curl -sL https://raw.githubusercontent.com/andy0mg/cent7/refs/heads/main/kernel_update.sh)

# use wget
# bash <(wget -qO- https://raw.githubusercontent.com/andy0mg/cent7/refs/heads/main/kernel_update.sh)



# Версия ядра для сборки (можно изменить)
KERNEL_VERSION="5.15.184"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-${KERNEL_VERSION}.tar.xz"

BACKUP_DATE=$(date +%F-%H%M%S)
SRC_DIR="/usr/src"
INSTALL_DIR="${SRC_DIR}/linux-${KERNEL_VERSION}"

# 1. Отключение всех лишних репозиториев (оставляем только те, где ВСЕ baseurl содержат vault.centos.org)
echo "### 1. Отключение всех лишних репозиториев (оставляем только vault)"
DISABLED_REPOS=""
for repofile in /etc/yum.repos.d/*.repo; do
    # Если в .repo-файле есть хотя бы один [section] с baseurl НЕ vault — отключаем всё
    NEED_DISABLE=0
    while read -r section; do
        sect_name=$(echo "$section" | grep -oP '^\[.*\]' | tr -d '[]')
        baseurl=$(awk "/^\[$sect_name\]/ {flag=1;next}/^\[/ {flag=0}flag" "$repofile" | grep -E '^baseurl=' | head -n1 | cut -d= -f2-)
        if [ -n "$baseurl" ] && [[ "$baseurl" != *vault.centos.org* ]]; then
            NEED_DISABLE=1
        fi
    done < <(grep -E '^\[.*\]' "$repofile")
    if [ $NEED_DISABLE -eq 1 ]; then
        if grep -q '^enabled=1' "$repofile"; then
            echo "Отключаю $repofile (есть не-vault baseurl)"
            sed -i 's/^enabled=1/enabled=0/' "$repofile"
            DISABLED_REPOS+="$repofile\n"
        fi
    fi
    # Если в .repo-файле нет секций или все baseurl vault — не трогаем
    # Если нет baseurl вообще (mirrorlist) — отключаем
    if ! grep -q '^baseurl=' "$repofile" && grep -q '^enabled=1' "$repofile"; then
        echo "Отключаю $repofile (нет baseurl — только mirrorlist)"
        sed -i 's/^enabled=1/enabled=0/' "$repofile"
        DISABLED_REPOS+="$repofile\n"
    fi
    unset NEED_DISABLE
    unset sect_name
    unset baseurl
done

# 2. Настройка vault-репозиториев для sclo-rh и base, если их нет
echo "### 2. Настройка Vault-репозиториев для SCLo и базовых пакетов"
if [ ! -f /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo ]; then
    cat >/etc/yum.repos.d/CentOS-SCLo-scl-rh.repo <<EOF
[centos-sclo-rh]
name=CentOS-7 - SCLo rh
baseurl=http://vault.centos.org/7.9.2009/sclo/x86_64/rh/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
EOF
fi

if [ ! -f /etc/yum.repos.d/CentOS-Vault.repo ]; then
    cat >/etc/yum.repos.d/CentOS-Vault.repo <<EOF
[centos7-vault-base]
name=CentOS-7 - Vault base
baseurl=http://vault.centos.org/7.9.2009/os/x86_64/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[centos7-vault-updates]
name=CentOS-7 - Vault updates
baseurl=http://vault.centos.org/7.9.2009/updates/x86_64/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
EOF
fi

# 3. yum clean и deps + gcc 10 через devtoolset-9
yum clean all
yum groupinstall -y "Development Tools"
yum install -y ncurses-devel bison flex elfutils-libelf-devel openssl-devel wget bc perl centos-release-scl devtoolset-9

# 4. Активация gcc 10 только в этом процессе
source /opt/rh/devtoolset-9/enable
set -e

# 5. Бэкап текущего grub.cfg и /boot
echo "### 3. Бэкап текущего grub.cfg и /boot"
mkdir -p /root/kernel-backup-$BACKUP_DATE
cp -a /boot /root/kernel-backup-$BACKUP_DATE/
cp /etc/default/grub /root/kernel-backup-$BACKUP_DATE/ 2>/dev/null || true

# 6. Очистка старых исходников (опционально)
echo "### 4. Очистка старых исходников (опционально)"
if [ -d "$SRC_DIR/linux-${KERNEL_VERSION}" ]; then
    echo "Удаляю старые исходники ядра $KERNEL_VERSION"
    rm -rf "$SRC_DIR/linux-${KERNEL_VERSION}"
fi

# 7. Скачивание и распаковка исходников ядра
echo "### 5. Скачивание и распаковка исходников ядра"
cd $SRC_DIR
if [ ! -f "linux-${KERNEL_VERSION}.tar.xz" ]; then
    wget -O "linux-${KERNEL_VERSION}.tar.xz" "$KERNEL_URL"
fi
tar -xf linux-${KERNEL_VERSION}.tar.xz

# 8. Копирование текущей конфигурации ядра
echo "### 6. Копирование текущей конфигурации ядра"
cd $INSTALL_DIR
if [ -f /boot/config-$(uname -r) ]; then
    cp /boot/config-$(uname -r) .config
    yes "" | make oldconfig
else
    make defconfig
fi

# 9. Компиляция ядра
echo "### 7. Компиляция ядра (может занять до 30-60 минут)"
make -j$(nproc)

# 10. Установка ядра и модулей
echo "### 8. Установка ядра и модулей"
make modules_install
make install

# 11. Восстановление SELinux label для /boot (если включено)
echo "### 9. Восстановление SELinux label для /boot (если включено)"
if command -v restorecon >/dev/null 2>&1 && sestatus | grep -q 'enabled'; then
    restorecon -Rv /boot
fi

# 12. Обновление grub и проверка загрузчиков
echo "### 10. Обновление grub и проверка загрузчиков"
grub2-mkconfig -o /boot/grub2/grub.cfg

# 13. Проверка новых записей grub
echo "### 11. Проверка новых записей grub"
awk -F"'" '$1=="menuentry " {print $2}' /boot/grub2/grub.cfg

# 14. Установка нового ядра по умолчанию
echo "### 12. Установка нового ядра по умолчанию"
NEW_KERNEL=$(awk -F"'" '$1=="menuentry " {print i++ " : " $2}' /boot/grub2/grub.cfg | grep "${KERNEL_VERSION}" | head -n1 | awk -F' : ' '{print $1}')
if [[ -n "$NEW_KERNEL" ]]; then
    grub2-set-default $NEW_KERNEL
    echo "Новое ядро ($KERNEL_VERSION) установлено как загрузка по умолчанию (grub entry $NEW_KERNEL)"
else
    echo "!!! Не удалось найти новое ядро в grub, выстави вручную после проверки /boot/grub2/grub.cfg"
fi

# 15. Включение ранее отключённых репозиториев (если скрипт завершился успешно)
echo "### 13. Включение ранее отключённых репозиториев"
if [ -n "$DISABLED_REPOS" ]; then
    echo -e "$DISABLED_REPOS" | while read repofile; do
        [ -f "$repofile" ] && sed -i 's/^enabled=0/enabled=1/' "$repofile"
    done
    echo "Репозитории восстановлены:"
    echo -e "$DISABLED_REPOS"
fi

# 16. Итоговая информация
echo -e "\n*** Сборка и установка ядра завершена ***"
echo "РЕКОМЕНДУЮ ПЕРЕЗАГРУЗИТЬ сервер и выбрать новое ядро в grub."
echo "Текущие ядра в /boot: "
ls -1 /boot/vmlinuz-*

echo -e "\nБэкап /boot и grub сохранён в /root/kernel-backup-$BACKUP_DATE"

echo -e "\nПРОВЕРЬ: После перезагрузки команда uname -r должна показать новое ядро: $KERNEL_VERSION"
echo -e "\nЕсли используешь DKMS-модули (VirtualBox, ZFS, etc) — их нужно пересобрать вручную после загрузки в новое ядро."

