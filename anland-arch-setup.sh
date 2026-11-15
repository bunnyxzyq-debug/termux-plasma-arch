#!/data/data/com.termux/files/usr/bin/bash
# anland-arch-setup.sh
#
# KDE Plasma (Wayland, KGSL GPU acceleration) running natively in Termux via
# Anland, plus an Arch Linux ARM container (proot-distro) with yay. Apps you
# install in Arch show up in the Plasma Kickoff menu and draw on the same
# desktop with the Adreno GPU.
#
# Optionally also sets up an Ubuntu 26.04 container with its own Plasma desktop
# (Anland's prebuilt image + patched KWin/XWayland + the Ubuntu GPU driver).
# Only one desktop (native or Ubuntu) can be shown at a time.
#
# Run it in Termux itself (not inside a container):
#   bash anland-arch-setup.sh
#
# With no options it opens a menu: pick what to install, start or stop a
# desktop, open the Arch/Ubuntu shells, sync Kickoff. A copy of the script is
# kept as the "anland-menu" command, so the menu is always one word away.
#
# Options (skip the menu and install straight away; with no terminal and no
# options it installs native Plasma + the Arch container):
#   --no-arch       skip the Arch container
#   --ubuntu        also set up the Ubuntu 26.04 container
#   --debian        also set up the Debian 13 container
#   --ubuntu-only   only Anland + the Ubuntu container (no native Plasma, no Arch)
#   --debian-only   only Anland + the Debian container (no native Plasma, no Arch)
#   -h, --help      show this text
#
# Environment variables:
#   ARCH_USER      user created in Arch              (default: arch)
#   ARCH_NAME      proot-distro container name       (default: archlinux)
#   UBUNTU_NAME    Ubuntu container name             (default: ubuntu-anland)
#   DEBIAN_NAME    Debian container name             (default: debian-anland)
#   ANLAND_DIR     download/work folder              (default: ~/anland)
#   GITHUB_TOKEN   optional, avoids GitHub API rate limits
#
# Needs: Termux (GitHub or F-Droid build), aarch64 phone with an Adreno GPU
# (Snapdragon), Wi-Fi, about 6 GB free storage (more for each extra container).
#
# Commands this installs:
#   plasma          start native Plasma, then open the "Anland Termux" app
#   plasma-ubuntu   start the Ubuntu desktop instead (with --ubuntu)
#   plasma-debian   start the Debian desktop instead (with --debian)
#   plasma-stop     stop whichever desktop is running
#   archsh          shell in the Arch container as your user
#   ubuntush        shell in the Ubuntu container (root)
#   debiansh        shell in the Debian container (root)
#   ksync           rebuild the "[Arch]" Kickoff entries by hand
#   anland-menu     this script's menu
#
# Known issue: if kwin_wayland fails with "cannot locate symbol", Termux's Qt
# moved past the Anland KWin build. Wait for a new Anland release, then re-run
# this script. Check before upgrading: apt list --upgradable | grep -i qt
set -eu

# Absolute path of this script, taken before the script changes directory.
SELF=$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")
ARCH_USER_GIVEN=${ARCH_USER:-}
ARCH_USER=${ARCH_USER:-arch}
ARCH_NAME=${ARCH_NAME:-archlinux}
UBUNTU_NAME=${UBUNTU_NAME:-ubuntu-anland}
DEBIAN_NAME=${DEBIAN_NAME:-debian-anland}
# Anland's prebuilt Ubuntu 26.04 ("resolute") image with Plasma installed.
UBUNTU_IMAGE=ghcr.io/lfdevs/ubuntu:resolute-anland-plasma
# Ubuntu 26.04 uses XWayland 24.1.10; the release also lists the Debian one.
UBUNTU_XWAYLAND_RE='^xwayland_24\.1\.10.*_arm64\.deb$'
# Anland's prebuilt Debian 13 ("trixie") image with Plasma installed.
DEBIAN_IMAGE=ghcr.io/lfdevs/debian:trixie-anland-plasma
# Debian 13 uses XWayland 24.1.6.
DEBIAN_XWAYLAND_RE='^xwayland_24\.1\.6.*_arm64\.deb$'
WORK=${ANLAND_DIR:-$HOME/anland}
DO_NATIVE=1
DO_ARCH=1
DO_UBUNTU=0
DO_DEBIAN=0

