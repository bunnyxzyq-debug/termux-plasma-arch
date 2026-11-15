# termux-plasma-arch

KDE Plasma on Android: a native, GPU-accelerated Plasma desktop in Termux
(via [Anland](https://github.com/lfdevs/anland-termux)), plus an Arch Linux
container whose `yay`/`pacman` apps show up in the Plasma Kickoff menu and draw
on the same desktop with the Adreno GPU. No root needed.

One script sets up everything and gives you a menu to run it. It can also add an
**Ubuntu 26.04** and a **Debian 13** container, each with its own Plasma desktop.

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
- **Optional Ubuntu 26.04 and Debian 13 desktops**: Anland's prebuilt images with
  Plasma, the patched KWin/XWayland and the distro's GPU driver, with `apt` apps in
  their own Kickoff menu.
- **A main menu** (`anland-menu`) to install, start and stop desktops and open the
  shells, plus short commands: `plasma`, `plasma-ubuntu`, `plasma-debian`,
  `plasma-stop`, `archsh`, `ubuntush`, `debiansh`, `ksync`.

## Requirements

- A **Snapdragon (Adreno GPU)** phone, arm64. The Anland GPU path needs Adreno.
- **Termux** from GitHub releases or F-Droid (not the Play Store build).
- Wi-Fi and roughly 6 GB of free storage (more for each extra container).
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

The script opens the main menu. Choose **1) Install / update**, tick the parts you
want, then press `g`:

```
  Install / update
   [x] 1  Native Plasma in Termux (GPU)
   [x] 2  Arch Linux container + yay + Kickoff sync (needs 1)
   [ ] 3  Ubuntu 26.04 desktop container
   [ ] 4  Debian 13 desktop container
```

Arch needs native Plasma (its apps appear in Plasma's Kickoff menu), so ticking 2
ticks 1 and unticking 1 unticks 2. If you tick Arch, it asks for the username (it
keeps the one from an earlier run).

The install takes a while (large downloads). When it finishes:

1. Install the Anland display app if you haven't yet. The script downloads it to
   your Downloads folder and tries to open it.
2. Run `anland-menu` and choose **2) Start native Plasma**, then switch to the
   **Anland Termux** app.

### Main menu

The script keeps a copy of itself as the `anland-menu` command, so the menu is one
word away:

| Menu entry | What it does |
| --- | --- |
| 1) Install / update | Tick the parts, then install or repair them |
| 2) Start native Plasma | Runs `plasma` |
| 3) Start Ubuntu Plasma | Runs `plasma-ubuntu` |
| 4) Start Debian Plasma | Runs `plasma-debian` |
| 5) Stop the running desktop | Runs `plasma-stop` |
| 6) Arch shell (yay) | Runs `archsh` |
| 7) Ubuntu shell (apt) | Runs `ubuntush` |
| 8) Debian shell (apt) | Runs `debiansh` |
| 9) Sync Arch apps to Kickoff | Runs `ksync` |
| u) Update this menu from GitHub | Downloads the newest script and restarts the menu |

Each entry shows whether its part is installed. Use the menu from the Termux app,
not from Konsole inside Plasma: starting or stopping a desktop closes the one you
are in.

### Options (skip the menu)

Options install straight away without the menu, which is useful for re-running or
scripting. Without a terminal (for example piped) and without options, it installs
native Plasma and Arch.

| Option / variable | Meaning | Default |
| --- | --- | --- |
| `--no-arch` | Skip the Arch container | off |
| `--ubuntu` | Also set up the Ubuntu 26.04 container | off |
| `--debian` | Also set up the Debian 13 container | off |
| `--ubuntu-only` | Only Anland and the Ubuntu container (no native Plasma, no Arch) | off |
| `--debian-only` | Only Anland and the Debian container (no native Plasma, no Arch) | off |
| `ARCH_USER` | Username created in Arch (the menu offers it as the default) | `arch` |
| `ARCH_NAME` | Arch container name | `archlinux` |
| `UBUNTU_NAME` | Ubuntu container name | `ubuntu-anland` |
| `DEBIAN_NAME` | Debian container name | `debian-anland` |
| `ANLAND_DIR` | Download/work folder | `~/anland` |
| `GITHUB_TOKEN` | Optional, avoids GitHub API rate limits | unset |

Examples:

