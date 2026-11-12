#!/data/data/com.termux/files/usr/bin/bash
# anland-arch-setup.sh
#
# KDE Plasma (Wayland, KGSL GPU acceleration) running natively in Termux via
# Anland, plus an Arch Linux ARM container (proot-distro) with yay. Apps you
# install in Arch show up in the Plasma Kickoff menu and draw on the same
# desktop with the Adreno GPU.
#
# Run it in Termux itself (not inside the Arch container):
#   bash anland-arch-setup.sh
#
# Options:
#   --no-arch      only set up native Plasma, skip the Arch container
#   -h, --help     show this text
#
# Environment variables:
#   ARCH_USER      user created in Arch              (default: arch)
#   ARCH_NAME      proot-distro container name       (default: archlinux)
#   ANLAND_DIR     download/work folder              (default: ~/anland)
#   GITHUB_TOKEN   optional, avoids GitHub API rate limits
#
# Needs: Termux (GitHub or F-Droid build), aarch64 phone with an Adreno GPU
# (Snapdragon), Wi-Fi, about 6 GB free storage.
#
# Commands this installs:
#   plasma   start the desktop, then open the "Anland Termux" app
#   archsh   shell in the Arch container as your user
#   ksync    rebuild the "[Arch]" Kickoff entries by hand
#
# Known issue: if kwin_wayland fails with "cannot locate symbol", Termux's Qt
# moved past the Anland KWin build. Wait for a new Anland release, then re-run
# this script. Check before upgrading: apt list --upgradable | grep -i qt
set -eu

ARCH_USER=${ARCH_USER:-arch}
ARCH_NAME=${ARCH_NAME:-archlinux}
WORK=${ANLAND_DIR:-$HOME/anland}
DO_ARCH=1

for a in "$@"; do
  case $a in
    --no-arch) DO_ARCH=0 ;;
    -h|--help) sed -n '2,/^set -eu/{/^set -eu/!p}' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- checks ----
[ -n "${PREFIX:-}" ] && [ -d /data/data/com.termux ] \
  || die "Run this in Termux itself, not inside the Arch container."
