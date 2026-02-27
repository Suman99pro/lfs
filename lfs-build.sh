#!/bin/bash
# =============================================================================
#  Linux From Scratch (LFS 12.2) - Full Build Script for USB Drive
#  Based on: https://www.linuxfromscratch.org/lfs/downloads/stable/
#
#  USAGE:
#    1. Edit the CONFIG section below
#    2. Run as root: sudo bash lfs-build.sh
#    3. Grab a coffee — this takes 4-12 hours
#
#  PHASES:
#    Phase 1 — Partition & Format USB
#    Phase 2 — Download Sources
#    Phase 3 — Cross-Compilation Toolchain (as lfs user)
#    Phase 4 — Temporary Tools
#    Phase 5 — Chroot & Full System Build
#    Phase 6 — Kernel + GRUB
#    Phase 7 — System Config & Cleanup
# =============================================================================

set -e  # Exit on any error
set -o pipefail

# =============================================================================
#  !! CONFIGURATION — EDIT THESE BEFORE RUNNING !!
# =============================================================================
USB_DRIVE="/dev/sdb"          # Your USB drive (check with: lsblk)
LFS="/mnt/lfs"                # Mount point
LFS_HOSTNAME="lfs-usb"        # Hostname for the new system
ROOT_PASS="lfsroot"           # Root password for LFS system
JOBS=$(nproc)                 # Number of parallel make jobs
LFS_VERSION="12.2"

# Partition sizes
EFI_SIZE="+512M"
SWAP_SIZE="+2G"
# Root gets the rest

# =============================================================================
#  COLOR OUTPUT
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[LFS]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}========== $* ==========${NC}\n"; }
step()    { echo -e "${CYAN}  --> $*${NC}"; }

# =============================================================================
#  SAFETY CHECKS
# =============================================================================
preflight_checks() {
  section "Preflight Checks"

  [[ $EUID -ne 0 ]] && error "This script must be run as root (sudo)."

  # Check host tools
  for tool in bash gcc g++ make gawk bison tar wget fdisk mkfs.ext4 mkfs.fat mkswap; do
    command -v $tool &>/dev/null || error "Required tool not found: $tool  (install it first)"
  done

  # Check bash version >= 3.2
  BASH_VER=$(bash --version | head -1 | awk '{print $4}' | cut -d. -f1)
  [[ $BASH_VER -lt 3 ]] && error "Bash 3.2+ required"

  # Confirm drive selection
  lsblk $USB_DRIVE &>/dev/null || error "Drive $USB_DRIVE not found. Check USB_DRIVE in config."

  echo -e "${RED}${BOLD}"
  echo "  !! WARNING !! "
  echo "  All data on $USB_DRIVE will be DESTROYED."
  echo "  Drive info:"
  lsblk $USB_DRIVE
  echo -e "${NC}"
  read -rp "  Type 'yes' to continue: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && error "Aborted by user."

  log "All preflight checks passed."
}

# =============================================================================
#  PHASE 1: PARTITION & FORMAT
# =============================================================================
phase1_partition() {
  section "Phase 1: Partitioning $USB_DRIVE"

  step "Wiping existing partition table..."
  wipefs -a $USB_DRIVE
  dd if=/dev/zero of=$USB_DRIVE bs=1M count=10 status=none

  step "Creating GPT partition table..."
  parted -s $USB_DRIVE mklabel gpt

  step "Creating EFI partition (512M)..."
  parted -s $USB_DRIVE mkpart EFI fat32 1MiB 513MiB
  parted -s $USB_DRIVE set 1 esp on

  step "Creating swap partition (2G)..."
  parted -s $USB_DRIVE mkpart SWAP linux-swap 513MiB 2561MiB

  step "Creating root partition (remaining space)..."
  parted -s $USB_DRIVE mkpart ROOT ext4 2561MiB 100%

  # Wait for kernel to re-read partition table
  partprobe $USB_DRIVE
  sleep 2

  EFI_PART="${USB_DRIVE}1"
  SWAP_PART="${USB_DRIVE}2"
  ROOT_PART="${USB_DRIVE}3"

  # Handle nvme drives (e.g. /dev/nvme0n1p1)
  if [[ "$USB_DRIVE" == *"nvme"* ]] || [[ "$USB_DRIVE" == *"mmcblk"* ]]; then
    EFI_PART="${USB_DRIVE}p1"
    SWAP_PART="${USB_DRIVE}p2"
    ROOT_PART="${USB_DRIVE}p3"
  fi

  step "Formatting EFI (FAT32)..."
  mkfs.fat -F32 -n EFI $EFI_PART

  step "Formatting swap..."
  mkswap -L SWAP $SWAP_PART
  swapon $SWAP_PART

  step "Formatting root (ext4)..."
  mkfs.ext4 -L LFS-ROOT $ROOT_PART

  step "Mounting filesystems..."
  mkdir -pv $LFS
  mount $ROOT_PART $LFS
  mkdir -pv $LFS/boot/efi
  mount $EFI_PART $LFS/boot/efi

  # Save partition info for later phases
  export EFI_PART SWAP_PART ROOT_PART
  export ROOT_UUID=$(blkid -s UUID -o value $ROOT_PART)
  export EFI_UUID=$(blkid -s UUID -o value $EFI_PART)
  export SWAP_UUID=$(blkid -s UUID -o value $SWAP_PART)

  log "Phase 1 complete. Partitions ready."
}

# =============================================================================
#  PHASE 2: PREPARE DIRECTORIES & DOWNLOAD SOURCES
# =============================================================================
phase2_sources() {
  section "Phase 2: Preparing Directories & Downloading Sources"

  step "Creating LFS directory structure..."
  mkdir -pv $LFS/{etc,var,sources,tools}
  mkdir -pv $LFS/usr/{bin,lib,sbin}
  mkdir -pv $LFS/lib64

  for i in bin lib sbin; do
    ln -sfv usr/$i $LFS/$i 2>/dev/null || true
  done

  chmod -v a+wt $LFS/sources

  step "Downloading LFS source packages..."
  cd $LFS/sources

  wget -q --show-progress --continue \
    https://www.linuxfromscratch.org/lfs/downloads/$LFS_VERSION/wget-list \
    -O wget-list

  wget -q --show-progress --continue \
    --input-file=wget-list \
    --directory-prefix=$LFS/sources \
    --continue || warn "Some downloads may have failed — continuing anyway"

  step "Verifying checksums..."
  wget -q https://www.linuxfromscratch.org/lfs/downloads/$LFS_VERSION/md5sums \
    -O md5sums
  md5sum -c md5sums --ignore-missing 2>/dev/null | grep -v OK | head -20 || true

  log "Phase 2 complete."
}

# =============================================================================
#  PHASE 3: CROSS-COMPILATION TOOLCHAIN
#  Run as 'lfs' user with clean environment
# =============================================================================
phase3_toolchain() {
  section "Phase 3: Cross-Compilation Toolchain"

  step "Creating lfs build user..."
  groupadd lfs 2>/dev/null || true
  useradd -s /bin/bash -g lfs -m -k /dev/null lfs 2>/dev/null || true

  step "Transferring ownership to lfs user..."
  chown -Rv lfs:lfs $LFS/{usr,lib,var,etc,bin,sbin,tools,sources,lib64,boot} 2>/dev/null || true

  step "Writing lfs user environment..."
  cat > /home/lfs/.bash_profile << 'EOF'
exec env -i HOME=$HOME TERM=$TERM PS1='\u:\w\$ ' /bin/bash
EOF

  cat > /home/lfs/.bashrc << EOF
set +h
umask 022
LFS=$LFS
LC_ALL=POSIX
LFS_TGT=\$(uname -m)-lfs-linux-gnu
PATH=/usr/bin
if [ ! -L /bin ]; then PATH=/bin:\$PATH; fi
PATH=\$LFS/tools/bin:\$PATH
CONFIG_SITE=\$LFS/usr/share/config.site
export LFS LC_ALL LFS_TGT PATH CONFIG_SITE
MAKEFLAGS="-j$JOBS"
export MAKEFLAGS
EOF
  chown lfs:lfs /home/lfs/.bash_profile /home/lfs/.bashrc

  step "Writing toolchain build script..."
  cat > /home/lfs/build-toolchain.sh << 'TOOLCHAIN_SCRIPT'
#!/bin/bash
set -e
source ~/.bashrc
cd $LFS/sources

build_package() {
  local name=$1; shift
  echo -e "\n\033[0;36m  --> Building: $name\033[0m"
}

# -----------------------------------------------------------------------
# 1. BINUTILS — Pass 1
# -----------------------------------------------------------------------
build_package "Binutils Pass 1"
tar -xf binutils-*.tar.xz
cd binutils-*/
mkdir -v build && cd build
../configure              \
    --prefix=$LFS/tools   \
    --with-sysroot=$LFS   \
    --target=$LFS_TGT     \
    --disable-nls         \
    --enable-gprofng=no   \
    --disable-werror      \
    --enable-new-dtags    \
    --enable-default-hash-style=gnu
make $MAKEFLAGS
make install
cd $LFS/sources
rm -rf binutils-*/

# -----------------------------------------------------------------------
# 2. GCC — Pass 1
# -----------------------------------------------------------------------
build_package "GCC Pass 1"
tar -xf gcc-*.tar.xz
cd gcc-*/
tar -xf $LFS/sources/mpfr-*.tar.xz
mv -v mpfr-*/ mpfr
tar -xf $LFS/sources/gmp-*.tar.xz
mv -v gmp-*/ gmp
tar -xf $LFS/sources/mpc-*.tar.gz
mv -v mpc-*/ mpc

# Fix host libgcc paths
case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
  ;;
esac

mkdir -v build && cd build
../configure                  \
    --target=$LFS_TGT         \
    --prefix=$LFS/tools       \
    --with-glibc-version=2.40 \
    --with-sysroot=$LFS       \
    --with-newlib             \
    --without-headers         \
    --enable-default-pie      \
    --enable-default-ssp      \
    --disable-nls             \
    --disable-shared          \
    --disable-multilib        \
    --disable-threads         \
    --disable-libatomic       \
    --disable-libgomp         \
    --disable-libquadmath     \
    --disable-libssp          \
    --disable-libvtv          \
    --disable-libstdcxx       \
    --enable-languages=c,c++
make $MAKEFLAGS
make install

# Generate limits.h
cd ..
cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
    $(dirname $($LFS_TGT-gcc -print-libgcc-file-name))/include/limits.h

cd $LFS/sources
rm -rf gcc-*/

# -----------------------------------------------------------------------
# 3. LINUX API HEADERS
# -----------------------------------------------------------------------
build_package "Linux API Headers"
tar -xf linux-*.tar.xz
cd linux-*/
make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include $LFS/usr
cd $LFS/sources
rm -rf linux-*/

# -----------------------------------------------------------------------
# 4. GLIBC
# -----------------------------------------------------------------------
build_package "Glibc"
tar -xf glibc-*.tar.xz
cd glibc-*/

case $(uname -m) in
  i?86)   ln -sfv ld-linux.so.2 $LFS/lib/ld-lsb.so.3 ;;
  x86_64) ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64 && \
          ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3 ;;
