# shellcheck shell=bash
# Shared by mkos-install and mkos-install-partition.

# mkos_packages — what pacstrap installs on a MKOS system, one per line:
# the base system, the MKOS desktop (exactly the set the live session runs:
# the part of iso/packages.x86_64 above "@live-only", shipped on the ISO),
# build tools the AIOS backend needs, and the bundled [mkos] AUR packages.
# Hardware-specific packages (microcode, GPU drivers) are added by the caller.
mkos_packages() {
    local list=${MKOS_DESKTOP_LIST:-/usr/local/share/mkos/desktop-packages.txt}
    [ -f "$list" ] || { echo "mkos_packages: missing $list" >&2; return 1; }
    printf '%s\n' base base-devel linux linux-firmware sudo mkinitcpio grub efibootmgr \
        openssh git vim nano python-pip python-virtualenv qt5-wayland \
        tesseract tesseract-data-eng llama-cpp ggml-vulkan
    grep -vE '^[[:space:]]*(#|$)' "$list"
    [ -d "${MKOS_REPO_DIR:-/opt/mkos-repo}" ] && printf '%s\n' piper-tts-bin yay-bin mpvpaper
    return 0
}

# mkos_enable_local_repo — let pacstrap (which uses the live system's
# pacman.conf) see the [mkos] repository bundled on the ISO
mkos_enable_local_repo() {
    [ -d /opt/mkos-repo ] || return 0
    grep -q '^\[mkos\]' /etc/pacman.conf || cat >>/etc/pacman.conf <<'EOF'

[mkos]
SigLevel = Optional TrustAll
Server = file:///opt/mkos-repo
EOF
}

# mkos_copy_assets <target root>
# Copies everything that makes an installed system "MKOS" from the live
# image onto the target: tools, their library, user services, completions,
# branding (plus the tmpfiles rule that re-asserts it after `filesystem`
# package updates), the AIOS backend, and the bundled [mkos] repository.
mkos_copy_assets() {
    local root=$1 f src=${MKOS_SRC:-}    # MKOS_SRC: a staged image tree (tests), default: this live system

    install -d "$root/usr/local/bin"
    for f in "$src"/usr/local/bin/mkos* "$src"/usr/local/bin/aios-*; do
        [ -e "$f" ] || continue
        case "${f##*/}" in
            mkos-live-setup|mkos-install-window|mkos-install|mkos-install-*|aios-install*) continue ;;   # live media only
        esac
        cp -a "$f" "$root/usr/local/bin/"
    done

    for f in /usr/local/libexec/aios-hardware \
             /usr/local/lib/mkos \
             /usr/local/share/aios \
             /usr/lib/mkos \
             /usr/lib/tmpfiles.d/mkos.conf \
             /usr/lib/systemd/user/mkos-first-boot.service \
             /usr/lib/systemd/user/mkos-genie.service \
             /usr/lib/systemd/user/aios.service.d \
             /usr/lib/systemd/user/swaync.service.d \
             /usr/lib/tmpfiles.d/mkos-memory.conf \
             /etc/sysctl.d/80-mkos-memory.conf \
             /etc/default/earlyoom \
             /usr/share/bash-completion/completions/mkos \
             /usr/share/zsh/site-functions/_mkos \
             /etc/systemd/zram-generator.conf \
             /etc/systemd/logind.conf.d/10-mkos.conf \
             /etc/systemd/system/emergency.service.d/override.conf \
             /etc/systemd/system/rescue.service.d/override.conf \
             /etc/wireplumber/wireplumber.conf.d/50-speaker-priority.conf \
             /etc/udev/rules.d/90-backlight.rules \
             /etc/modprobe.d/nvidia.conf \
             /etc/security/faillock.conf \
             /etc/sudoers.d/mkos-nopasswd \
             /etc/motd /etc/issue /etc/os-release; do
        [ -e "$src$f" ] || continue
        install -d "$root$(dirname "$f")"
        cp -a "$src$f" "$root$f"
    done
    # /usr/lib/os-release is a tmpfiles symlink on the live system; write the
    # real file so the branding is correct even before tmpfiles runs.
    [ -f "$src/usr/lib/mkos/os-release" ] && install -m644 "$src/usr/lib/mkos/os-release" "$root/usr/lib/os-release"

    [ -d "$src/opt/aios" ] && cp -a "$src/opt/aios" "$root/opt/aios"

    local repo=${MKOS_REPO_DIR:-/opt/mkos-repo}
    if [ -d "$repo" ]; then
        install -d "$root/opt/mkos-repo"
        cp -a "$repo/." "$root/opt/mkos-repo/"
        grep -q '^\[mkos\]' "$root/etc/pacman.conf" || cat >>"$root/etc/pacman.conf" <<'EOF'

[mkos]
SigLevel = Optional TrustAll
Server = file:///opt/mkos-repo
EOF
    fi

    [ -d "$src/etc/skel" ] && cp -a "$src/etc/skel/." "$root/etc/skel/"
}

# mkos_app_bundles — the optional app bundles the installers offer:
#   id|title|one-line description|packages (official repositories only)
mkos_app_bundles() {
    cat <<'BUNDLES'
office|Office|LibreOffice: documents, spreadsheets, slides — opens Microsoft Office files|libreoffice-fresh hunspell hunspell-en_us
dev|Developer|VS Code (Code - OSS), Docker, Node.js, GitHub CLI|code docker docker-compose docker-buildx nodejs npm github-cli python-pipx
media|Media|VLC, OBS Studio (record & stream), Audacity|vlc obs-studio audacity
creative|Creative|GIMP, Inkscape, Krita, Kdenlive|gimp inkscape krita kdenlive
gaming|Gaming|Steam, Lutris, GameMode, MangoHud (+ 32-bit drivers)|steam lutris gamemode lib32-gamemode mangohud lib32-mangohud
browsers|More browsers|Chromium next to Firefox|chromium
chat|Chat|Discord, Telegram|discord telegram-desktop
tools|Utilities|Disks, GParted, KeePassXC password manager, archive manager|gnome-disk-utility gparted keepassxc file-roller
BUNDLES
}

# mkos_bundle_pkgs <bundle id…> [-- <GPU driver packages>]
#   → packages for those bundles, one per line. Gaming adds the 32-bit
#   variants of this machine's GPU drivers (Steam's games are 32-bit).
mkos_bundle_pkgs() {
    local ids=() gpu=() id seen_gpu=0 p
    while [ $# -gt 0 ]; do
        if [ "$1" = -- ]; then shift; gpu=("$@"); break; fi
        ids+=("$1"); shift
    done
    for id in "${ids[@]}"; do
        mkos_app_bundles | awk -F'|' -v id="$id" '$1 == id { n = split($4, a, " "); for (i = 1; i <= n; i++) print a[i] }'
        if [ "$id" = gaming ] && [ "$seen_gpu" = 0 ]; then
            seen_gpu=1
            for p in "${gpu[@]}"; do
                case "$p" in
                    nvidia-utils)   echo lib32-nvidia-utils ;;
                    vulkan-intel)   echo lib32-vulkan-intel ;;
                    vulkan-radeon)  echo lib32-vulkan-radeon ;;
                    vulkan-nouveau) echo lib32-vulkan-nouveau ;;
                    mesa)           echo lib32-mesa ;;
                esac
            done
        fi
    done | awk '!seen[$0]++'
}

# mkos_target_services — system services every MKOS install enables
mkos_target_services() {
    printf '%s\n' NetworkManager bluetooth power-profiles-daemon systemd-timesyncd earlyoom fstrim.timer
}
