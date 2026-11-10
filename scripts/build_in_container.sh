#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# 1. Install minimal required packages for Wine i386 headless, MariaDB, and PHP (without php-gd video codec bloat)
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    unzip \
    xz-utils \
    cabextract \
    binutils \
    wine \
    wine32 \
    libwine \
    mariadb-server \
    mariadb-client \
    php-cli \
    php-mysql \
    php-mbstring \
    php-xml \
    php-zip \
    php-curl

mkdir -p /opt/samp-runtime/{wineprefix,mysql_data,phpmyadmin,etc,tmp,run}

# 2. Pre-initialize headless WINEPREFIX and disable unneeded GUI/desktop services
export WINEPREFIX=/opt/samp-runtime/wineprefix
export WINEDEBUG=-all
export DISPLAY=
export WINEDLLOVERRIDES="mscoree,mshtml,winemenubuilder.exe,explorer.exe,plugplay.exe,rpcss.exe,services.exe,svchost.exe=d"

wineboot --init || true
wineserver -w || true

# 3. Install Visual C++ Redistributable x86 and MariaDB/MySQL Win32 Connector DLLs into system32
SYS32="/opt/samp-runtime/wineprefix/drive_c/windows/system32"
mkdir -p "$SYS32"

for dll in msvcp80.dll msvcr80.dll msvcp90.dll msvcr90.dll msvcp100.dll msvcr100.dll \
           msvcp110.dll msvcr110.dll msvcp120.dll msvcr120.dll msvcp140.dll msvcp140_1.dll \
           msvcp140_2.dll vcruntime140.dll concrt140.dll vcomp140.dll ucrtbase.dll \
           ws2_32.dll mswsock.dll iphlpapi.dll dbghelp.dll; do
    if [ -f "/usr/lib/i386-linux-gnu/wine/i386-windows/$dll" ]; then
        cp -f "/usr/lib/i386-linux-gnu/wine/i386-windows/$dll" "$SYS32/$dll"
    fi
done

if wget -q -O /tmp/vc_redist.x86.exe "https://aka.ms/vs/17/release/vc_redist.x86.exe"; then
    mkdir -p /tmp/vcredist
    cabextract -q -d /tmp/vcredist /tmp/vc_redist.x86.exe 2>/dev/null || true
    for cab in /tmp/vcredist/a*; do
        if [ -f "$cab" ] && cabextract -l "$cab" >/dev/null 2>&1; then
            cabextract -q -d /tmp/vcredist/extracted "$cab" 2>/dev/null || true
        fi
    done
    if [ -d /tmp/vcredist/extracted ]; then
        find /tmp/vcredist/extracted -iname "*.dll" -exec cp -f {} "$SYS32/" \;
    fi
    rm -rf /tmp/vc_redist.x86.exe /tmp/vcredist
fi

if wget -q -O /tmp/mariadb-win32.zip "https://archive.mariadb.org/connector-c-3.3.8/mariadb-connector-c-3.3.8-win32.zip"; then
    mkdir -p /tmp/mariadb-win32
    unzip -q /tmp/mariadb-win32.zip -d /tmp/mariadb-win32
    LIBMARIADB_PATH=$(find /tmp/mariadb-win32 -iname "libmariadb.dll" | head -n 1)
    if [ -n "$LIBMARIADB_PATH" ]; then
        cp -f "$LIBMARIADB_PATH" "$SYS32/libmariadb.dll"
        cp -f "$LIBMARIADB_PATH" "$SYS32/libmysql.dll"
    fi
    rm -rf /tmp/mariadb-win32.zip /tmp/mariadb-win32
fi

# 4. Write lightweight MariaDB configuration optimized for Android RAM & QEMU user-mode
cat > /opt/samp-runtime/etc/my.cnf << 'EOF'
[mysqld]
user=root
bind-address=127.0.0.1
port=3306
innodb_buffer_pool_size=16M
innodb_log_file_size=8M
innodb_use_native_aio=0
max_connections=32
performance_schema=OFF
skip-name-resolve
character-set-server=utf8mb4
collation-server=utf8mb4_general_ci

[client]
host=127.0.0.1
port=3306
user=root
EOF

# 5. Pre-initialize MariaDB data directory, remove Docker hostname entries, and set root empty password
mariadb-install-db --no-defaults \
    --basedir=/usr \
    --datadir=/opt/samp-runtime/mysql_data \
    --auth-root-authentication-method=normal \
    --skip-test-db \
    --innodb-use-native-aio=0

mariadbd --defaults-file=/opt/samp-runtime/etc/my.cnf \
    --basedir=/usr \
    --datadir=/opt/samp-runtime/mysql_data \
    --tmpdir=/opt/samp-runtime/tmp \
    --socket=/opt/samp-runtime/run/mysqld.sock \
    --pid-file=/opt/samp-runtime/run/mysqld.pid &
MARIADB_PID=$!

for i in $(seq 1 30); do
    if mysqladmin --socket=/opt/samp-runtime/run/mysqld.sock -u root ping >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

mysql --socket=/opt/samp-runtime/run/mysqld.sock -u root << 'EOF'
DELETE FROM mysql.user WHERE Host NOT IN ('localhost', '127.0.0.1', '::1');
DELETE FROM mysql.proxies_priv WHERE Host NOT IN ('localhost', '127.0.0.1', '::1');
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('');
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD('');
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
CREATE DATABASE IF NOT EXISTS samp_db;
FLUSH PRIVILEGES;
EOF

mysqladmin --socket=/opt/samp-runtime/run/mysqld.sock -u root shutdown
wait "$MARIADB_PID" || true