esac

patch -Np1 -i $LFS/sources/glibc-*-fhs-1.patch 2>/dev/null || true

mkdir -v build && cd build
echo "rootsbindir=/usr/sbin" > configparms
../configure                           \
    --prefix=/usr                      \
    --host=$LFS_TGT                    \
    --build=$(../scripts/config.guess) \
    --enable-kernel=4.19               \
    --with-headers=$LFS/usr/include    \
    --disable-nscd                     \
    libc_cv_slibdir=/usr/lib
make $MAKEFLAGS
make DESTDIR=$LFS install

# Fix hard-coded path
sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd

# Sanity check
echo 'int main(){}' | $LFS_TGT-gcc -xc -
readelf -l a.out | grep ld-linux || echo "WARNING: Glibc sanity check may have issues"
rm -v a.out

cd $LFS/sources
rm -rf glibc-*/

# -----------------------------------------------------------------------
# 5. LIBSTDC++ (from GCC sources)
# -----------------------------------------------------------------------
build_package "Libstdc++"
tar -xf gcc-*.tar.xz
cd gcc-*/
mkdir -v build && cd build
../libstdc++-v3/configure           \
    --host=$LFS_TGT                 \
    --build=$(../config.guess)      \
    --prefix=/usr                   \
    --disable-multilib              \
    --disable-nls                   \
    --disable-libstdcxx-pch         \
    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/$(ls ../gcc/BASE-VER | cut -d. -f1)*
make $MAKEFLAGS
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/lib{stdc++{,exp},supc++}.la
cd $LFS/sources
rm -rf gcc-*/

echo -e "\n\033[0;32m[LFS] Cross-toolchain complete!\033[0m"
TOOLCHAIN_SCRIPT

  chown lfs:lfs /home/lfs/build-toolchain.sh
  chmod +x /home/lfs/build-toolchain.sh

  step "Running toolchain build as lfs user (this takes ~30-60 min)..."
  su - lfs -c "bash /home/lfs/build-toolchain.sh" 2>&1 | tee /var/log/lfs-toolchain.log

  log "Phase 3 complete. Cross-toolchain built."
}