[ "$(id -u)" -ne 0 ] || die "Do not run this as root."
[ "$(uname -m)" = aarch64 ] || die "This only supports aarch64 phones."
[ -e /dev/kgsl-3d0 ] || warn "No Adreno GPU node found: the Anland GPU path needs a Snapdragon phone."
[[ $ARCH_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "ARCH_USER must be a lowercase Linux username."

HDR=()
[ -n "${GITHUB_TOKEN:-}" ] && HDR=(-H "Authorization: Bearer $GITHUB_TOKEN")
gh_api() { curl -fsSL "${HDR[@]}" -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"; }
fetch()  { curl -fL --retry 3 -# -O "$1"; }

# ------------------------------------------------------- Termux packages ----
export DEBIAN_FRONTEND=noninteractive
termux-wake-lock 2>/dev/null || true

say "Updating Termux and installing Plasma"
pkg update -y
apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade
pkg install -y x11-repo
pkg update -y
pkg install -y curl jq proot-distro plasma-desktop konsole dolphin pipewire termux-api

# --------------------------------------------------- Anland + GPU driver ----
say "Finding the latest Anland release"
REL=$(gh_api repos/lfdevs/anland-termux/releases/latest) \
  || die "GitHub API request failed (rate limit? set GITHUB_TOKEN)."
TAG=$(jq -r .tag_name <<<"$REL")
pick() { jq -r --arg re "$1" '[.assets[] | select(.name | test($re)) | .browser_download_url][0] // empty' <<<"$REL"; }

DAEMON=$(pick '^anland_[0-9.]+(-[0-9]+)?_aarch64\.deb$')
XWAY=$(pick '^xwayland_.*_aarch64\.deb$')
KWIN=$(pick '^kwin-anland_.*_aarch64\.deb$')
if [ "${TERMUX_APP__APK_RELEASE:-}" = F_DROID ]; then
  APK=$(pick '^AnlandTermux-.*-compatible\.apk$')   # F-Droid / ZeroTermux build
else
  APK=$(pick '^AnlandTermux-[0-9.]+\.apk$')         # GitHub Termux build
fi
for v in DAEMON XWAY KWIN APK; do
  [ -n "${!v}" ] || die "Release $TAG has no $v asset (release layout changed?)."
done

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

say "Downloading Anland $TAG, $LTAG, $FTAG"
rm -rf "$WORK/dl"; mkdir -p "$WORK/dl"; cd "$WORK/dl"
for u in "$DAEMON" "$XWAY" "$KWIN" $LURLS $FURLS; do fetch "$u"; done

say "Installing"
apt-mark unhold xwayland mesa mesa-vulkan-icd-freedreno layer-shell-qt >/dev/null 2>&1 || true
# --allow-downgrades: Termux's repo can carry a newer layer-shell-qt/mesa than the
# patched builds, and the patched ones are the ones Anland needs.
reinst() {
  apt-get install -y --reinstall --allow-downgrades \
    -o Dpkg::Options::=--force-confold "$@"
}
reinst ./anland_*_aarch64.deb
reinst ./xwayland_*_aarch64.deb ./kwin-anland_*_aarch64.deb
reinst ./layer-shell-qt_*.deb
reinst ./mesa*.deb
# Keep Termux updates from replacing the patched packages.
apt-mark hold xwayland mesa mesa-vulkan-icd-freedreno layer-shell-qt

say "Installing the 'plasma' command"
curl -fL -o "$WORK/startplasma-anland.sh" \
  https://github.com/lfdevs/anland-termux/raw/refs/heads/main/scripts/startplasma-anland.sh
chmod +x "$WORK/startplasma-anland.sh"
cat > "$PREFIX/bin/plasma" <<EOF
#!$PREFIX/bin/bash
cd "$WORK"
killall anland >/dev/null 2>&1 || true
anland >/dev/null 2>&1 &
./startplasma-anland.sh
EOF
chmod +x "$PREFIX/bin/plasma"

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

if [ "$DO_ARCH" = 0 ]; then
  say "Done (native Plasma only). Install the Anland app, then run: plasma"
  exit 0
fi

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
MESA_URL=$(gh_api repos/lfdevs/mesa-for-android-container/releases/latest \
  | jq -r '[.assets[] | select(.name | test("archlinux_arm64\\.tar$")) | .browser_download_url][0] // empty') \
  || die "Could not query mesa-for-android-container."
[ -n "$MESA_URL" ] || die "No Arch Mesa package in the latest mesa-for-android-container release."
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
grep -q '^IgnorePkg' "$CONF" || \
  sed -i '/^\[options\]/a IgnorePkg = linux-aarch64 linux-aarch64-headers linux-firmware' "$CONF"

pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm
pacman -S --needed --noconfirm sudo base-devel git ttf-dejavu ttf-liberation qt6-wayland

# Patched Mesa (KGSL / Adreno), then pin it so updates do not replace it.
rm -rf /tmp/mesa-arch; mkdir -p /tmp/mesa-arch
tar -xf /tmp/mesa-for-android-container*archlinux_arm64.tar -C /tmp/mesa-arch
pacman -U --noconfirm /tmp/mesa-arch/*.pkg.tar.*
pacman -S --needed --noconfirm mesa-utils
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

cat <<MSG

All done.

  1. Install the Anland display app if you have not yet (see the prompt above).
  2. Run:   plasma        then open the "Anland Termux" app.
  3. Arch:  archsh        then: yay -S <app>   (it appears in Kickoff by itself)

Check the GPU from Konsole inside Plasma:
  archsh -- env MESA_LOADER_DRIVER_OVERRIDE=kgsl TURNIP_KMD=kgsl GALLIUM_DRIVER=freedreno \\
    FD_FORCE_KGSL=1 XDG_RUNTIME_DIR=/tmp/run WAYLAND_DISPLAY=wayland-0 eglinfo -B
Look for "FD6xx" (freedreno) under the Wayland platform; "llvmpipe" means CPU only.
MSG