# 6. Install and pre-configure phpMyAdmin (English slim package)
wget -q -O /tmp/phpmyadmin.tar.xz "https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-english.tar.xz"
tar -xJf /tmp/phpmyadmin.tar.xz -C /opt/samp-runtime/phpmyadmin --strip-components=1
rm -f /tmp/phpmyadmin.tar.xz
rm -rf /opt/samp-runtime/phpmyadmin/{doc,examples,setup,sql,test}

cat > /opt/samp-runtime/phpmyadmin/config.inc.php << 'EOF'
<?php
declare(strict_types=1);
$cfg['blowfish_secret'] = 'SampAndroidRunnerSecretKey2026XamppStyle';
$i = 1;
$cfg['Servers'][$i]['auth_type'] = 'config';
$cfg['Servers'][$i]['host'] = '127.0.0.1';
$cfg['Servers'][$i]['port'] = '3306';
$cfg['Servers'][$i]['user'] = 'root';
$cfg['Servers'][$i]['password'] = '';
$cfg['Servers'][$i]['compress'] = false;
$cfg['Servers'][$i]['AllowNoPassword'] = true;
$cfg['TempDir'] = '/opt/samp-runtime/tmp';
$cfg['SendErrorReports'] = 'never';
$cfg['ShowPhpInfo'] = false;
EOF

# 7. Write self-contained php.ini with proper module load order (mysqlnd & pdo FIRST) and remove duplicate conf.d
EXT_DIR=$(find /usr/lib/php -maxdepth 1 -type d -name "20*" | head -n 1)
rm -rf /etc/php/*/cli/conf.d/*.ini

cat > /opt/samp-runtime/etc/php.ini << EOF
extension_dir = "$EXT_DIR"
extension=mysqlnd
extension=pdo
extension=xml
extension=mysqli
extension=pdo_mysql
extension=mbstring
extension=zip
extension=curl
memory_limit = 256M
upload_max_filesize = 128M
post_max_size = 128M
max_execution_time = 300
max_input_time = 300
mysqli.default_host = 127.0.0.1
mysqli.default_port = 3306
mysqli.default_user = root
session.save_path = "/opt/samp-runtime/tmp"
sys_temp_dir = "/opt/samp-runtime/tmp"
EOF

# 8. Strip unneeded Wine GUI/DirectX/Audio/Media bloat and strip ELF debug symbols to shrink size
WINE_WIN="/usr/lib/i386-linux-gnu/wine/i386-windows"
if [ -d "$WINE_WIN" ]; then
    rm -f "$WINE_WIN"/d3d*.dll "$WINE_WIN"/wined3d.dll "$WINE_WIN"/dxgi.dll \
          "$WINE_WIN"/vulkan*.dll "$WINE_WIN"/winevulkan.dll "$WINE_WIN"/openal32.dll \
          "$WINE_WIN"/xaudio*.dll "$WINE_WIN"/xactengine*.dll "$WINE_WIN"/x3daudio*.dll \
          "$WINE_WIN"/winealsa.drv "$WINE_WIN"/winepulse.drv "$WINE_WIN"/winex11.drv \
          "$WINE_WIN"/winedbg.exe "$WINE_WIN"/wordpad.exe "$WINE_WIN"/notepad.exe \
          "$WINE_WIN"/iexplore.exe "$WINE_WIN"/wmplayer.exe "$WINE_WIN"/oleview.exe \
          "$WINE_WIN"/winemine.exe "$WINE_WIN"/twain_32.dll "$WINE_WIN"/sane.ds \
          "$WINE_WIN"/gphoto2.ds "$WINE_WIN"/dmusic*.dll "$WINE_WIN"/dmime.dll \
          "$WINE_WIN"/dmsynth.dll "$WINE_WIN"/dmloader.dll "$WINE_WIN"/dsound.dll \
          "$WINE_WIN"/dinput*.dll "$WINE_WIN"/xinput*.dll "$WINE_WIN"/*.acm \
          "$WINE_WIN"/qedit.dll "$WINE_WIN"/quartz.dll "$WINE_WIN"/wmvcore.dll \
          "$WINE_WIN"/winebrowser.exe "$WINE_WIN"/winhlp32.exe "$WINE_WIN"/hh.exe \
          "$WINE_WIN"/control.exe "$WINE_WIN"/taskmgr.exe "$WINE_WIN"/explorer.exe || true
fi

rm -rf /usr/lib/i386-linux-gnu/dri /usr/lib/i386-linux-gnu/libLLVM*.so* \
       /usr/lib/i386-linux-gnu/libvulkan*.so* || true

# Strip debug symbols from shared objects and binaries
find /usr/lib /usr/bin /usr/sbin -type f \( -name "*.so*" -o -executable \) -exec strip --strip-unneeded {} + 2>/dev/null || true

# 9. Strict verification: ensure ZERO PHP startup warnings and all required extensions load
wine --version
mariadbd --version
PHP_OUT=$(php -c /opt/samp-runtime/etc/php.ini -v 2>&1)
echo "$PHP_OUT"
if echo "$PHP_OUT" | grep -qi "warning"; then
    echo "ERROR: PHP startup produced warnings!"
    exit 1
fi
php -c /opt/samp-runtime/etc/php.ini -l /opt/samp-runtime/phpmyadmin/config.inc.php
php -c /opt/samp-runtime/etc/php.ini -m | grep -E "^(mysqli|pdo_mysql|mbstring|zip|xml|curl)$"

# 10. Clean apt caches, docs, locales, and temporary build tools
apt-get remove -y cabextract wget unzip xz-utils binutils || true
apt-get autoremove -y || true
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/* /usr/share/doc/* /usr/share/man/* \
       /usr/share/info/* /usr/share/locale/* /usr/include/* /var/log/* /tmp/*