# =============================================================================
#  PHASE 4: TEMPORARY TOOLS (still as lfs user, then chroot prep)
# =============================================================================
phase4_temp_tools() {
  section "Phase 4: Temporary Tools"

  cat > /home/lfs/build-temptools.sh << 'TEMPTOOLS_SCRIPT'
#!/bin/bash
set -e
source ~/.bashrc
cd $LFS/sources

build() { echo -e "\n\033[0;36m  --> Building: $1\033[0m"; }

# -----------------------------------------------------------------------
# M4
# -----------------------------------------------------------------------
build "M4"
tar -xf m4-*.tar.xz; cd m4-*/
./configure --prefix=/usr --host=$LFS_TGT --build=$(build-aux/config.guess)
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf m4-*/

# -----------------------------------------------------------------------
# NCURSES
# -----------------------------------------------------------------------
build "Ncurses"
tar -xf ncurses-*.tar.gz; cd ncurses-*/
sed -i s/mawk// configure
mkdir -v build; pushd build
  ../configure
  make -C include && make -C progs tic
popd
./configure                \
    --prefix=/usr          \
    --host=$LFS_TGT        \
    --build=$(./config.guess) \
    --mandir=/usr/share/man  \
    --with-manpage-format=normal \
    --with-shared          \
    --without-normal       \
    --with-cxx-shared      \
    --without-debug        \
    --without-ada          \
    --disable-stripping    \
    --enable-widec
make $MAKEFLAGS
make DESTDIR=$LFS TIC_PATH=$(pwd)/build/progs/tic install
ln -sv libncursesw.so $LFS/usr/lib/libncurses.so
sed -e 's/^#if.*XOPEN.*$/#if 1/' -i $LFS/usr/include/curses.h
cd $LFS/sources; rm -rf ncurses-*/

# -----------------------------------------------------------------------
# BASH
# -----------------------------------------------------------------------
build "Bash"
tar -xf bash-*.tar.gz; cd bash-*/
./configure                  \
    --prefix=/usr            \
    --build=$(sh support/config.guess) \
    --host=$LFS_TGT          \
    --without-bash-malloc
make $MAKEFLAGS
make DESTDIR=$LFS install
ln -sv bash $LFS/usr/bin/sh
cd $LFS/sources; rm -rf bash-*/

# -----------------------------------------------------------------------
# COREUTILS
# -----------------------------------------------------------------------
build "Coreutils"
tar -xf coreutils-*.tar.xz; cd coreutils-*/
./configure                  \
    --prefix=/usr            \
    --host=$LFS_TGT          \
    --build=$(build-aux/config.guess) \
    --enable-install-program=hostname \
    --enable-no-install-program=kill,uptime
make $MAKEFLAGS
make DESTDIR=$LFS install
mv -v $LFS/usr/bin/chroot $LFS/usr/sbin
mkdir -pv $LFS/usr/share/man/man8
mv -v $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/' $LFS/usr/share/man/man8/chroot.8
cd $LFS/sources; rm -rf coreutils-*/

# -----------------------------------------------------------------------
# DIFFUTILS
# -----------------------------------------------------------------------
build "Diffutils"
tar -xf diffutils-*.tar.xz; cd diffutils-*/
./configure --prefix=/usr --host=$LFS_TGT --build=$(./build-aux/config.guess)
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf diffutils-*/

# -----------------------------------------------------------------------
# FILE
# -----------------------------------------------------------------------
build "File"
tar -xf file-*.tar.gz; cd file-*/
mkdir -v build; pushd build
  ../configure --disable-bzlib --disable-libseccomp --disable-xzlib --disable-zlib
  make
popd
./configure --prefix=/usr --host=$LFS_TGT --build=$(./config.guess)
make FILE_COMPILE=$(pwd)/build/src/file $MAKEFLAGS
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/libmagic.la
cd $LFS/sources; rm -rf file-*/

# -----------------------------------------------------------------------
# FINDUTILS
# -----------------------------------------------------------------------
build "Findutils"
tar -xf findutils-*.tar.xz; cd findutils-*/
./configure                \
    --prefix=/usr          \
    --localstatedir=/var/lib/locate \
    --host=$LFS_TGT        \
    --build=$(build-aux/config.guess)
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf findutils-*/

# -----------------------------------------------------------------------
# GAWK
# -----------------------------------------------------------------------
build "Gawk"
tar -xf gawk-*.tar.xz; cd gawk-*/
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr --host=$LFS_TGT --build=$(build-aux/config.guess)
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf gawk-*/

# -----------------------------------------------------------------------
# GREP
# -----------------------------------------------------------------------
build "Grep"
tar -xf grep-*.tar.xz; cd grep-*/
./configure --prefix=/usr --host=$LFS_TGT --build=$(./build-aux/config.guess)
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf grep-*/

# -----------------------------------------------------------------------
# GZIP
# -----------------------------------------------------------------------
build "Gzip"
tar -xf gzip-*.tar.xz; cd gzip-*/
./configure --prefix=/usr --host=$LFS_TGT
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf gzip-*/

# -----------------------------------------------------------------------
# MAKE
# -----------------------------------------------------------------------
build "Make"
tar -xf make-*.tar.gz; cd make-*/
./configure                    \
    --prefix=/usr              \
    --without-guile            \
    --host=$LFS_TGT            \
    --build=$(build-aux/config.guess)
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf make-*/

# -----------------------------------------------------------------------
# PATCH
# -----------------------------------------------------------------------
build "Patch"
tar -xf patch-*.tar.xz; cd patch-*/
./configure --prefix=/usr --host=$LFS_TGT --build=$(build-aux/config.guess)
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf patch-*/

# -----------------------------------------------------------------------
# SED
# -----------------------------------------------------------------------
build "Sed"
tar -xf sed-*.tar.xz; cd sed-*/
./configure --prefix=/usr --host=$LFS_TGT --build=$(./build-aux/config.guess)
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf sed-*/

# -----------------------------------------------------------------------
# TAR
# -----------------------------------------------------------------------
build "Tar"
tar -xf tar-*.tar.xz; cd tar-*/
./configure --prefix=/usr --host=$LFS_TGT --build=$(build-aux/config.guess)
make $MAKEFLAGS && make DESTDIR=$LFS install
cd $LFS/sources; rm -rf tar-*/

# -----------------------------------------------------------------------
# XZ
# -----------------------------------------------------------------------
build "Xz"
tar -xf xz-*.tar.xz; cd xz-*/
./configure                  \
    --prefix=/usr            \
    --host=$LFS_TGT          \
    --build=$(build-aux/config.guess) \
    --disable-static         \
    --docdir=/usr/share/doc/xz
make $MAKEFLAGS && make DESTDIR=$LFS install
rm -v $LFS/usr/lib/liblzma.la
cd $LFS/sources; rm -rf xz-*/

# -----------------------------------------------------------------------
# BINUTILS — Pass 2
# -----------------------------------------------------------------------
build "Binutils Pass 2"
tar -xf binutils-*.tar.xz; cd binutils-*/
sed '6009s/$add_dir//' -i ltmain.sh
mkdir -v build && cd build
../configure                    \
    --prefix=/usr               \
    --build=$(../config.guess)  \
    --host=$LFS_TGT             \
    --disable-nls               \
    --enable-shared             \
    --enable-gprofng=no         \
    --disable-werror            \
    --enable-64-bit-bfd         \
    --enable-new-dtags          \
    --enable-default-hash-style=gnu
make $MAKEFLAGS && make DESTDIR=$LFS install
rm -v $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
cd $LFS/sources; rm -rf binutils-*/

# -----------------------------------------------------------------------
# GCC — Pass 2
# -----------------------------------------------------------------------
build "GCC Pass 2"
tar -xf gcc-*.tar.xz; cd gcc-*/
tar -xf $LFS/sources/mpfr-*.tar.xz; mv -v mpfr-*/ mpfr
tar -xf $LFS/sources/gmp-*.tar.xz;  mv -v gmp-*/  gmp
tar -xf $LFS/sources/mpc-*.tar.gz;  mv -v mpc-*/  mpc

case $(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
  ;;
esac

sed '/thread_header =/s/@.*@/gthr-posix.h/' \
    -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in

mkdir -v build && cd build
../configure                               \
    --build=$(../config.guess)             \
    --host=$LFS_TGT                        \
    --target=$(uname -m)-linux-gnu         \
    LDFLAGS_FOR_TARGET="-L$PWD/$LFS_TGT/libgcc" \
    --prefix=/usr                          \
    --with-build-sysroot=$LFS             \
    --enable-default-pie                   \
    --enable-default-ssp                   \
    --disable-nls                          \
    --disable-multilib                     \
    --disable-libatomic                    \
    --disable-libgomp                      \
    --disable-libquadmath                  \
    --disable-libsanitizer                 \
    --disable-libssp                       \
    --disable-libvtv                       \
    --enable-languages=c,c++
make $MAKEFLAGS
make DESTDIR=$LFS install
ln -sv gcc $LFS/usr/bin/cc
cd $LFS/sources; rm -rf gcc-*/

echo -e "\n\033[0;32m[LFS] Temporary tools complete!\033[0m"
TEMPTOOLS_SCRIPT

  chown lfs:lfs /home/lfs/build-temptools.sh
  chmod +x /home/lfs/build-temptools.sh

  step "Building temporary tools as lfs user (this takes ~30-60 min)..."
  su - lfs -c "bash /home/lfs/build-temptools.sh" 2>&1 | tee /var/log/lfs-temptools.log

  log "Phase 4 complete."
}

# =============================================================================
#  PHASE 5: CHROOT SETUP
# =============================================================================
phase5_chroot_setup() {
  section "Phase 5: Preparing Chroot Environment"

  step "Taking ownership back to root..."
  chown -R root:root $LFS/{usr,lib,lib64,var,etc,bin,sbin,tools,sources,boot} 2>/dev/null || true

  step "Creating remaining directory structure..."
  mkdir -pv $LFS/{dev,proc,sys,run}
  mkdir -pv $LFS/{boot,home,mnt,opt,srv}
  mkdir -pv $LFS/etc/{opt,sysconfig}
  mkdir -pv $LFS/lib/firmware
  mkdir -pv $LFS/media/{floppy,cdrom}
  mkdir -pv $LFS/usr/{,local/}{include,src}
  mkdir -pv $LFS/usr/local/{bin,lib,sbin}
  mkdir -pv $LFS/usr/{,local/}share/{color,dict,doc,info,locale,man}
  mkdir -pv $LFS/usr/{,local/}share/{misc,terminfo,zoneinfo}
  mkdir -pv $LFS/usr/{,local/}share/man/man{1..8}
  mkdir -pv $LFS/var/{cache,local,log,mail,opt,spool}
  mkdir -pv $LFS/var/lib/{color,misc,locate}
  install -dv -m 0750 $LFS/root
  install -dv -m 1777 $LFS/tmp $LFS/var/tmp

  step "Creating essential files..."
  ln -sfv /run $LFS/var/run
  ln -sfv /run/lock $LFS/var/lock

  # /etc/mtab
  ln -sfv ../proc/self/mounts $LFS/etc/mtab

  cat > $LFS/etc/hosts << EOF
127.0.0.1  localhost
127.0.1.1  $LFS_HOSTNAME
::1        localhost ip6-localhost ip6-loopback
ff02::1    ip6-allnodes
ff02::2    ip6-allrouters
EOF

  cat > $LFS/etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/usr/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/usr/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/usr/bin/false
systemd-network:x:76:76:systemd Network Management:/:/usr/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/usr/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/usr/bin/false
systemd-coredump:x:79:79:systemd Core Dumper:/:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
systemd-oom:x:81:81:systemd Out Of Memory Daemon:/:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF

  cat > $LFS/etc/group << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
systemd-journal:x:23:
input:x:24:
mail:x:34:
kvm:x:61:
systemd-journal-gateway:x:73:
systemd-journal-remote:x:74:
systemd-journal-upload:x:75:
systemd-network:x:76:
systemd-resolve:x:77:
systemd-timesync:x:78:
systemd-coredump:x:79:
uuidd:x:80:
systemd-oom:x:81:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF

  touch $LFS/var/log/{btmp,lastlog,faillog,wtmp}
  chgrp -v utmp $LFS/var/log/lastlog
  chmod -v 664  $LFS/var/log/lastlog
  chmod -v 600  $LFS/var/log/btmp

  step "Mounting virtual kernel filesystems..."
  mount -v --bind /dev $LFS/dev
  mount -vt devpts devpts -o gid=5,mode=0620 $LFS/dev/pts
  mount -vt proc proc $LFS/proc
  mount -vt sysfs sysfs $LFS/sys
  mount -vt tmpfs tmpfs $LFS/run
  if [ -h $LFS/dev/shm ]; then
    install -v -d -m 1777 $LFS/$(realpath /dev/shm)
  else
    mount -vt tmpfs -o nosuid,nodev tmpfs $LFS/dev/shm
  fi

  log "Phase 5 complete. Chroot environment ready."
}

# =============================================================================
#  PHASE 6: FULL SYSTEM BUILD INSIDE CHROOT
# =============================================================================
phase6_full_system() {
  section "Phase 6: Building Full LFS System Inside Chroot"

  step "Writing full system build script..."
  cat > $LFS/sources/build-system.sh << CHROOT_SCRIPT
#!/bin/bash
set -e
export MAKEFLAGS="-j$JOBS"
cd /sources

build() { echo -e "\n\033[0;36m  --> Building: \$1\033[0m"; }

# -----------------------------------------------------------------------
# SETUP
# -----------------------------------------------------------------------
install -dv /usr/share/pkgconfig

# -----------------------------------------------------------------------
# MAN-PAGES
# -----------------------------------------------------------------------
build "Man-Pages"
tar -xf man-pages-*.tar.xz; cd man-pages-*/
rm -v man3/crypt*.3
make prefix=/usr install
cd /sources; rm -rf man-pages-*/

# -----------------------------------------------------------------------
# IANA-ETC
# -----------------------------------------------------------------------
build "Iana-Etc"
tar -xf iana-etc-*.tar.gz; cd iana-etc-*/
cp -v services protocols /etc
cd /sources; rm -rf iana-etc-*/

# -----------------------------------------------------------------------
# GLIBC
# -----------------------------------------------------------------------
build "Glibc"
tar -xf glibc-*.tar.xz; cd glibc-*/
patch -Np1 -i /sources/glibc-*-fhs-1.patch 2>/dev/null || true
mkdir -v build && cd build
echo "rootsbindir=/usr/sbin" > configparms
../configure             \
    --prefix=/usr        \
    --disable-werror     \
    --enable-kernel=4.19 \
    --enable-stack-protector=strong \
    --disable-nscd       \
    libc_cv_slibdir=/usr/lib
make \$MAKEFLAGS
# Disable tests that may fail in chroot
touch /etc/ld.so.conf
sed '/test-installation/s@\$(PERL)@echo not running@' -i ../Makefile
make install
sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
cp -v ../nscd/nscd.conf /etc/nscd.conf
mkdir -pv /var/cache/nscd

# Locales
mkdir -pv /usr/lib/locale
localedef -i C -f UTF-8 C.UTF-8 2>/dev/null || true
localedef -i en_US -f UTF-8 en_US.UTF-8 2>/dev/null || true

cat > /etc/nsswitch.conf << "EOF2"
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
EOF2

# Timezone
tar -xf /sources/tzdata*.tar.gz -C /tmp
ZONEINFO=/usr/share/zoneinfo
mkdir -pv \$ZONEINFO/{posix,right}
for tz in /tmp/etcetera /tmp/southamerica /tmp/northamerica \
           /tmp/europe /tmp/africa /tmp/antarctica \
           /tmp/asia /tmp/australasia /tmp/backward; do
  zic -L /dev/null -d \$ZONEINFO \$tz 2>/dev/null || true
  zic -L /dev/null -d \$ZONEINFO/posix \$tz 2>/dev/null || true
  zic -L /tmp/leapseconds -d \$ZONEINFO/right \$tz 2>/dev/null || true
done
cp -v /tmp/zone.tab /tmp/zone1970.tab /tmp/iso3166.tab \$ZONEINFO
zic -d \$ZONEINFO -p America/New_York 2>/dev/null || true
ln -sfv /usr/share/zoneinfo/UTC /etc/localtime

cat > /etc/ld.so.conf << "EOF2"
/usr/local/lib
/opt/lib
include /etc/ld.so.conf.d/*.conf
EOF2
mkdir -pv /etc/ld.so.conf.d

cd /sources; rm -rf glibc-*/

# -----------------------------------------------------------------------
# ZLIB
# -----------------------------------------------------------------------
build "Zlib"
tar -xf zlib-*.tar.gz; cd zlib-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
rm -fv /usr/lib/libz.a
cd /sources; rm -rf zlib-*/

# -----------------------------------------------------------------------
# BZIP2
# -----------------------------------------------------------------------
build "Bzip2"
tar -xf bzip2-*.tar.gz; cd bzip2-*/
patch -Np1 -i /sources/bzip2-*-install_docs-1.patch 2>/dev/null || true
sed -i 's@\(ln -s -f \)\$(PREFIX)/bin/@\1@' Makefile
sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
make -f Makefile-libbz2_so && make clean
make \$MAKEFLAGS
make PREFIX=/usr install
cp -av libbz2.so.* /usr/lib
ln -sv libbz2.so.1.0.8 /usr/lib/libbz2.so
cp -v bzip2-shared /usr/bin/bzip2
for i in /usr/bin/{bzcat,bunzip2}; do
  ln -sfv bzip2 \$i
done
rm -fv /usr/lib/libbz2.a
cd /sources; rm -rf bzip2-*/

# -----------------------------------------------------------------------
# XZ
# -----------------------------------------------------------------------
build "Xz"
tar -xf xz-*.tar.xz; cd xz-*/
./configure            \
    --prefix=/usr      \
    --disable-static   \
    --docdir=/usr/share/doc/xz
make \$MAKEFLAGS && make install
cd /sources; rm -rf xz-*/

# -----------------------------------------------------------------------
# ZSTD
# -----------------------------------------------------------------------
build "Zstd"
tar -xf zstd-*.tar.gz; cd zstd-*/
make \$MAKEFLAGS prefix=/usr
make prefix=/usr install
rm -v /usr/lib/libzstd.a
cd /sources; rm -rf zstd-*/

# -----------------------------------------------------------------------
# FILE
# -----------------------------------------------------------------------
build "File"
tar -xf file-*.tar.gz; cd file-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf file-*/

# -----------------------------------------------------------------------
# READLINE
# -----------------------------------------------------------------------
build "Readline"
tar -xf readline-*.tar.gz; cd readline-*/
sed -i '/MV.*old/d' Makefile.in
sed -i '/{OLDSUFF}/c:' support/shlib-install
sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
./configure            \
    --prefix=/usr      \
    --disable-static   \
    --with-curses      \
    --docdir=/usr/share/doc/readline
make SHLIB_LIBS="-lncursesw" \$MAKEFLAGS
make SHLIB_LIBS="-lncursesw" install
install -v -m644 doc/*.{ps,pdf,html,dvi} /usr/share/doc/readline
cd /sources; rm -rf readline-*/

# -----------------------------------------------------------------------
# M4
# -----------------------------------------------------------------------
build "M4"
tar -xf m4-*.tar.xz; cd m4-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf m4-*/

# -----------------------------------------------------------------------
# BC
# -----------------------------------------------------------------------
build "Bc"
tar -xf bc-*.tar.xz; cd bc-*/
CC=gcc ./configure --prefix=/usr -G -O3 -r
make \$MAKEFLAGS && make install
cd /sources; rm -rf bc-*/

# -----------------------------------------------------------------------
# FLEX
# -----------------------------------------------------------------------
build "Flex"
tar -xf flex-*.tar.gz; cd flex-*/
./configure            \
    --prefix=/usr      \
    --docdir=/usr/share/doc/flex \
    --disable-static
make \$MAKEFLAGS && make install
ln -sv flex   /usr/bin/lex
ln -sv flex.1 /usr/share/man/man1/lex.1
cd /sources; rm -rf flex-*/

# -----------------------------------------------------------------------
# TCL
# -----------------------------------------------------------------------
build "Tcl"
tar -xf tcl*-src.tar.gz; cd tcl*/
SRCDIR=\$(pwd)
cd unix
./configure --prefix=/usr --mandir=/usr/share/man
make \$MAKEFLAGS
sed -e "s|{\$SRCDIR}/unix|\${installdir}|" \
    -e "s|{\$SRCDIR}|\${installdir}/include|" \
    -i tclConfig.sh
sed -e "s|{\$SRCDIR}/unix/pkgs/tdbc1.*}|{\${installdir}/lib/tdbc1&}|" \
    -i pkgs/tdbc1.*/tdbcConfig.sh 2>/dev/null || true
sed -e "s|{\$SRCDIR}/unix/pkgs/itcl4.*}|{\${installdir}/lib/itcl4&}|" \
    -i pkgs/itcl4.*/itclConfig.sh 2>/dev/null || true
make install
chmod -v u+w /usr/lib/libtcl*.so
make install-private-headers
ln -sfv tclsh8.6 /usr/bin/tclsh 2>/dev/null || true
mv /usr/share/man/man3/{Thread,Tcl_Thread}.3
cd /sources; rm -rf tcl*/

# -----------------------------------------------------------------------
# EXPECT
# -----------------------------------------------------------------------
build "Expect"
tar -xf expect*.tar.gz; cd expect*/
python3 -c 'from pty import spawn; spawn(["echo", "ok"])' 2>/dev/null || true
patch -Np1 -i /sources/expect-*gcc14*.patch 2>/dev/null || true
./configure                 \
    --prefix=/usr           \
    --with-tcl=/usr/lib     \
    --enable-shared         \
    --mandir=/usr/share/man \
    --with-tclinclude=/usr/include
make \$MAKEFLAGS && make install
ln -svf expect*/libexpect*.so /usr/lib 2>/dev/null || true
cd /sources; rm -rf expect*/

# -----------------------------------------------------------------------
# DEJAGNU
# -----------------------------------------------------------------------
build "DejaGNU"
tar -xf dejagnu-*.tar.gz; cd dejagnu-*/
mkdir -v build && cd build
../configure --prefix=/usr
make install
cd /sources; rm -rf dejagnu-*/

# -----------------------------------------------------------------------
# PKGCONF
# -----------------------------------------------------------------------
build "Pkgconf"
tar -xf pkgconf-*.tar.xz; cd pkgconf-*/
./configure              \
    --prefix=/usr        \
    --disable-static     \
    --docdir=/usr/share/doc/pkgconf
make \$MAKEFLAGS && make install
ln -sv pkgconf   /usr/bin/pkg-config
ln -sv pkgconf.1 /usr/share/man/man1/pkg-config.1
cd /sources; rm -rf pkgconf-*/

# -----------------------------------------------------------------------
# BINUTILS
# -----------------------------------------------------------------------
build "Binutils"
tar -xf binutils-*.tar.xz; cd binutils-*/
mkdir -v build && cd build
../configure              \
    --prefix=/usr         \
    --sysconfdir=/etc     \
    --enable-gold         \
    --enable-ld=default   \
    --enable-plugins      \
    --enable-shared       \
    --disable-werror      \
    --enable-64-bit-bfd   \
    --enable-new-dtags    \
    --with-system-zlib    \
    --enable-default-hash-style=gnu
make tooldir=/usr \$MAKEFLAGS
make tooldir=/usr install
rm -fv /usr/lib/lib{bfd,ctf,ctf-nobfd,gprofng,opcodes,sframe}.a
cd /sources; rm -rf binutils-*/

# -----------------------------------------------------------------------
# GMP
# -----------------------------------------------------------------------
build "GMP"
tar -xf gmp-*.tar.xz; cd gmp-*/
./configure              \
    --prefix=/usr        \
    --enable-cxx         \
    --disable-static     \
    --docdir=/usr/share/doc/gmp
make \$MAKEFLAGS && make install
cd /sources; rm -rf gmp-*/

# -----------------------------------------------------------------------
# MPFR
# -----------------------------------------------------------------------
build "MPFR"
tar -xf mpfr-*.tar.xz; cd mpfr-*/
./configure              \
    --prefix=/usr        \
    --disable-static     \
    --enable-thread-safe \
    --docdir=/usr/share/doc/mpfr
make \$MAKEFLAGS && make install
cd /sources; rm -rf mpfr-*/

# -----------------------------------------------------------------------
# MPC
# -----------------------------------------------------------------------
build "MPC"
tar -xf mpc-*.tar.gz; cd mpc-*/
./configure              \
    --prefix=/usr        \
    --disable-static     \
    --docdir=/usr/share/doc/mpc
make \$MAKEFLAGS && make install
cd /sources; rm -rf mpc-*/

# -----------------------------------------------------------------------
# ATTR
# -----------------------------------------------------------------------
build "Attr"
tar -xf attr-*.tar.gz; cd attr-*/
./configure              \
    --prefix=/usr        \
    --disable-static     \
    --sysconfdir=/etc    \
    --docdir=/usr/share/doc/attr
make \$MAKEFLAGS && make install
cd /sources; rm -rf attr-*/

# -----------------------------------------------------------------------
# ACL
# -----------------------------------------------------------------------
build "Acl"
tar -xf acl-*.tar.xz; cd acl-*/
./configure              \
    --prefix=/usr        \
    --disable-static     \
    --docdir=/usr/share/doc/acl
make \$MAKEFLAGS && make install
cd /sources; rm -rf acl-*/

# -----------------------------------------------------------------------
# LIBCAP
# -----------------------------------------------------------------------
build "Libcap"
tar -xf libcap-*.tar.xz; cd libcap-*/
sed -i '/install -m.*STA/d' libcap/Makefile
make prefix=/usr lib=lib \$MAKEFLAGS
make prefix=/usr lib=lib install
cd /sources; rm -rf libcap-*/

# -----------------------------------------------------------------------
# LIBXCRYPT
# -----------------------------------------------------------------------
build "Libxcrypt"
tar -xf libxcrypt-*.tar.xz; cd libxcrypt-*/
./configure              \
    --prefix=/usr        \
    --enable-hashes=strong,glibc \
    --enable-obsolete-api=no \
    --disable-static     \
    --disable-failure-tokens
make \$MAKEFLAGS && make install
cd /sources; rm -rf libxcrypt-*/

# -----------------------------------------------------------------------
# SHADOW
# -----------------------------------------------------------------------
build "Shadow"
tar -xf shadow-*.tar.xz; cd shadow-*/
sed -i 's/groups\$(EXEEXT) //' src/Makefile.in
find man -name 'groups.1' -delete
sed -e 's:#ENCRYPT_METHOD DES:ENCRYPT_METHOD YESCRYPT:' \
    -e 's:/var/spool/mail:/var/mail:'                   \
    -e '/PATH=/{s@/sbin:@@;s@/bin:@@}'                 \
    -i etc/login.defs
touch /usr/bin/passwd
./configure                          \
    --sysconfdir=/etc                \
    --disable-static                 \
    --with-{b,yes}crypt              \
    --without-libbsd                 \
    --with-group-name-max-length=32
make \$MAKEFLAGS && make exec_prefix=/usr install
make -C man install-man
pwconv && grpconv
mkdir -p /etc/default
useradd -D --gid 999
sed -i '/MAIL/s/yes/no/' /etc/default/useradd
passwd -e root 2>/dev/null || true
cd /sources; rm -rf shadow-*/

# -----------------------------------------------------------------------
# GCC (Full)
# -----------------------------------------------------------------------
build "GCC"
tar -xf gcc-*.tar.xz; cd gcc-*/
tar -xf /sources/mpfr-*.tar.xz; mv mpfr-*/ mpfr
tar -xf /sources/gmp-*.tar.xz;  mv gmp-*/  gmp
tar -xf /sources/mpc-*.tar.gz;  mv mpc-*/  mpc
case \$(uname -m) in
  x86_64)
    sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
  ;;
esac
mkdir -v build && cd build
../configure                   \
    --prefix=/usr              \
    LD=ld                      \
    --enable-languages=c,c++   \
    --enable-default-pie       \
    --enable-default-ssp       \
    --enable-host-pie          \
    --disable-multilib         \
    --disable-bootstrap        \
    --disable-fixincludes      \
    --with-system-zlib
make \$MAKEFLAGS && make install

# Fix install paths
ln -svr /usr/bin/cpp /usr/lib
ln -sfv ../../libexec/gcc/\$(uname -m)-pc-linux-gnu/*/liblto_plugin.so \
        /usr/lib/bfd-plugins/ 2>/dev/null || true

# Sanity check
echo 'int main(){}' > dummy.c
cc dummy.c -v -Wl,--verbose &> dummy.log
readelf -l a.out | grep ': /lib' || echo "GCC sanity: check dummy.log"
rm -v dummy.c a.out dummy.log

mkdir -pv /usr/share/gdb/auto-load/usr/lib
mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib 2>/dev/null || true
cd /sources; rm -rf gcc-*/

# -----------------------------------------------------------------------
# NCURSES
# -----------------------------------------------------------------------
build "Ncurses"
tar -xf ncurses-*.tar.gz; cd ncurses-*/
./configure              \
    --prefix=/usr        \
    --mandir=/usr/share/man \
    --with-shared        \
    --without-debug      \
    --without-normal     \
    --with-cxx-shared    \
    --enable-pc-files    \
    --with-pkg-config-libdir=/usr/lib/pkgconfig \
    --enable-widec
make \$MAKEFLAGS && make install
for lib in ncurses form panel menu; do
  ln -sfv lib\${lib}w.so /usr/lib/lib\${lib}.so
  ln -sfv \${lib}w.pc /usr/lib/pkgconfig/\${lib}.pc
done
ln -sfv libncursesw.so /usr/lib/libcurses.so
cd /sources; rm -rf ncurses-*/

# -----------------------------------------------------------------------
# SED
# -----------------------------------------------------------------------
build "Sed"
tar -xf sed-*.tar.xz; cd sed-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf sed-*/

# -----------------------------------------------------------------------
# PSMISC
# -----------------------------------------------------------------------
build "Psmisc"
tar -xf psmisc-*.tar.xz; cd psmisc-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf psmisc-*/

# -----------------------------------------------------------------------
# GETTEXT
# -----------------------------------------------------------------------
build "Gettext"
tar -xf gettext-*.tar.xz; cd gettext-*/
./configure              \
    --prefix=/usr        \
    --disable-static     \
    --docdir=/usr/share/doc/gettext
make \$MAKEFLAGS && make install
chmod -v 0755 /usr/lib/preloadable_libintl.so 2>/dev/null || true
cd /sources; rm -rf gettext-*/

# -----------------------------------------------------------------------
# BISON
# -----------------------------------------------------------------------
build "Bison"
tar -xf bison-*.tar.xz; cd bison-*/
./configure              \
    --prefix=/usr        \
    --docdir=/usr/share/doc/bison
make \$MAKEFLAGS && make install
cd /sources; rm -rf bison-*/

# -----------------------------------------------------------------------
# GREP
# -----------------------------------------------------------------------
build "Grep"
tar -xf grep-*.tar.xz; cd grep-*/
sed -i "s/echo/#echo/" src/egrep.sh
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf grep-*/

# -----------------------------------------------------------------------
# BASH
# -----------------------------------------------------------------------
build "Bash"
tar -xf bash-*.tar.gz; cd bash-*/
./configure                  \
    --prefix=/usr            \
    --without-bash-malloc    \
    --with-installed-readline \
    --docdir=/usr/share/doc/bash
make \$MAKEFLAGS && make install
cd /sources; rm -rf bash-*/

# -----------------------------------------------------------------------
# LIBTOOL
# -----------------------------------------------------------------------
build "Libtool"
tar -xf libtool-*.tar.xz; cd libtool-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
rm -fv /usr/lib/libltdl.a
cd /sources; rm -rf libtool-*/

# -----------------------------------------------------------------------
# GDBM
# -----------------------------------------------------------------------
build "GDBM"
tar -xf gdbm-*.tar.gz; cd gdbm-*/
./configure              \
    --prefix=/usr        \
    --disable-static     \
    --enable-libgdbm-compat
make \$MAKEFLAGS && make install
cd /sources; rm -rf gdbm-*/

# -----------------------------------------------------------------------
# GPERF
# -----------------------------------------------------------------------
build "Gperf"
tar -xf gperf-*.tar.gz; cd gperf-*/
./configure --prefix=/usr --docdir=/usr/share/doc/gperf
make \$MAKEFLAGS && make install
cd /sources; rm -rf gperf-*/

# -----------------------------------------------------------------------
# EXPAT
# -----------------------------------------------------------------------
build "Expat"
tar -xf expat-*.tar.xz; cd expat-*/
./configure              \
    --prefix=/usr        \
    --disable-static     \
    --docdir=/usr/share/doc/expat
make \$MAKEFLAGS && make install
cd /sources; rm -rf expat-*/

# -----------------------------------------------------------------------
# INETUTILS
# -----------------------------------------------------------------------
build "Inetutils"
tar -xf inetutils-*.tar.xz; cd inetutils-*/
sed -i 's/def HAVE_TERMCAP_TGETENT/ 1/' telnet/telnet.c
./configure              \
    --prefix=/usr        \
    --bindir=/usr/bin    \
    --localstatedir=/var \
    --disable-logger     \
    --disable-whois      \
    --disable-rcp        \
    --disable-rexec      \
    --disable-rlogin     \
    --disable-rsh        \
    --disable-servers
make \$MAKEFLAGS && make install
mv -v /usr/{,s}bin/ifconfig 2>/dev/null || true
cd /sources; rm -rf inetutils-*/

# -----------------------------------------------------------------------
# LESS
# -----------------------------------------------------------------------
build "Less"
tar -xf less-*.tar.gz; cd less-*/
./configure --prefix=/usr --sysconfdir=/etc
make \$MAKEFLAGS && make install
cd /sources; rm -rf less-*/

# -----------------------------------------------------------------------
# PERL
# -----------------------------------------------------------------------
build "Perl"
tar -xf perl-*.tar.xz; cd perl-*/
export BUILD_ZLIB=False
export BUILD_BZIP2=0
sh Configure -des                                  \
             -Dprefix=/usr                         \
             -Dvendorprefix=/usr                   \
             -Dpager="/usr/bin/less -isR"          \
             -Dman1dir=/usr/share/man/man1         \
             -Dman3dir=/usr/share/man/man3
make \$MAKEFLAGS && make install
unset BUILD_ZLIB BUILD_BZIP2
cd /sources; rm -rf perl-*/

# -----------------------------------------------------------------------
# XML-PARSER
# -----------------------------------------------------------------------
build "XML::Parser"
tar -xf XML-Parser-*.tar.gz; cd XML-Parser-*/
perl Makefile.PL
make \$MAKEFLAGS && make install
cd /sources; rm -rf XML-Parser-*/

# -----------------------------------------------------------------------
# INTLTOOL
# -----------------------------------------------------------------------
build "Intltool"
tar -xf intltool-*.tar.gz; cd intltool-*/
sed -i 's:\\\${:\\\$\\{:' intltool-update.in
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf intltool-*/

# -----------------------------------------------------------------------
# AUTOCONF
# -----------------------------------------------------------------------
build "Autoconf"
tar -xf autoconf-*.tar.xz; cd autoconf-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf autoconf-*/

# -----------------------------------------------------------------------
# AUTOMAKE
# -----------------------------------------------------------------------
build "Automake"
tar -xf automake-*.tar.xz; cd automake-*/
./configure --prefix=/usr --docdir=/usr/share/doc/automake
make \$MAKEFLAGS && make install
cd /sources; rm -rf automake-*/

# -----------------------------------------------------------------------
# OPENSSL
# -----------------------------------------------------------------------
build "OpenSSL"
tar -xf openssl-*.tar.gz; cd openssl-*/
./config              \
    --prefix=/usr     \
    --openssldir=/etc/ssl \
    --libdir=lib      \
    shared            \
    zlib-dynamic
make \$MAKEFLAGS
sed -i '/INSTALL_LIBS/s/libcrypto.a libssl.a//' Makefile
make MANSUFFIX=ssl install
cd /sources; rm -rf openssl-*/

# -----------------------------------------------------------------------
# KMOD
# -----------------------------------------------------------------------
build "Kmod"
tar -xf kmod-*.tar.xz; cd kmod-*/
./configure               \
    --prefix=/usr         \
    --sysconfdir=/etc     \
    --with-openssl        \
    --with-xz             \
    --with-zstd           \
    --with-zlib
make \$MAKEFLAGS && make install
for target in depmod insmod modinfo modprobe rmmod; do
  ln -sfv ../bin/kmod /usr/sbin/\$target
done
ln -sfv kmod /usr/bin/lsmod
cd /sources; rm -rf kmod-*/

# -----------------------------------------------------------------------
# ELFUTILS (libelf)
# -----------------------------------------------------------------------
build "Elfutils"
tar -xf elfutils-*.tar.bz2; cd elfutils-*/
./configure               \
    --prefix=/usr         \
    --sysconfdir=/etc     \
    --disable-debuginfod  \
    --enable-libdebuginfod=dummy
make \$MAKEFLAGS && make install
rm -v /usr/lib/libelf.a
cd /sources; rm -rf elfutils-*/

# -----------------------------------------------------------------------
# LIBFFI
# -----------------------------------------------------------------------
build "Libffi"
tar -xf libffi-*.tar.gz; cd libffi-*/
./configure              \
    --prefix=/usr        \
    --disable-static     \
    --with-gcc-arch=native
make \$MAKEFLAGS && make install
cd /sources; rm -rf libffi-*/

# -----------------------------------------------------------------------
# PYTHON 3
# -----------------------------------------------------------------------
build "Python 3"
tar -xf Python-3.*.tar.xz; cd Python-3.*/
./configure                  \
    --prefix=/usr            \
    --enable-shared          \
    --with-system-expat      \
    --enable-optimizations
make \$MAKEFLAGS && make install
cat > /etc/pip.conf << "EOF2"
[global]
root-user-action = ignore
disable-pip-version-check = true
EOF2
cd /sources; rm -rf Python-3.*/

# -----------------------------------------------------------------------
# FLIT-CORE (Python packaging)
# -----------------------------------------------------------------------
build "Flit-Core"
tar -xf flit_core-*.tar.gz 2>/dev/null && cd flit_core-*/ && \
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps \$PWD && \
    pip3 install --no-index --find-links dist flit_core && \
    cd /sources && rm -rf flit_core-*/ 2>/dev/null || true

# -----------------------------------------------------------------------
# WHEEL
# -----------------------------------------------------------------------
build "Wheel"
tar -xf wheel-*.tar.gz 2>/dev/null && cd wheel-*/ && \
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps \$PWD && \
    pip3 install --no-index --find-links dist wheel && \
    cd /sources && rm -rf wheel-*/ 2>/dev/null || true

# -----------------------------------------------------------------------
# NINJA
# -----------------------------------------------------------------------
build "Ninja"
tar -xf ninja-*.tar.gz; cd ninja-*/
python3 configure.py --bootstrap
install -vm755 ninja /usr/bin/
install -vDm644 misc/bash-completion /usr/share/bash-completion/completions/ninja
cd /sources; rm -rf ninja-*/

# -----------------------------------------------------------------------
# MESON
# -----------------------------------------------------------------------
build "Meson"
tar -xf meson-*.tar.gz; cd meson-*/
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps \$PWD
pip3 install --no-index --find-links dist meson
install -vDm644 data/shell-completions/bash/meson /usr/share/bash-completion/completions/meson
cd /sources; rm -rf meson-*/

# -----------------------------------------------------------------------
# COREUTILS
# -----------------------------------------------------------------------
build "Coreutils"
tar -xf coreutils-*.tar.xz; cd coreutils-*/
patch -Np1 -i /sources/coreutils-*-i18n-*.patch 2>/dev/null || true
autoreconf -fiv 2>/dev/null || true
FORCE_UNSAFE_CONFIGURE=1 ./configure \
    --prefix=/usr            \
    --enable-no-install-program=kill,uptime
make \$MAKEFLAGS && make install
mv -v /usr/bin/chroot /usr/sbin
mv -v /usr/share/man/man1/chroot.1 /usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/' /usr/share/man/man8/chroot.8
cd /sources; rm -rf coreutils-*/

# -----------------------------------------------------------------------
# CHECK
# -----------------------------------------------------------------------
build "Check"
tar -xf check-*.tar.gz 2>/dev/null && cd check-*/ && \
    ./configure --prefix=/usr --disable-static && \
    make \$MAKEFLAGS && make install && \
    cd /sources && rm -rf check-*/ 2>/dev/null || true

# -----------------------------------------------------------------------
# DIFFUTILS
# -----------------------------------------------------------------------
build "Diffutils"
tar -xf diffutils-*.tar.xz; cd diffutils-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf diffutils-*/

# -----------------------------------------------------------------------
# GAWK
# -----------------------------------------------------------------------
build "Gawk"
tar -xf gawk-*.tar.xz; cd gawk-*/
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf gawk-*/

# -----------------------------------------------------------------------
# FINDUTILS
# -----------------------------------------------------------------------
build "Findutils"
tar -xf findutils-*.tar.xz; cd findutils-*/
./configure --prefix=/usr --localstatedir=/var/lib/locate
make \$MAKEFLAGS && make install
cd /sources; rm -rf findutils-*/

# -----------------------------------------------------------------------
# GROFF
# -----------------------------------------------------------------------
build "Groff"
tar -xf groff-*.tar.gz; cd groff-*/
PAGE=A4 ./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf groff-*/

# -----------------------------------------------------------------------
# GRUB
# -----------------------------------------------------------------------
build "GRUB"
tar -xf grub-*.tar.xz; cd grub-*/
./configure                    \
    --prefix=/usr              \
    --sysconfdir=/etc          \
    --disable-efiemu           \
    --with-grub-mkfont=no      \
    --target=x86_64            \
    --with-platform=efi        \
    --disable-werror
make \$MAKEFLAGS && make install
mv -v /etc/bash_completion.d/grub /usr/share/bash-completion/completions/grub 2>/dev/null || true
cd /sources; rm -rf grub-*/

# -----------------------------------------------------------------------
# GZIP
# -----------------------------------------------------------------------
build "Gzip"
tar -xf gzip-*.tar.xz; cd gzip-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf gzip-*/

# -----------------------------------------------------------------------
# IPROUTE2
# -----------------------------------------------------------------------
build "IPRoute2"
tar -xf iproute2-*.tar.xz; cd iproute2-*/
sed -i /ARPD/d Makefile
rm -fv man/man8/arpd.8
make NETNS_RUN_DIR=/run/netns \$MAKEFLAGS
make SBINDIR=/usr/sbin install
mkdir -pv             /usr/share/doc/iproute2
cp -v COPYING README* /usr/share/doc/iproute2
cd /sources; rm -rf iproute2-*/

# -----------------------------------------------------------------------
# KBD
# -----------------------------------------------------------------------
build "Kbd"
tar -xf kbd-*.tar.xz; cd kbd-*/
patch -Np1 -i /sources/kbd-*-backspace-1.patch 2>/dev/null || true
sed -i '/RESIZECONS_PROGS=/s/yes/no/' configure
sed -i 's/resizecons.8 //' docs/man/man8/Makefile.in
./configure --prefix=/usr --disable-vlock
make \$MAKEFLAGS && make install
cd /sources; rm -rf kbd-*/

# -----------------------------------------------------------------------
# LIBPIPELINE
# -----------------------------------------------------------------------
build "Libpipeline"
tar -xf libpipeline-*.tar.gz; cd libpipeline-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf libpipeline-*/

# -----------------------------------------------------------------------
# MAKE
# -----------------------------------------------------------------------
build "Make"
tar -xf make-*.tar.gz; cd make-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf make-*/

# -----------------------------------------------------------------------
# PATCH
# -----------------------------------------------------------------------
build "Patch"
tar -xf patch-*.tar.xz; cd patch-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf patch-*/

# -----------------------------------------------------------------------
# TAR
# -----------------------------------------------------------------------
build "Tar"
tar -xf tar-*.tar.xz; cd tar-*/
FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr
make \$MAKEFLAGS && make install
cd /sources; rm -rf tar-*/

# -----------------------------------------------------------------------
# TEXINFO
# -----------------------------------------------------------------------
build "Texinfo"
tar -xf texinfo-*.tar.xz; cd texinfo-*/
./configure --prefix=/usr
make \$MAKEFLAGS && make install
make TEXMF=/usr/share/texmf install-tex 2>/dev/null || true
cd /sources; rm -rf texinfo-*/

# -----------------------------------------------------------------------
# VIM
# -----------------------------------------------------------------------
build "Vim"
tar -xf vim-*.tar.gz; cd vim-*/
echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
./configure --prefix=/usr
make \$MAKEFLAGS && make install
ln -sv vim /usr/bin/vi
for L in  /usr/share/man/{,*/}man1/ex.1; do
    ln -sfv vim.1 \$(dirname \$L)/ex.1
done
cat > /etc/vimrc << "EOF2"
source \$VIMRUNTIME/defaults.vim
let skip_defaults_vim=1
set nocompatible
syntax on
set background=dark
EOF2
cd /sources; rm -rf vim-*/

# -----------------------------------------------------------------------
# MARKDOWNLINT (optional — skip if not present)
# -----------------------------------------------------------------------
build "MarkupSafe (Python)"
tar -xf MarkupSafe-*.tar.gz 2>/dev/null && cd MarkupSafe-*/ && \
    pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps \$PWD && \
    pip3 install --no-index --find-links dist markupsafe && \
    cd /sources && rm -rf MarkupSafe-*/ 2>/dev/null || true

# -----------------------------------------------------------------------
# UDEV (from systemd sources)
# -----------------------------------------------------------------------
build "Udev (systemd)"
tar -xf systemd-*.tar.gz; cd systemd-*/
sed -i -e 's/GROUP="render"/GROUP="video"/'    \
       -e 's/GROUP="sgx", //'                  \
       rules.d/50-udev-default.rules.in
sed '/systemd-sysctl/s/.*//' -i rules.d/99-systemd.rules.in
sed '/NETWORK_DIRS/s/systemd/udev/' -i src/basic/path-lookup.c 2>/dev/null || true
mkdir -v build && cd build
meson setup ..               \
    --prefix=/usr            \
    --buildtype=release      \
    -D mode=release          \
    -D dev-kvm-mode=0660     \
    -D link-udev-shared=false \
    -D logind=false          \
    -D vconsole=false
ninja udevadm systemd-hwdb \
      \$(grep -o 'build src/udev[^ ]*' build.ninja | awk '{ print \$2 }') \
      \$(realpath libudev.so --relative-to .)
install udevadm                          /usr/bin/
install systemd-hwdb                     /usr/bin/udev-hwdb
ln -sfv ../bin/udevadm                   /usr/sbin/udevd
cp -av libudev.so{,*[0-9]}              /usr/lib/
install -D -m644 ../src/libudev/libudev.h /usr/include/libudev.h
install -D -m644 ../src/udev/*.pc        /usr/lib/pkgconfig/
install -D -m644 ../src/udev/udev.conf   /etc/udev/udev.conf
install -d -m755 /etc/udev/{hwdb,rules}.d
install -d -m755 /usr/{lib,share}/udev/{hwdb,rules}.d
install         ../rules.d/*.rules /usr/lib/udev/rules.d/
install         rules.d/*.rules    /usr/lib/udev/rules.d/ 2>/dev/null || true
install -d /usr/lib/udev/rules.d
udev-hwdb update
cd /sources; rm -rf systemd-*/

# -----------------------------------------------------------------------
# MAN-DB
# -----------------------------------------------------------------------
build "Man-DB"
tar -xf man-db-*.tar.xz; cd man-db-*/
./configure                   \
    --prefix=/usr             \
    --docdir=/usr/share/doc/man-db \
    --sysconfdir=/etc         \
    --disable-setuid          \
    --enable-cache-owner=bin  \
    --with-browser=/usr/bin/lynx \
    --with-vgrind=/usr/bin/vgrind \
    --with-grap=/usr/bin/grap
make \$MAKEFLAGS && make install
cd /sources; rm -rf man-db-*/

# -----------------------------------------------------------------------
# PROCPS-NG
# -----------------------------------------------------------------------
build "Procps-ng"
tar -xf procps-ng-*.tar.xz; cd procps-ng-*/
./configure                \
    --prefix=/usr          \
    --docdir=/usr/share/doc/procps-ng \
    --disable-static       \
    --disable-kill
make \$MAKEFLAGS && make install
cd /sources; rm -rf procps-ng-*/

# -----------------------------------------------------------------------
# UTIL-LINUX
# -----------------------------------------------------------------------
build "Util-linux"
tar -xf util-linux-*.tar.xz; cd util-linux-*/
mkdir -pv /var/lib/hwclock
./configure                       \
    --bindir=/usr/bin             \
    --libdir=/usr/lib             \
    --runstatedir=/run            \
    --sbindir=/usr/sbin           \
    --disable-chfn-chsh           \
    --disable-login               \
    --disable-nologin             \
    --disable-su                  \
    --disable-setpriv             \
    --disable-runuser             \
    --disable-pylibmount          \
    --disable-static              \
    --disable-liblastlog2         \
    --without-python              \
    --without-systemd             \
    --without-systemdsystemunitdir \
    ADJTIME_PATH=/var/lib/hwclock/adjtime \
    --docdir=/usr/share/doc/util-linux
make \$MAKEFLAGS && make install
cd /sources; rm -rf util-linux-*/

# -----------------------------------------------------------------------
# E2FSPROGS
# -----------------------------------------------------------------------
build "E2fsprogs"
tar -xf e2fsprogs-*.tar.gz; cd e2fsprogs-*/
mkdir -v build && cd build
../configure                 \
    --prefix=/usr            \
    --sysconfdir=/etc        \
    --enable-elf-shlibs      \
    --disable-libblkid       \
    --disable-libuuid        \
    --disable-uuidd          \
    --disable-fsck
make \$MAKEFLAGS && make install
rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
gunzip -v /usr/share/info/libext2fs.info.gz
install-info --dir-file=/usr/share/info/dir /usr/share/info/libext2fs.info
cd /sources; rm -rf e2fsprogs-*/

# -----------------------------------------------------------------------
# SYSKLOGD (syslog)
# -----------------------------------------------------------------------
build "Sysklogd"
tar -xf sysklogd-*.tar.gz 2>/dev/null && cd sysklogd-*/ && \
    ./configure --prefix=/usr --sysconfdir=/etc && \
    make \$MAKEFLAGS && make install && \
    cd /sources && rm -rf sysklogd-*/ 2>/dev/null || true

# -----------------------------------------------------------------------
# SYSVINIT
# -----------------------------------------------------------------------
build "Sysvinit"
tar -xf sysvinit-*.tar.xz; cd sysvinit-*/
patch -Np1 -i /sources/sysvinit-*-consolidated-1.patch 2>/dev/null || true
make \$MAKEFLAGS && make install
cd /sources; rm -rf sysvinit-*/

echo -e "\n\033[0;32m[LFS] Full system build complete!\033[0m"
CHROOT_SCRIPT

  step "Entering chroot and building full system (this takes 2-8 hours)..."
  chroot "$LFS" /usr/bin/env -i   \
      HOME=/root                   \
      TERM="$TERM"                 \
      PS1='(lfs chroot) \u:\w\$ ' \
      PATH=/usr/bin:/usr/sbin      \
      MAKEFLAGS="-j$JOBS"          \
      /bin/bash --login /sources/build-system.sh 2>&1 | tee /var/log/lfs-system.log

  log "Phase 6 complete."
}

