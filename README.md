# termux-plasma-arch

KDE Plasma on Android: a native, GPU-accelerated Plasma desktop in Termux
(via [Anland](https://github.com/lfdevs/anland-termux)), plus an Arch Linux
container whose `yay`/`pacman` apps show up in the Plasma Kickoff menu and draw
on the same desktop with the Adreno GPU. No root needed.

One script sets up everything. It can also add an **Ubuntu 26.04** container with
its own Plasma desktop (`--ubuntu`).

## What you get

- **Native Plasma (Wayland)** running in Termux, with Konsole and Dolphin, using
  the KGSL driver for GPU acceleration.
- **An Arch Linux ARM container** (proot-distro) with a normal user, `sudo`,
  fonts, locale and [`yay`](https://github.com/Jguer/yay).
- **Kickoff menu sync**: every app you install in Arch appears in Kickoff as
  `[Arch] <app>`. A pacman hook keeps the menu up to date after every install,
  upgrade or removal.
- **GPU for Arch apps**: a patched Mesa (Freedreno/KGSL) is installed in Arch and
  pinned so `pacman -Syu` doesn't replace it.
- **Optional Ubuntu 26.04 desktop** (`--ubuntu`): Anland's prebuilt Ubuntu image with
  Plasma, the patched KWin/XWayland and the Ubuntu GPU driver, with `apt` apps in
  its own Kickoff menu.
- Short commands: `plasma`, `plasma-ubuntu`, `plasma-stop`, `archsh`, `ubuntush`, `ksync`.

## Requirements

- A **Snapdragon (Adreno GPU)** phone, arm64. The Anland GPU path needs Adreno.
- **Termux** from GitHub releases or F-Droid (not the Play Store build).
- Wi-Fi and roughly 6 GB of free storage (more with `--ubuntu`).
- The script picks the matching **Anland Termux** display app for your Termux
  build and offers to install it.

## Install

Run this in Termux (not inside a container):

```
curl -LO https://raw.githubusercontent.com/bunnyxzyq-debug/termux-plasma-arch/main/anland-arch-setup.sh
bash anland-arch-setup.sh
```

Download it first rather than piping into `bash`: the script asks for the
password of your Arch user, and a pipe breaks that prompt.

It takes a while (large downloads). When it finishes:

1. Install the Anland display app if you haven't yet. The script downloads it to
   your Downloads folder and tries to open it.
2. Run `plasma`, then switch to the **Anland Termux** app.

### Options

| Option / variable | Meaning | Default |
| --- | --- | --- |
| `--no-arch` | Skip the Arch container | off |
| `--ubuntu` | Also set up the Ubuntu 26.04 container | off |
| `--ubuntu-only` | Only Anland and the Ubuntu container (no native Plasma, no Arch) | off |
| `ARCH_USER` | Username created in Arch | `arch` |
| `ARCH_NAME` | Arch container name | `archlinux` |
| `UBUNTU_NAME` | Ubuntu container name | `ubuntu-anland` |
| `ANLAND_DIR` | Download/work folder | `~/anland` |
| `GITHUB_TOKEN` | Optional, avoids GitHub API rate limits | unset |

Examples:

```
ARCH_USER=bob bash anland-arch-setup.sh            # native Plasma + Arch
bash anland-arch-setup.sh --ubuntu                 # native Plasma + Arch + Ubuntu
bash anland-arch-setup.sh --ubuntu-only            # just Ubuntu
```

The script is safe to re-run: finished steps are skipped or repeated harmlessly.

## Commands

| Command | What it does |
| --- | --- |
| `plasma` | Starts native Plasma. Then open the **Anland Termux** app. |
| `plasma-ubuntu` | Starts the Ubuntu desktop instead (with `--ubuntu`). |
| `plasma-stop` | Stops whichever desktop is running. |
| `archsh` | Opens a shell in the Arch container as your user. Install apps with `yay -S <app>`. |
| `ubuntush` | Opens a shell in the Ubuntu container (root). Install apps with `apt install <app>`. |
| `ksync` | Rebuilds the `[Arch]` Kickoff entries by hand (normally the pacman hook does this). |

Run these from the Termux app, not from Konsole inside Plasma: starting a desktop
stops the one that is running.

## Ubuntu desktop (optional)

`--ubuntu` installs Anland's prebuilt **Ubuntu 26.04** image (`ghcr.io/lfdevs/ubuntu:resolute-anland-plasma`)
as a proot-distro container, then adds Anland's patched XWayland and KWin and the
Ubuntu build of the GPU driver, and pins them so `apt upgrade` doesn't replace them.

- Start it with `plasma-ubuntu`, then open **Anland Termux**.
- It is a separate desktop from native Plasma. Both draw in the Anland app, so run
  **one at a time**; `plasma` and `plasma-ubuntu` each stop the other first.
- Apps installed with `apt` appear in Ubuntu's own Kickoff menu; no sync script is needed.
- Only Ubuntu 26.04 ("resolute") is supported.
- GPU check: open Konsole inside the Ubuntu desktop and run `eglinfo -B`. The
  renderer should be `FD6xx` (freedreno).

## Check that the GPU is used

In Konsole inside Plasma:

```
archsh -- env MESA_LOADER_DRIVER_OVERRIDE=kgsl TURNIP_KMD=kgsl GALLIUM_DRIVER=freedreno \
  FD_FORCE_KGSL=1 XDG_RUNTIME_DIR=/tmp/run WAYLAND_DISPLAY=wayland-0 eglinfo -B
```

Under **Wayland platform**, the renderer should be `FD6xx` (freedreno). If it says
`llvmpipe`, rendering is on the CPU.

## How it works

- Termux runs `kwin_wayland` and Plasma using patched packages from the Anland
  project. The Anland daemon and display app show the desktop.
- The Arch container shares Termux's `tmp` folder, so Arch apps connect to
  Plasma's Wayland socket (`wayland-0`).
- The Ubuntu container works the same way: `--shared-tmp` lets it reach the Anland
  display, and its Plasma runs inside the container, started by `startplasma-anland`.
- `archsh` also bind-mounts Termux's menu folder into Arch as `/termux-apps`.
  `/usr/local/bin/sync-kickoff` writes `[Arch]` `.desktop` files there, each one
  launching the app through `proot-distro` with the GPU environment set.

## Troubleshooting

**`kwin_wayland` fails with `cannot locate symbol ...`**
Termux's Qt moved ahead of the Anland KWin build. Wait for a new
[Anland release](https://github.com/lfdevs/anland-termux/releases), then re-run
the script. Before upgrading Termux, check: `apt list --upgradable | grep -i qt`.

**Plasma starts but the Anland app stays black**
Make sure the display app matches your Termux build (GitHub build: standard APK;
F-Droid build: `-compatible` APK). The two variants can't be installed together;
uninstall the other first.

**Boxes instead of text in Arch apps**
Fonts or locale are missing in Arch:
`archsh`, then `sudo pacman -S ttf-dejavu ttf-liberation`.

**`pacman` errors about Landlock or the sandbox**
The script adds `DisableSandbox` to `/etc/pacman.conf`. If you reset the config,
add that line under `[options]`.

**`sudo` says your user isn't allowed**
Run `proot-distro login archlinux` (as root) and create
`/etc/sudoers.d/<user>` containing `<user> ALL=(ALL:ALL) ALL`, mode 440.

**An Arch app doesn't appear in Kickoff**
Run `ksync`, and if needed `kbuildsycoca6 --noincremental` in Konsole inside
Plasma.

**Ubuntu desktop doesn't start**
Stop any other desktop first (`plasma-stop`), then run `plasma-ubuntu` from the Termux
app. If it still fails, check that the patched packages are installed:
`ubuntush -- dpkg -l xwayland kwin-wayland` should show an Anland build (xwayland
`-9x`, kwin `...ubuntu9x`).

**Ubuntu graphics fall back to the CPU after an update**
`apt` replaced the patched Mesa or KWin. Re-run the script with `--ubuntu`; it
reinstalls and pins them again.

**Electron or X11-only Arch apps**
Qt and GTK apps use Wayland automatically. Electron/Chromium apps may need
`--ozone-platform=wayland`. X11-only apps need extra XWayland setup.

## Notes

- Not an official project. It automates the manual setup from the Anland user
  guide and adds the Arch container and Kickoff sync on top.
- Status: the manual steps this script automates (native Plasma, the Arch
  container with GPU and Kickoff sync, and the Ubuntu desktop with GPU) were
  verified on a Snapdragon 732G (Adreno 618) with the GitHub build of Termux. The
  `--ubuntu` and `--ubuntu-only` options of the script itself have not been run
  end to end yet, so please open an issue if something breaks.
- Termux's Mesa and Arch's Mesa are separate builds and may be different
  versions. If an app glitches, try matching them.
- Arch's kernel packages are pinned (`IgnorePkg`) because a kernel can't be
  installed in a container.

## Credits

- [Anland](https://github.com/superturtlee/anland) and
  [anland-termux](https://github.com/lfdevs/anland-termux), including the
  prebuilt Ubuntu 26.04 image
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)
  and [lfdevs/termux-packages](https://github.com/lfdevs/termux-packages)
- [Termux](https://github.com/termux/termux-app) and
  [proot-distro](https://github.com/termux/proot-distro)
- [Arch Linux ARM](https://archlinuxarm.org)