for a in "$@"; do
  case $a in
    --no-arch) DO_ARCH=0 ;;
    --ubuntu) DO_UBUNTU=1 ;;
    --debian) DO_DEBIAN=1 ;;
    --ubuntu-only) DO_UBUNTU=1; DO_NATIVE=0; DO_ARCH=0 ;;
    --debian-only) DO_DEBIAN=1; DO_NATIVE=0; DO_ARCH=0 ;;
    -h|--help) sed -n '2,/^set -eu/{/^set -eu/!p}' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks ----
[ -n "${PREFIX:-}" ] && [ -d /data/data/com.termux ] \
  || die "Run this in Termux itself, not inside a container."
[ "$(id -u)" -ne 0 ] || die "Do not run this as root."
[ "$(uname -m)" = aarch64 ] || die "This only supports aarch64 phones."
[ -e /dev/kgsl-3d0 ] || warn "No Adreno GPU node found: the Anland GPU path needs a Snapdragon phone."

HDR=()
[ -n "${GITHUB_TOKEN:-}" ] && HDR=(-H "Authorization: Bearer $GITHUB_TOKEN")
gh_api() { curl -fsSL "${HDR[@]}" -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"; }
fetch()  { curl -fL --retry 3 -# -O "$1"; }
# URL of the newest mesa-for-android-container asset whose name matches regex $1.
# Searches recent releases (the "latest" one can be a Turnip-only release).
mesa_url() {
  gh_api "repos/lfdevs/mesa-for-android-container/releases?per_page=30" \
    | jq -r --arg re "$1" '[.[].assets[] | select(.name | test($re)) | .browser_download_url][0] // empty'
}

# Helper command that stops whichever Plasma desktop (native or Ubuntu) is
# running, so the other one can be started.
make_plasma_stop() {
  cat > "$PREFIX/bin/plasma-stop" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
pkill -f startplasma >/dev/null 2>&1 || true
pkill kwin_wayland >/dev/null 2>&1 || true
pkill plasmashell >/dev/null 2>&1 || true
killall anland >/dev/null 2>&1 || true
EOF
  chmod +x "$PREFIX/bin/plasma-stop"
}

# ------------------------------------------------------------------ menu ----
RAW_URL=https://raw.githubusercontent.com/bunnyxzyq-debug/termux-plasma-arch/main/anland-arch-setup.sh

have()  { [ -x "$PREFIX/bin/$1" ]; }
state() { if have "$1"; then printf 'installed'; else printf 'not installed'; fi; }
pause() { read -r -p "Press Enter to go back to the menu... " _ || true; }
clear_screen() { clear 2>/dev/null || true; }

# Run an installed command, or say that it still has to be installed.
run_cmd() {
  local name=$1; shift
  if have "$name"; then "$PREFIX/bin/$name" "$@" || true
  else warn "'$name' is not installed yet. Choose 'Install / update' first."
  fi
}

# Toggle screen for the install parts. Returns 0 to start, 1 to go back.
install_menu() {
  local c
  while :; do
    clear_screen
    printf '\n  Install / update\n  ----------------\n'
    printf '   [%s] 1  Native Plasma in Termux (GPU)\n' "$([ "$DO_NATIVE" = 1 ] && printf x || printf ' ')"
    printf '   [%s] 2  Arch Linux container + yay + Kickoff sync (needs 1)\n' "$([ "$DO_ARCH" = 1 ] && printf x || printf ' ')"
    printf '   [%s] 3  Ubuntu 26.04 desktop container\n' "$([ "$DO_UBUNTU" = 1 ] && printf x || printf ' ')"
    printf '   [%s] 4  Debian 13 desktop container\n' "$([ "$DO_DEBIAN" = 1 ] && printf x || printf ' ')"
    printf '\n  1-4 = tick / untick   g = go   b = back\n\n'
    read -r -p "Choose: " c || exit 0
    case $c in
      1) DO_NATIVE=$((1 - DO_NATIVE)); if [ "$DO_NATIVE" = 0 ]; then DO_ARCH=0; fi ;;
      2) DO_ARCH=$((1 - DO_ARCH)); if [ "$DO_ARCH" = 1 ]; then DO_NATIVE=1; fi ;;
      3) DO_UBUNTU=$((1 - DO_UBUNTU)) ;;
      4) DO_DEBIAN=$((1 - DO_DEBIAN)) ;;
      g|G)
        if [ $((DO_NATIVE + DO_ARCH + DO_UBUNTU + DO_DEBIAN)) -eq 0 ]; then
          warn "Tick at least one part."; sleep 1
        else
          return 0
        fi ;;
      b|B|0) return 1 ;;
    esac
  done
}