# =============================================================================
#  PHASE 7: KERNEL & BOOTLOADER
# =============================================================================
phase7_kernel_grub() {
  section "Phase 7: Linux Kernel & GRUB"

  cat > $LFS/sources/build-kernel.sh << KERNEL_SCRIPT
#!/bin/bash
set -e
cd /sources

echo -e "\n\033[0;36m  --> Building Linux Kernel\033[0m"
tar -xf linux-*.tar.xz; cd linux-*/

make mrproper
make defconfig

# Enable important features for USB boot
scripts/config --enable CONFIG_EFI_STUB
scripts/config --enable CONFIG_EXT4_FS
scripts/config --enable CONFIG_USB_SUPPORT
scripts/config --enable CONFIG_USB_XHCI_HCD
scripts/config --enable CONFIG_USB_EHCI_HCD
scripts/config --enable CONFIG_USB_OHCI_HCD
scripts/config --enable CONFIG_USB_MASS_STORAGE
scripts/config --enable CONFIG_BLK_DEV_SD
scripts/config --enable CONFIG_ATA
scripts/config --enable CONFIG_ATA_PIIX
scripts/config --enable CONFIG_SATA_AHCI
scripts/config --enable CONFIG_NETDEVICES
scripts/config --enable CONFIG_NET_CORE
scripts/config --enable CONFIG_INET
scripts/config --enable CONFIG_DEVTMPFS
scripts/config --enable CONFIG_DEVTMPFS_MOUNT
scripts/config --enable CONFIG_TMPFS
scripts/config --enable CONFIG_PROC_FS
scripts/config --enable CONFIG_SYSFS
scripts/config --enable CONFIG_VIRTIO_PCI
scripts/config --enable CONFIG_VIRTIO_BLK

make -j$JOBS
make modules_install

# Install kernel
mkdir -pv /boot
cp -iv arch/x86_64/boot/bzImage /boot/vmlinuz-lfs-$LFS_VERSION
cp -iv System.map /boot/System.map-lfs
cp -iv .config /boot/config-lfs
install -dv /usr/share/doc/linux
cp -rv Documentation/* /usr/share/doc/linux 2>/dev/null || true

cd /sources; rm -rf linux-*/

echo -e "\n\033[0;36m  --> Installing GRUB for EFI\033[0m"
grub-install                          \
    --target=x86_64-efi               \
    --efi-directory=/boot/efi         \
    --bootloader-id=LFS               \
    --removable                       \
    --recheck

# GRUB config
cat > /boot/grub/grub.cfg << "EOF"
set default=0
set timeout=10
set gfxpayload=keep

insmod part_gpt
insmod ext2
insmod fat

menuentry "Linux From Scratch $LFS_VERSION" {
    linux /boot/vmlinuz-lfs-$LFS_VERSION root=UUID=$ROOT_UUID rw quiet
    echo "Loading LFS kernel..."
}

menuentry "Linux From Scratch (verbose)" {
    linux /boot/vmlinuz-lfs-$LFS_VERSION root=UUID=$ROOT_UUID rw
}
EOF

echo -e "\033[0;32m[LFS] Kernel and GRUB installed.\033[0m"
KERNEL_SCRIPT

  chroot "$LFS" /usr/bin/env -i   \
      HOME=/root                   \
      TERM="$TERM"                 \
      PATH=/usr/bin:/usr/sbin      \
      /bin/bash --login /sources/build-kernel.sh 2>&1 | tee /var/log/lfs-kernel.log

  log "Phase 7 complete."
}

