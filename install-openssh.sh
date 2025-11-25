#!/bin/bash
set -e
# use curl
# bash <(curl -sL https://raw.githubusercontent.com/andy0mg/cent7/refs/heads/main/install-openssh.sh)

# use wget
# bash <(wget -qO- https://raw.githubusercontent.com/andy0mg/cent7/refs/heads/main/install-openssh.sh)




echo "[+] Установка зависимостей..."
yum groupinstall -y "Development Tools"
yum install -y wget pam-devel zlib-devel

echo "[+] Скачивание и установка OpenSSL 1.1.1w..."
cd /usr/local/src
wget https://www.openssl.org/source/openssl-1.1.1w.tar.gz
tar xzf openssl-1.1.1w.tar.gz
cd openssl-1.1.1w
./config --prefix=/opt/openssl-1.1.1 --openssldir=/opt/openssl-1.1.1
make -j$(nproc)
make install

echo "[+] Добавление OpenSSL в ld.so конфигурацию..."
echo "/opt/openssl-1.1.1/lib" > /etc/ld.so.conf.d/openssl-1.1.1.conf
ldconfig

echo "[+] Скачивание и установка OpenSSH 9.9p2..."
cd /usr/local/src
wget https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-9.9p2.tar.gz
tar xzf openssh-9.9p2.tar.gz
cd openssh-9.9p2

./configure --prefix=/opt/openssh-9.9 \
  --sysconfdir=/etc/ssh \
  --with-ssl-dir=/opt/openssl-1.1.1 \
  --with-md5-passwords \
  --with-pam \
  CPPFLAGS="-I/opt/openssl-1.1.1/include" \
  LDFLAGS="-L/opt/openssl-1.1.1/lib"
make -j$(nproc)
make install

echo "[+] Резервное копирование старых ssh и sshd (если есть)..."
mv /usr/bin/ssh /usr/bin/ssh.old 2>/dev/null || true
mv /usr/sbin/sshd /usr/sbin/sshd.old 2>/dev/null || true

echo "[+] Установка новых бинарников ssh и sshd..."
ln -sf /opt/openssh-9.9/bin/ssh /usr/bin/ssh
ln -sf /opt/openssh-9.9/sbin/sshd /usr/sbin/sshd
sed -i -E 's/^(GSSAPIAuthentication|GSSAPICleanupCredentials)/#\1/' /etc/ssh/sshd_config
chmod 600 /etc/ssh/ssh_host_*_key
chown root:root /etc/ssh/ssh_host_*_key
echo "[+] Проверка версий..."
ssh -V
sshd -V

echo "[✓] Установка завершена. Проверь SSH в новом окне, прежде чем выходить из текущей сессии!"
