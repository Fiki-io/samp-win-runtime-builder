#!/usr/bin/env bash
set -euxo pipefail

WORKDIR="$PWD/build_work"
STAGING="$WORKDIR/staging"
mkdir -p "$STAGING/bin/arm64-v8a" "$STAGING/bin/armeabi-v7a" "$STAGING/rootfs"

# 1. Extract static qemu-i386 binaries for Android ARM64 (arm64-v8a) and ARM32 (armeabi-v7a)
# Run Debian bookworm container to fetch exact qemu-user-static .deb packages for arm64 and armhf
docker run --rm -v "$WORKDIR:/work" debian:bookworm-slim bash -exc '
apt-get update
apt-get install -y --no-install-recommends binutils xz-utils
dpkg --add-architecture arm64
dpkg --add-architecture armhf
apt-get update
cd /work
apt-get download qemu-user-static:arm64 qemu-user-static:armhf

mkdir -p deb_arm64 deb_armhf
ar x qemu-user-static_*_arm64.deb --output=deb_arm64
tar -xJf deb_arm64/data.tar.xz -C deb_arm64
cp -f deb_arm64/usr/bin/qemu-i386-static /work/staging/bin/arm64-v8a/libqemu-i386.so

ar x qemu-user-static_*_armhf.deb --output=deb_armhf
tar -xJf deb_armhf/data.tar.xz -C deb_armhf
cp -f deb_armhf/usr/bin/qemu-i386-static /work/staging/bin/armeabi-v7a/libqemu-i386.so
chmod 0755 /work/staging/bin/arm64-v8a/libqemu-i386.so /work/staging/bin/armeabi-v7a/libqemu-i386.so
'

file "$STAGING/bin/arm64-v8a/libqemu-i386.so"
file "$STAGING/bin/armeabi-v7a/libqemu-i386.so"

# 2. Build the i386 RootFS inside a linux/386 Debian Bookworm container
docker rm -f samp-rootfs-container >/dev/null 2>&1 || true
docker run --name samp-rootfs-container --platform linux/386 \
    -v "$PWD/scripts:/scripts:ro" \
    debian:bookworm-slim bash /scripts/build_in_container.sh

# 3. Export the clean i386 RootFS into staging/rootfs
docker export samp-rootfs-container | tar -xf - -C "$STAGING/rootfs" \
    --exclude="dev/*" --exclude="proc/*" --exclude="sys/*" --exclude="scripts"
docker rm -f samp-rootfs-container

# 4. Write runtime manifest metadata for the Android Runner app
cat > "$STAGING/manifest.json" << 'EOF'
{
  "name": "SA-MP Windows Headless Runtime All-in-One",
  "version": "1.0.0",
  "arch_guest": "i386",
  "supported_host_abis": ["arm64-v8a", "armeabi-v7a"],
  "components": {
    "qemu_arm64": "bin/arm64-v8a/libqemu-i386.so",
    "qemu_arm32": "bin/armeabi-v7a/libqemu-i386.so",
    "rootfs": "rootfs",
    "wine_binary": "rootfs/usr/lib/wine/wine",
    "wineserver_binary": "rootfs/usr/lib/wine/wineserver",
    "wineprefix": "rootfs/opt/samp-runtime/wineprefix",
    "mariadbd_binary": "rootfs/usr/sbin/mariadbd",
    "mysql_binary": "rootfs/usr/bin/mysql",
    "mysql_data": "rootfs/opt/samp-runtime/mysql_data",
    "mysql_cnf": "rootfs/opt/samp-runtime/etc/my.cnf",
    "php_binary": "rootfs/usr/bin/php",
    "php_ini": "rootfs/opt/samp-runtime/etc/php.ini",
    "phpmyadmin_dir": "rootfs/opt/samp-runtime/phpmyadmin"
  }
}
EOF

# 5. Compress into a single All-in-One .tar.xz archive
mkdir -p "$PWD/dist"
ARCHIVE="$PWD/dist/samp-win-runtime-all-in-one.tar.xz"
XZ_OPT="-T0 -6" tar -cJf "$ARCHIVE" -C "$STAGING" bin rootfs manifest.json
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
ls -lh "$PWD/dist"