# Asks for the Arch username. Keeps the one a previous run set up, if any.
ask_arch_user() {
  local u old=""
  if [ -z "$ARCH_USER_GIVEN" ] && have archsh; then
    old=$(sed -n 's/.*--user \([a-z_][a-z0-9_-]*\).*/\1/p' "$PREFIX/bin/archsh" | head -n1)
    [ -z "$old" ] || ARCH_USER=$old
  fi
  while :; do
    read -r -p "Username for the Arch container [$ARCH_USER]: " u || exit 0
    u=${u:-$ARCH_USER}
    if [[ $u =~ ^[a-z_][a-z0-9_-]*$ ]]; then ARCH_USER=$u; return 0; fi
    warn "Use lowercase letters, digits, _ or -, starting with a letter."
  done
}

# Replace the installed menu with the newest script from GitHub.
update_self() {
  local tmp="$TMPDIR/anland-menu.new"
  if curl -fsSL -o "$tmp" "$RAW_URL" && bash -n "$tmp" 2>/dev/null \
     && grep -q 'anland-arch-setup' "$tmp"; then
    chmod +x "$tmp"
    mv -f "$tmp" "$PREFIX/bin/anland-menu"
    echo "Updated. Restarting the menu..."; sleep 1
    exec "$PREFIX/bin/anland-menu"
  fi
  rm -f "$tmp"
  warn "Could not download a valid update. Nothing was changed."
  pause
}

# Returns 0 when the user chose to install (DO_* are set), exits on Quit.
main_menu() {
  local c
  while :; do
    clear_screen
    printf '\n  Termux KDE Plasma + Arch + Ubuntu + Debian\n  ------------------------------------------\n'
    if [ -n "${WAYLAND_DISPLAY:-}" ]; then
      warn "You are inside a desktop: starting or stopping one here will close it. Use the Termux app."
    fi
    printf '   1) %-30s\n' "Install / update"
    printf '   2) %-30s (%s)\n' "Start native Plasma" "$(state plasma)"
    printf '   3) %-30s (%s)\n' "Start Ubuntu Plasma" "$(state plasma-ubuntu)"
    printf '   4) %-30s (%s)\n' "Start Debian Plasma" "$(state plasma-debian)"
    printf '   5) %-30s\n' "Stop the running desktop"
    printf '   6) %-30s (%s)\n' "Arch shell (yay)" "$(state archsh)"
    printf '   7) %-30s (%s)\n' "Ubuntu shell (apt)" "$(state ubuntush)"
    printf '   8) %-30s (%s)\n' "Debian shell (apt)" "$(state debiansh)"
    printf '   9) %-30s\n' "Sync Arch apps to Kickoff"
    printf '   u) %-30s\n' "Update this menu from GitHub"
    printf '   0) %-30s\n\n' "Quit"
    read -r -p "Choose: " c || exit 0
    case $c in
      1) if install_menu; then return 0; fi ;;
      2) echo "Starting Plasma. Open the Anland Termux app now."; run_cmd plasma; pause ;;
      3) echo "Starting Ubuntu Plasma. Open the Anland Termux app now."; run_cmd plasma-ubuntu; pause ;;
      4) echo "Starting Debian Plasma. Open the Anland Termux app now."; run_cmd plasma-debian; pause ;;
      5) run_cmd plasma-stop; echo "Stopped."; sleep 1 ;;
      6) run_cmd archsh ;;
      7) run_cmd ubuntush ;;
      8) run_cmd debiansh ;;
      9) run_cmd ksync; pause ;;
      u|U) update_self ;;
      0|q|Q) exit 0 ;;
    esac
  done
}

if [ "$#" -eq 0 ] && [ -t 0 ]; then
  main_menu
  if [ "$DO_ARCH" = 1 ]; then ask_arch_user; fi
fi