# =============================================================================
#  PHASE 8: SYSTEM CONFIGURATION
# =============================================================================
phase8_sysconfig() {
  section "Phase 8: System Configuration"

  step "Writing fstab..."
  cat > $LFS/etc/fstab << EOF
# /etc/fstab
UUID=$ROOT_UUID   /         ext4    defaults              1 1
UUID=$EFI_UUID    /boot/efi vfat    umask=0077            0 2
UUID=$SWAP_UUID   swap      swap    pri=1                 0 0
proc              /proc     proc    nosuid,noexec,nodev   0 0
sysfs             /sys      sysfs   nosuid,noexec,nodev   0 0
devpts            /dev/pts  devpts  gid=5,mode=620        0 0
tmpfs             /run      tmpfs   defaults              0 0
devtmpfs          /dev      devtmpfs mode=0755,nosuid     0 0
EOF

  step "Setting hostname..."
  echo "$LFS_HOSTNAME" > $LFS/etc/hostname

  step "Writing /etc/inittab..."
  cat > $LFS/etc/inittab << "EOF"
id:3:initdefault:
si::sysinit:/etc/rc.d/init.d/rcS
l0:0:wait:/etc/rc.d/rc 0
l1:S1:wait:/etc/rc.d/rc 1
l2:2:wait:/etc/rc.d/rc 2
l3:3:wait:/etc/rc.d/rc 3
l4:4:wait:/etc/rc.d/rc 4
l5:5:wait:/etc/rc.d/rc 5
l6:6:wait:/etc/rc.d/rc 6
ca:12345:ctrlaltdel:/sbin/shutdown -t1 -a -r now
su:S016:once:/sbin/sulogin
1:2345:respawn:/sbin/agetty --autologin root tty1 9600
2:2345:respawn:/sbin/agetty tty2 9600
3:2345:respawn:/sbin/agetty tty3 9600
EOF

  step "Writing /etc/sysconfig/clock..."
  cat > $LFS/etc/sysconfig/clock << "EOF"
UTC=1
CLOCKPARAMS=
EOF

  step "Writing /etc/profile..."
  cat > $LFS/etc/profile << "EOF"
for i in $(ls /etc/profile.d/*.sh 2>/dev/null); do
    source $i
done
export PS1='\u@\h:\w\$ '
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HISTSIZE=1000
export EDITOR=vim
EOF

  step "Writing /etc/issue and /etc/os-release..."
  cat > $LFS/etc/issue << EOF
Linux From Scratch $LFS_VERSION
Kernel \r on an \m (\l)
EOF

  cat > $LFS/etc/os-release << EOF
NAME="Linux From Scratch"
VERSION="$LFS_VERSION"
ID=lfs
PRETTY_NAME="Linux From Scratch $LFS_VERSION"
VERSION_CODENAME=LFS-USB
EOF

  step "Setting root password..."
  chroot "$LFS" /usr/bin/env -i   \
      HOME=/root                   \
      PATH=/usr/bin:/usr/sbin      \
      /bin/bash --login -c "echo 'root:$ROOT_PASS' | chpasswd"

  step "Writing /etc/inputrc..."
  cat > $LFS/etc/inputrc << "EOF"
set horizontal-scroll-mode Off
set meta-flag On
set input-meta On
set convert-meta Off
set output-meta On
set bell-style none
"\eOd": backward-word
"\eOc": forward-word
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\e[5~": beginning-of-history
"\e[6~": end-of-history
"\e[3~": delete-char
"\e[2~": quoted-insert
"\eOH": beginning-of-line
"\eOF": end-of-line
"\e[H": beginning-of-line
"\e[F": end-of-line
EOF

  log "Phase 8 complete."
}

# =============================================================================
#  PHASE 9: CLEANUP & UNMOUNT
# =============================================================================
phase9_cleanup() {
  section "Phase 9: Cleanup & Unmount"

  step "Removing temporary tools and lfs user..."
  rm -rf $LFS/tools
  rm -rf $LFS/sources/build-*.sh
  userdel -r lfs 2>/dev/null || true

  step "Stripping binaries (saves space)..."
  find $LFS/usr/lib -type f -name '*.a' -exec strip --strip-debug {} \; 2>/dev/null || true
  find $LFS/usr/{bin,sbin,lib} -type f \( -name '*.so*' -o -perm /111 \) \
       -exec strip --strip-unneeded {} \; 2>/dev/null || true

  step "Unmounting virtual filesystems..."
  umount -v $LFS/dev/pts  2>/dev/null || true
  umount -v $LFS/dev/shm  2>/dev/null || true
  umount -v $LFS/dev      2>/dev/null || true
  umount -v $LFS/proc     2>/dev/null || true
  umount -v $LFS/sys      2>/dev/null || true
  umount -v $LFS/run      2>/dev/null || true

  step "Unmounting USB partitions..."
  umount -v $LFS/boot/efi 2>/dev/null || true
  umount -v $LFS           2>/dev/null || true
  swapoff $SWAP_PART        2>/dev/null || true

  log "Phase 9 complete."
}

# =============================================================================
#  MAIN — RUN ALL PHASES
# =============================================================================
main() {
  clear
  echo -e "${BOLD}${BLUE}"
  echo "  ██╗     ███████╗███████╗    ██████╗ ██╗   ██╗██╗██╗     ██████╗ "
  echo "  ██║     ██╔════╝██╔════╝    ██╔══██╗██║   ██║██║██║     ██╔══██╗"
  echo "  ██║     █████╗  ███████╗    ██████╔╝██║   ██║██║██║     ██║  ██║"
  echo "  ██║     ██╔══╝  ╚════██║    ██╔══██╗██║   ██║██║██║     ██║  ██║"
  echo "  ███████╗██║     ███████║    ██████╔╝╚██████╔╝██║███████╗██████╔╝"
  echo "  ╚══════╝╚═╝     ╚══════╝    ╚═════╝  ╚═════╝ ╚═╝╚══════╝╚═════╝ "
  echo -e "${NC}"
  echo -e "  ${BOLD}Linux From Scratch $LFS_VERSION — USB Build Script${NC}"
  echo -e "  Target Drive : ${RED}$USB_DRIVE${NC}"
  echo -e "  Mount Point  : $LFS"
  echo -e "  Parallel Jobs: $JOBS"
  echo ""

  preflight_checks
  phase1_partition
  phase2_sources
  phase3_toolchain
  phase4_temp_tools
  phase5_chroot_setup
  phase6_full_system
  phase7_kernel_grub
  phase8_sysconfig
  phase9_cleanup

  echo ""
  echo -e "${BOLD}${GREEN}"
  echo "  =================================================="
  echo "   LFS Build Complete!"
  echo "  =================================================="
  echo -e "${NC}"
  echo "  Your Linux From Scratch system is on: $USB_DRIVE"
  echo "  Root password: $ROOT_PASS"
  echo ""
  echo "  To boot:"
  echo "  1. Insert USB into target machine"
  echo "  2. Enter BIOS/UEFI and select USB as boot device"
  echo "  3. Select 'Linux From Scratch $LFS_VERSION' from GRUB"
  echo ""
  echo "  Logs saved to:"
  echo "    /var/log/lfs-toolchain.log"
  echo "    /var/log/lfs-temptools.log"
  echo "    /var/log/lfs-system.log"
  echo "    /var/log/lfs-kernel.log"
  echo ""
}

main "$@"