```
ARCH_USER=bob bash anland-arch-setup.sh            # native Plasma + Arch
bash anland-arch-setup.sh --ubuntu                 # native Plasma + Arch + Ubuntu
bash anland-arch-setup.sh --ubuntu-only            # just Ubuntu
bash anland-arch-setup.sh --debian-only            # just Debian
```

The script is safe to re-run: finished steps are skipped or repeated harmlessly.

## Commands

| Command | What it does |
| --- | --- |
| `anland-menu` | Opens the main menu. |
| `plasma` | Starts native Plasma. Then open the **Anland Termux** app. |
| `plasma-ubuntu` | Starts the Ubuntu desktop instead (with `--ubuntu`). |
| `plasma-debian` | Starts the Debian desktop instead (with `--debian`). |
| `plasma-stop` | Stops whichever desktop is running. |
| `archsh` | Opens a shell in the Arch container as your user. Install apps with `yay -S <app>`. |
| `ubuntush` | Opens a shell in the Ubuntu container (root). Install apps with `apt install <app>`. |
| `debiansh` | Opens a shell in the Debian container (root). Install apps with `apt install <app>`. |
| `ksync` | Rebuilds the `[Arch]` Kickoff entries by hand (normally the pacman hook does this). |

Run these from the Termux app, not from Konsole inside Plasma: starting a desktop
stops the one that is running.

## Ubuntu and Debian desktops (optional)

Ticking **3** or **4** in the install menu (or `--ubuntu` / `--debian`) installs
Anland's prebuilt image as a proot-distro container:

| Desktop | Image | Container name |
| --- | --- | --- |
| Ubuntu 26.04 ("resolute") | `ghcr.io/lfdevs/ubuntu:resolute-anland-plasma` | `ubuntu-anland` |
| Debian 13 ("trixie") | `ghcr.io/lfdevs/debian:trixie-anland-plasma` | `debian-anland` |

The script then adds Anland's patched XWayland and KWin and the distro's build of
the GPU driver (Mesa), and pins them so `apt upgrade` doesn't replace them.

- Start them with `plasma-ubuntu` or `plasma-debian`, then open **Anland Termux**.
- Each is a separate desktop from native Plasma. They all draw in the Anland app,
  so run **one at a time**; every start command stops the others first.
- Apps installed with `apt` appear in that desktop's own Kickoff menu; no sync
  script is needed.
- Only Ubuntu 26.04 and Debian 13 are supported.
- GPU check: open Konsole inside the desktop and run `eglinfo -B`. The renderer
  should be `FD6xx` (freedreno).

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
- The Ubuntu and Debian containers work the same way: `--shared-tmp` lets them reach
  the Anland display, and their Plasma runs inside the container, started by
  `startplasma-anland`.
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

**Ubuntu or Debian desktop doesn't start**
Stop any other desktop first (`plasma-stop`), then run `plasma-ubuntu` or
`plasma-debian` from the Termux app. If it still fails, check that the patched
packages are installed: `ubuntush -- dpkg -l xwayland kwin-wayland` (or `debiansh`)
should show an Anland build (xwayland `-9x`, kwin `...9x`).

**Ubuntu or Debian graphics fall back to the CPU after an update**
`apt` replaced the patched Mesa or KWin. Open `anland-menu`, choose **1) Install /
update**, tick that container and go (or re-run the script with `--ubuntu` /
`--debian`); it reinstalls and pins them again.

**"Unexpected paths in the Mesa archive"**
The script only extracts a Mesa archive that stays inside `/usr`, and refuses
anything else before touching the system. If a new release changes the layout,
open an issue.

**Electron or X11-only Arch apps**
Qt and GTK apps use Wayland automatically. Electron/Chromium apps may need
`--ozone-platform=wayland`. X11-only apps need extra XWayland setup.

## Notes

- Not an official project. It automates the manual setup from the Anland user
  guide and adds the Arch container and Kickoff sync on top.
- Status: the manual steps this script automates (native Plasma, the Arch
  container with GPU and Kickoff sync, and the Ubuntu desktop with GPU) were
  verified on a Snapdragon 732G (Adreno 618) with the GitHub build of Termux. The
  Ubuntu and Debian installs and the main menu of the script itself have been
  tested in a simulated environment but not run end to end on a phone yet. The
  Debian desktop in particular has not been seen running yet, so please open an
  issue if something breaks.
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