if [ "$DO_ARCH" = 1 ] && ! [[ $ARCH_USER =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  die "ARCH_USER must be a lowercase Linux username."
fi

# ------------------------------------------------------- Termux packages ----
export DEBIAN_FRONTEND=noninteractive
termux-wake-lock 2>/dev/null || true

PATCHED="xwayland mesa mesa-vulkan-icd-freedreno layer-shell-qt"

say "Updating Termux and installing packages"
if [ "$DO_NATIVE" = 1 ]; then
  # Hold already-installed patched packages first, so the upgrade below (and any
  # re-run after a failed run) cannot replace them with Termux's stock builds.
  for p in $PATCHED; do
    dpkg -s "$p" >/dev/null 2>&1 && apt-mark hold "$p" >/dev/null || true
  done
fi
pkg update -y
apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade
if [ "$DO_NATIVE" = 1 ]; then
  pkg install -y x11-repo
  pkg update -y
  pkg install -y curl jq proot-distro plasma-desktop konsole dolphin pipewire termux-api
else
  pkg install -y curl jq proot-distro termux-api
fi

# --------------------------------------------------- Anland + GPU driver ----
say "Finding the latest Anland release"
REL=$(gh_api repos/lfdevs/anland-termux/releases/latest) \
  || die "GitHub API request failed (rate limit? set GITHUB_TOKEN)."
TAG=$(jq -r .tag_name <<<"$REL")
pick() { jq -r --arg re "$1" '[.assets[] | select(.name | test($re)) | .browser_download_url][0] // empty' <<<"$REL"; }

DAEMON=$(pick '^anland_[0-9.]+(-[0-9]+)?_aarch64\.deb$')
if [ "${TERMUX_APP__APK_RELEASE:-}" = F_DROID ]; then
  APK=$(pick '^AnlandTermux-.*-compatible\.apk$')   # F-Droid / ZeroTermux build
else
  APK=$(pick '^AnlandTermux-[0-9.]+\.apk$')         # GitHub Termux build
fi
NEEDED="DAEMON APK"
if [ "$DO_NATIVE" = 1 ]; then
  XWAY=$(pick '^xwayland_.*_aarch64\.deb$')
  KWIN=$(pick '^kwin-anland_.*_aarch64\.deb$')
  NEEDED="$NEEDED XWAY KWIN"
fi
if [ "$DO_UBUNTU" = 1 ]; then
  UXWAY=$(pick "$UBUNTU_XWAYLAND_RE")
  UKWIN=$(pick '^kwin_anland-.*ubuntu.*\.zip$')
  NEEDED="$NEEDED UXWAY UKWIN"
fi
if [ "$DO_DEBIAN" = 1 ]; then
  DXWAY=$(pick "$DEBIAN_XWAYLAND_RE")
  DKWIN=$(pick '^kwin_anland-.*debian.*\.zip$')
  NEEDED="$NEEDED DXWAY DKWIN"
fi
for v in $NEEDED; do
  [ -n "${!v}" ] || die "Release $TAG has no $v asset (release layout changed?)."
done

if [ "$DO_NATIVE" = 1 ]; then
say "Finding matching LayerShellQt and Freedreno packages"
TAGS=$(gh_api "repos/lfdevs/termux-packages/releases?per_page=100" | jq -r '.[].tag_name') \
  || die "Could not list lfdevs/termux-packages releases."
LV=$(dpkg-query -W -f='${Version}' layer-shell-qt 2>/dev/null || true)
WANT="layer-shell-qt_${LV%%-*}-1"
if grep -qxF "$WANT" <<<"$TAGS"; then
  LTAG=$WANT
else
  LTAG=$(grep '^layer-shell-qt_' <<<"$TAGS" | head -n1 || true)
fi
FTAG=$(grep '^freedreno-' <<<"$TAGS" | grep -v -- '-weston$' | head -n1 || true)
[ -n "$LTAG" ] && [ -n "$FTAG" ] || die "Could not find LayerShellQt/Freedreno releases."
tag_debs() { gh_api "repos/lfdevs/termux-packages/releases/tags/$1" \
  | jq -r '.assets[] | select(.name | endswith(".deb")) | .browser_download_url'; }
LURLS=$(tag_debs "$LTAG") || die "Could not read release $LTAG."
FURLS=$(tag_debs "$FTAG") || die "Could not read release $FTAG."
fi

say "Downloading Anland $TAG${LTAG:+, $LTAG, $FTAG}"
rm -rf "$WORK/dl"; mkdir -p "$WORK/dl"; cd "$WORK/dl"
fetch "$DAEMON"
if [ "$DO_NATIVE" = 1 ]; then
  for u in "$XWAY" "$KWIN" $LURLS $FURLS; do fetch "$u"; done
fi

say "Installing"
# --allow-downgrades: Termux's repo can carry a newer layer-shell-qt/mesa than the
# patched builds, and the patched ones are the ones Anland needs.
reinst() {
  apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages \
    -o Dpkg::Options::=--force-confold "$@"
}
reinst ./anland_*_aarch64.deb
if [ "$DO_NATIVE" = 1 ]; then
reinst ./xwayland_*_aarch64.deb ./kwin-anland_*_aarch64.deb
reinst ./layer-shell-qt_*.deb
reinst ./mesa*.deb
# Keep Termux updates from replacing the patched packages.
apt-mark hold $PATCHED

say "Installing the 'plasma' command"
curl -fL -o "$WORK/startplasma-anland.sh" \
  https://github.com/lfdevs/anland-termux/raw/refs/heads/main/scripts/startplasma-anland.sh
chmod +x "$WORK/startplasma-anland.sh"
make_plasma_stop
cat > "$PREFIX/bin/plasma" <<EOF
#!$PREFIX/bin/bash
cd "$WORK"
plasma-stop
sleep 1
anland >/dev/null 2>&1 &
./startplasma-anland.sh
EOF
chmod +x "$PREFIX/bin/plasma"
fi

say "Downloading the Anland display app"
if [ ! -d "$HOME/storage/downloads" ]; then
  termux-setup-storage || true
  for _ in $(seq 30); do [ -d "$HOME/storage/downloads" ] && break; sleep 1; done
fi
if [ -d "$HOME/storage/downloads" ]; then
  APKFILE="$HOME/storage/downloads/$(basename "$APK")"
  curl -fL -# -o "$APKFILE" "$APK"
  termux-open "$APKFILE" || true
  echo "Install the app from the prompt or from Downloads: $(basename "$APKFILE")"
  echo "(If you had the other Anland variant installed, uninstall it first.)"
else
  warn "No storage access. Download and install this APK yourself: $APK"
fi

# ------------------------------------------------- Ubuntu and Debian part ----
# Ubuntu 26.04 and Debian 13 share one routine: Anland's prebuilt image, then the
# patched XWayland and KWin and the distro's build of the GPU driver (Mesa).
# args: label name image xwayland-deb kwin-zip mesa-asset-regex shell-cmd plasma-cmd
setup_container() {
  local label=$1 name=$2 image=$3 xway=$4 kwin=$5 mesa_re=$6 shcmd=$7 plcmd=$8
  local mesa udl

  say "Setting up the $label container '$name'"
  if ! proot-distro login "$name" -- true >/dev/null 2>&1; then
    proot-distro install "$image" --name "$name"
  fi

  say "Downloading Anland's patched XWayland/KWin for $label and its Mesa"
  mesa=$(mesa_url "$mesa_re")
  [ -n "$mesa" ] || die "No $label Mesa package found in mesa-for-android-container (rate limit? set GITHUB_TOKEN)."
  udl="$TMPDIR/container-setup"
  rm -rf "$udl"; mkdir -p "$udl"
  ( cd "$udl" && fetch "$xway" && fetch "$kwin" && fetch "$mesa" )

# Written to the shared tmp folder, which the container sees as /tmp.
cat > "$TMPDIR/container-root-setup.sh" <<'CT_EOF'
#!/bin/bash
set -eu
export DEBIAN_FRONTEND=noninteractive
D=/tmp/container-setup
cd "$D"

retry() {
  n=0
  until "$@"; do
    n=$((n + 1))
    [ "$n" -ge 5 ] && return 1
    echo "Download failed, retrying ($n/5)..."; sleep 5
  done
}
# --allow-change-held-packages lets a re-run replace packages pinned by an earlier run.
APT="apt-get install -y --reinstall --allow-downgrades --allow-change-held-packages"

# The Mesa archive is a plain file tree to extract over the system. Refuse it if
# it contains anything outside /usr, before any system file is touched.
MESA=$(ls "$D"/mesa-for-android-container*.tar.gz 2>/dev/null | head -n1 || true)
[ -n "$MESA" ] || { echo "Mesa archive not found in $D." >&2; exit 1; }
if tar -tzf "$MESA" | grep -v -E '^(\./)?usr(/|$)' | grep -v -x './' | grep -q .; then
  echo "Unexpected paths in the Mesa archive; not installing it." >&2
  exit 1
fi

retry apt-get update
retry apt-get install -y unzip
# Optional extras (audio for Plasma, mesa-utils for the GPU check); not fatal.
retry apt-get install -y mesa-utils pipewire-audio libcanberra-pulse || echo "Optional packages skipped."
retry apt-get install -y pipewire-libcamera || echo "pipewire-libcamera skipped."

# Anland's patched XWayland and KWin.
$APT "$D"/xwayland_*_arm64.deb
rm -rf "$D/kwin-debs"; mkdir -p "$D/kwin-debs"
unzip -o -q "$D"/kwin_anland-*.zip -d "$D/kwin-debs"
KDEBS=$(find "$D/kwin-debs" -name '*.deb')
[ -n "$KDEBS" ] || { echo "No .deb files in the KWin zip." >&2; exit 1; }
$APT $KDEBS

# Patched Mesa (KGSL / Adreno): extract over the system.
tar -xzf "$MESA" -C / --no-overwrite-dir
ldconfig

# Pin the patched packages so apt upgrade does not replace them.
for p in xwayland libegl-mesa0 libgbm1 libgl1-mesa-dri libglx-mesa0 mesa-libgallium \
         mesa-vulkan-drivers kwin-common kwin-data kwin-wayland libkwin6; do
  dpkg -s "$p" >/dev/null 2>&1 && apt-mark hold "$p" >/dev/null || true
done
rm -rf "$D"
CT_EOF

  say "Configuring $label (this takes a while)"
  proot-distro login "$name" --shared-tmp -- bash /tmp/container-root-setup.sh
  rm -rf "$udl" "$TMPDIR/container-root-setup.sh"

  say "Installing the '$shcmd' and '$plcmd' commands"
  make_plasma_stop
  printf '#!%s/bin/bash\nexec proot-distro login %s --shared-tmp "$@"\n' \
    "$PREFIX" "$name" > "$PREFIX/bin/$shcmd"
  printf '#!%s/bin/bash\nplasma-stop\nsleep 1\nanland >/dev/null 2>&1 &\nexec proot-distro login %s --shared-tmp -- bash -c "startplasma-anland"\n' \
    "$PREFIX" "$name" > "$PREFIX/bin/$plcmd"
  chmod +x "$PREFIX/bin/$shcmd" "$PREFIX/bin/$plcmd"
}

if [ "$DO_UBUNTU" = 1 ]; then
  setup_container "Ubuntu 26.04" "$UBUNTU_NAME" "$UBUNTU_IMAGE" "$UXWAY" "$UKWIN" \
    '^mesa-for-android-container.*ubuntu_resolute_arm64\.tar\.gz$' ubuntush plasma-ubuntu
fi
if [ "$DO_DEBIAN" = 1 ]; then
  setup_container "Debian 13" "$DEBIAN_NAME" "$DEBIAN_IMAGE" "$DXWAY" "$DKWIN" \
    '^mesa-for-android-container.*debian_trixie_arm64\.tar\.gz$' debiansh plasma-debian
fi

if [ "$DO_ARCH" = 1 ]; then
# -------------------------------------------------------------- Arch part ----
arch_cleanup() {
  proot-distro login "$ARCH_NAME" -- rm -f /etc/sudoers.d/99-setup-nopasswd >/dev/null 2>&1 || true
  rm -f "$TMPDIR/arch-root-setup.sh"
}

say "Setting up the Arch Linux ARM container '$ARCH_NAME'"
if ! proot-distro login "$ARCH_NAME" -- true >/dev/null 2>&1; then
  cd "$WORK"
  ROOTFS=ArchLinuxARM-aarch64-latest.tar.gz
  if [ ! -s "$ROOTFS" ]; then
    # The rootfs is not signature-checked here; HTTPS is tried first.
    curl -fL -# -o "$ROOTFS.part" "https://os.archlinuxarm.org/os/$ROOTFS" \
      || curl -fL -# -o "$ROOTFS.part" "http://os.archlinuxarm.org/os/$ROOTFS"
    mv "$ROOTFS.part" "$ROOTFS"
  fi
  proot-distro install "./$ROOTFS" --name "$ARCH_NAME"
fi

say "Downloading the patched Mesa for Arch"
MESA_URL=$(mesa_url '^mesa-for-android-container.*archlinux_arm64\.tar$')
[ -n "$MESA_URL" ] || die "No Arch Mesa package found in mesa-for-android-container (rate limit? set GITHUB_TOKEN)."
rm -f "$TMPDIR"/mesa-for-android-container*.tar
( cd "$TMPDIR" && curl -fL -# -O "$MESA_URL" )

# Written to the shared tmp folder, which the container sees as /tmp.
cat > "$TMPDIR/arch-root-setup.sh" <<'ROOT_EOF'
#!/bin/bash
set -eu
: "${ARCH_USER:?}" "${ARCH_NAME:?}"
CONF=/etc/pacman.conf

# pacman's sandbox needs kernel features proot does not have; do not let
# kernel updates build initramfs images inside a container.
grep -q '^DisableSandbox' "$CONF" || sed -i '/^\[options\]/a DisableSandbox' "$CONF"
# Slow phone connections trip pacman's "Operation too slow" abort.
grep -q '^DisableDownloadTimeout' "$CONF" || sed -i '/^\[options\]/a DisableDownloadTimeout' "$CONF"

# Retry network steps; pacman keeps already-downloaded packages in its cache.
retry() {
  n=0
  until "$@"; do
    n=$((n + 1))
    [ "$n" -ge 5 ] && return 1
    echo "Download failed, retrying ($n/5)..."; sleep 5
  done
}
grep -q '^IgnorePkg' "$CONF" || \
  sed -i '/^\[options\]/a IgnorePkg = linux-aarch64 linux-aarch64-headers linux-firmware' "$CONF"

pacman-key --init
pacman-key --populate archlinuxarm
retry pacman -Syu --noconfirm
retry pacman -S --needed --noconfirm sudo base-devel git ttf-dejavu ttf-liberation qt6-wayland

# Patched Mesa (KGSL / Adreno), then pin it so updates do not replace it.
rm -rf /tmp/mesa-arch; mkdir -p /tmp/mesa-arch
tar -xf /tmp/mesa-for-android-container*archlinux_arm64.tar -C /tmp/mesa-arch
pacman -U --noconfirm /tmp/mesa-arch/*.pkg.tar.*
retry pacman -S --needed --noconfirm mesa-utils
grep -q 'vulkan-freedreno' "$CONF" || \
  sed -i '/^IgnorePkg/ s/$/ mesa mesa-docs vulkan-freedreno vulkan-mesa-layers vulkan-mesa-implicit-layers/' "$CONF"
rm -rf /tmp/mesa-arch /tmp/mesa-for-android-container*.tar

# Normal user with sudo (temporary passwordless sudo is removed afterwards).
id "$ARCH_USER" >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash "$ARCH_USER"
printf '%s ALL=(ALL:ALL) ALL\n' "$ARCH_USER" > "/etc/sudoers.d/$ARCH_USER"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$ARCH_USER" > /etc/sudoers.d/99-setup-nopasswd
chmod 440 "/etc/sudoers.d/$ARCH_USER" /etc/sudoers.d/99-setup-nopasswd

# Locale and fonts (without these Qt shows boxes instead of text).
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
fc-cache -f

# Kickoff sync: mirror Arch .desktop files into the Plasma menu, each one
# launching through the container with the GPU environment set.
cat > /usr/local/bin/sync-kickoff <<'SYNC_EOF'
#!/bin/bash
OUT=${KICKOFF_OUT:-/termux-apps}
SRC=${KICKOFF_SRC:-/usr/share/applications}
[ -d "$OUT" ] || exit 0
rm -f "$OUT"/arch-*.desktop
for f in "$SRC"/*.desktop; do
  [ -e "$f" ] || continue
  sed -E \
    -e '/^(TryExec|DBusActivatable)=/d' \
    -e 's|^Exec=(.*)|Exec=proot-distro login @ARCH_NAME@ --user @ARCH_USER@ --shared-tmp -- env MESA_LOADER_DRIVER_OVERRIDE=kgsl TURNIP_KMD=kgsl GALLIUM_DRIVER=freedreno FD_FORCE_KGSL=1 LANG=en_US.UTF-8 XDG_RUNTIME_DIR=/tmp/run WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland \1|' \
    -e 's|^Name=|Name=[Arch] |' \
    "$f" > "$OUT/arch-$(basename "$f")"
done
SYNC_EOF
sed -i "s/@ARCH_NAME@/$ARCH_NAME/g; s/@ARCH_USER@/$ARCH_USER/g" /usr/local/bin/sync-kickoff
chmod +x /usr/local/bin/sync-kickoff

mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/kickoff.hook <<'HOOK_EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Path
Target = usr/share/applications/*.desktop

[Action]
Description = Syncing apps to KDE Kickoff
When = PostTransaction
Exec = /usr/local/bin/sync-kickoff
HOOK_EOF
ROOT_EOF

trap arch_cleanup EXIT
say "Configuring Arch (this takes a while)"
proot-distro login "$ARCH_NAME" --shared-tmp -- \
  env ARCH_USER="$ARCH_USER" ARCH_NAME="$ARCH_NAME" bash /tmp/arch-root-setup.sh

say "Password for '$ARCH_USER' inside Arch"
if [ "$(proot-distro login "$ARCH_NAME" -- passwd -S "$ARCH_USER" 2>/dev/null | awk '{print $2}')" != P ]; then
  proot-distro login "$ARCH_NAME" -- passwd "$ARCH_USER"
fi

say "Installing yay"
proot-distro login "$ARCH_NAME" --user "$ARCH_USER" --shared-tmp -- bash -c '
  set -e
  command -v yay >/dev/null && exit 0
  cd ~ && rm -rf yay-bin
  git clone --depth 1 https://aur.archlinux.org/yay-bin.git
  cd yay-bin && makepkg -si --noconfirm
  cd ~ && rm -rf yay-bin
'

say "Installing the 'archsh' and 'ksync' commands"
mkdir -p "$HOME/.local/share/applications"
cat > "$PREFIX/bin/archsh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec proot-distro login @ARCH_NAME@ --user @ARCH_USER@ --shared-tmp --bind "$HOME/.local/share/applications:/termux-apps" "$@"
EOF
cat > "$PREFIX/bin/ksync" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec archsh -- /usr/local/bin/sync-kickoff
EOF
sed -i "s/@ARCH_NAME@/$ARCH_NAME/g; s/@ARCH_USER@/$ARCH_USER/g" "$PREFIX/bin/archsh"
chmod +x "$PREFIX/bin/archsh" "$PREFIX/bin/ksync"
ksync
fi

# Keep a copy of this script as the "anland-menu" command.
if [ -f "$SELF" ] && grep -q 'anland-arch-setup' "$SELF" && ! [ "$SELF" -ef "$PREFIX/bin/anland-menu" ]; then
  cp "$SELF" "$PREFIX/bin/anland-menu.new"
  chmod +x "$PREFIX/bin/anland-menu.new"
  mv -f "$PREFIX/bin/anland-menu.new" "$PREFIX/bin/anland-menu"
fi

# ------------------------------------------------------------------ summary ----
cat <<'MSG'

All done. Run  anland-menu  any time to get the menu.

  1. Install the Anland display app if you have not yet (see the prompt above).
  2. Start ONE desktop at a time from the Termux app, then open "Anland Termux":
MSG
if [ "$DO_NATIVE" = 1 ]; then echo "       plasma          native Plasma"; fi
if [ "$DO_UBUNTU" = 1 ]; then echo "       plasma-ubuntu   Ubuntu 26.04 Plasma"; fi
if [ "$DO_DEBIAN" = 1 ]; then echo "       plasma-debian   Debian 13 Plasma"; fi
echo "       plasma-stop     stop whichever desktop is running"
if [ "$DO_ARCH" = 1 ]; then
cat <<'MSG'
  3. Arch:   archsh   then: yay -S <app>   (it appears in Kickoff by itself)

Check the GPU for Arch apps from Konsole inside native Plasma:
  archsh -- env MESA_LOADER_DRIVER_OVERRIDE=kgsl TURNIP_KMD=kgsl GALLIUM_DRIVER=freedreno \
    FD_FORCE_KGSL=1 XDG_RUNTIME_DIR=/tmp/run WAYLAND_DISPLAY=wayland-0 eglinfo -B
Look for "FD6xx" (freedreno) under the Wayland platform; "llvmpipe" means CPU only.
MSG
fi
if [ "$DO_UBUNTU" = 1 ]; then
cat <<'MSG'

Ubuntu: ubuntush   then: apt install <app>   (it appears in Ubuntu's Kickoff)
Check its GPU from Konsole inside the Ubuntu desktop: eglinfo -B  (look for "FD6xx").
MSG
fi
if [ "$DO_DEBIAN" = 1 ]; then
cat <<'MSG'

Debian: debiansh   then: apt install <app>   (it appears in Debian's Kickoff)
Check its GPU from Konsole inside the Debian desktop: eglinfo -B  (look for "FD6xx").
MSG
fi
