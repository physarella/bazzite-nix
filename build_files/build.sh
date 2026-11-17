#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### Hardware support -- must live in the image
#
# corectrl ships dbus system services and the privileged helper's polkit action
# into /usr, which nix fundamentally cannot provide. Stock Fedora 44 package,
# no COPR or RPM Fusion needed.
dnf5 install -y corectrl

# goxlr-utility is not in any repo; upstream ships an RPM on GitHub releases.
# Pinned by version and checksum so a retagged release cannot change the build.
# Verified byte-identical to the copy currently layered on the host.
GOXLR_VER=1.2.4
GOXLR_SHA=a3006b5536f98d162904c41a407c66810df2509ef47bb6457cbc8f2a05c297ea
curl -fsSL -o /tmp/goxlr.rpm \
  "https://github.com/GoXLR-on-Linux/goxlr-utility/releases/download/v${GOXLR_VER}/goxlr-utility-${GOXLR_VER}-1.x86_64.rpm"
echo "${GOXLR_SHA}  /tmp/goxlr.rpm" | sha256sum -c -
dnf5 install -y /tmp/goxlr.rpm
rm -f /tmp/goxlr.rpm

# The RPM ships no systemd unit -- upstream expects you to launch the daemon by
# hand from its desktop entry. system_files/ provides a user unit; enable it
# globally so it starts with the graphical session instead.
systemctl --global enable goxlr-daemon.service

### Obscura VPN
#
# A system service, an SELinux module and a sysusers group: none of which nix
# can provide. Previously layered with rpm-ostree, which blocks `bootc upgrade`.
#
# Packages track Obscura's repo; trust is anchored on the signing keys instead,
# pinned by fingerprint. If Obscura rotates its key the build fails here --
# check the new key out of band before re-pinning.
OBSCURA_RPM_BASE=https://linux-pkgs.obscura.com/rpm
OBSCURA_KEY_FPRS="952095FF926830EFE59875B7878908CE460572A7
2A5996C7C12D701E78ADC7A27FFA28C5B0D8256F"
curl -fsSL -o /tmp/obscura.key "${OBSCURA_RPM_BASE}/RPM-GPG-KEY-obscura"
# gpg needs a writable home even for --show-keys, and /root (/var/roothome)
# does not exist during the image build.
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
fetched_fprs=$(gpg --show-keys --with-colons /tmp/obscura.key | awk -F: '$1 == "fpr" {print $10}' | sort)
[ "$fetched_fprs" = "$(sort <<<"$OBSCURA_KEY_FPRS")" ]
rpm --import /tmp/obscura.key
rm -rf /tmp/obscura.key "$GNUPGHOME"
unset GNUPGHOME

# obscura-repository installs the .repo file itself, so it is bootstrapped from
# a temporary repo; gpgcheck verifies both packages against the keys above.
dnf5 install -y \
  --repofrompath="obscura-bootstrap,${OBSCURA_RPM_BASE}/x86_64" \
  --setopt=obscura-bootstrap.gpgcheck=1 \
  obscura-repository obscura

# The postinstall loads this with `|| true`, so a failure would ship silently.
semodule -l | grep -qx obscura

# The %post `systemctl start` is a no-op in a container build, and presets are
# not applied to an existing /etc on upgrade, so enable explicitly.
systemctl enable obscura.service

# This timer runs `rpm --import`, which fails every time against the read-only
# rpmdb in /usr. Key updates arrive with each image rebuild instead.
systemctl disable obscura-package-signing-key-refresh.timer
systemctl mask obscura-package-signing-key-refresh.service

### VR: Monado (OpenXR) + xrizer (OpenVR on top of OpenXR)
#
# Fedora packages Monado, so the old hand-layered dependency set for a native
# build that never happened -- boost, libuvc, onnxruntime, opencv,
# opencv-video, openhmd, openvr-api, librealsense -- stays dropped. Nothing
# required any of them (rpm -q --whatrequires was empty). librealsense is moot
# anyway: the "Valve Software 3D Camera" here is the Index's own stereo pair.
#
# xr-hardware carries the udev rules that give the seat user access to HMDs
# and controllers, which is why this lives in the image and not in nix.
#
# Which runtime is active is per-user state; `ujust vr-monado` and
# `ujust vr-steamvr` switch it. Nothing here makes Monado the default.
dnf5 install -y monado xr-hardware

# On AMD, Monado's compositor needs a high-priority GPU queue, which requires
# CAP_SYS_NICE; without it frames drop under load. Fedora's RPM does not set it.
setcap CAP_SYS_NICE=eip /usr/bin/monado-service
getcap /usr/bin/monado-service | grep -q cap_sys_nice

# xrizer is not packaged for Fedora; pinned upstream release, as with goxlr.
# Used over Fedora's opencomposite, which upstream no longer maintains.
# Bump by hand: neither dependabot nor renovate watches it.
XRIZER_VER=0.6
XRIZER_SHA=9b2105433e48a20f789e20a14113dbd98650afd116bd232419725a4438dd2149
curl -fsSL -o /tmp/xrizer.zip \
  "https://github.com/Supreeeme/xrizer/releases/download/v${XRIZER_VER}/xrizer-v${XRIZER_VER}.zip"
echo "${XRIZER_SHA}  /tmp/xrizer.zip" | sha256sum -c -
unzip -q /tmp/xrizer.zip -d /tmp/xrizer
mkdir -p /usr/lib64/xrizer
cp -a "/tmp/xrizer/xrizer-v${XRIZER_VER}/." /usr/lib64/xrizer/
test -f /usr/lib64/xrizer/bin/linux64/vrclient.so
rm -rf /tmp/xrizer /tmp/xrizer.zip

### Nix package manager
#
# Fedora 44 packages Nix natively, so no curl|sh installer is needed. This puts
# the binaries in /usr (immutable, versioned with the image) and creates the
# nixbld users via sysusers.d. The store itself is made writable by nix.mount +
# tmpfiles.d/nix-store.conf from system_files/.
#
# EVERY weak dependency must be named explicitly. This base sets
# install_weak_deps=False in /etc/dnf/dnf.conf, and `dnf5 install -y nix` alone
# silently drops all three of the things the `nix` metapackage Recommends. The
# authoritative list, and how to re-derive it if this ever changes:
#
#   dnf5 repoquery --recommends nix nix-core
#     -> busybox, nix-daemon (if systemd), nix-legacy
#
# Each was found the hard way, one failed build at a time, because each fails
# far from its cause:
#
#   nix-daemon   ships /usr/lib/systemd/system/nix-daemon.{socket,service}.
#                Without it the image build itself dies on
#                `systemctl enable nix-daemon.service`.
#
#   busybox      Fedora's /etc/nix/nix.conf hardcodes
#                  sandbox-paths = /bin/sh=/usr/bin/busybox
#                Substitution from cache.nixos.org is unaffected, so nix looks
#                perfectly healthy and `nix profile add` works -- but every
#                sandboxed *build* dies with "getting attributes of path
#                /usr/bin/busybox: No such file or directory". busybox is used
#                because it is static; pointing /bin/sh at the host bash fails,
#                as the sandbox has none of bash's dynamic libraries.
#
#   nix-legacy   provides nix-env, nix-build, nix-shell, nix-store and friends
#                as argv[0] symlinks to the multi-call nix binary. home-manager
#                activation calls nix-build and nix-env directly, and derives
#                its entire PATH as the store bins plus
#                  dirname $(readlink -m $(type -p nix-env))
#                so those commands and `nix` itself must all sit in one
#                directory. Without it, `home-manager switch` fails with
#                "nix-env: command not found" long after nix appears to work.
dnf5 install -y nix nix-daemon nix-legacy busybox

# Let anyone in wheel drive the daemon (add substituters, use flakes) without
# sudo. Without this, only root is trusted and unprivileged flake use is
# crippled. Fedora already enables nix-command + flakes in this file.
cat >>/etc/nix/nix.conf <<'EOF'

# --- added by image build ---
trusted-users = root @wheel
EOF

systemctl enable nix.mount

# Run the daemon as a plain service, NOT socket-activated.
#
# nix-daemon.socket has PID 1 create the listening socket, and SELinux denies
# that outright:
#
#   avc: denied { create } for pid=1 comm="systemd" name="socket"
#     scontext=init_t tcontext=default_t tclass=sock_file permissive=0
#
# Fedora ships nix with no SELinux policy, so file_contexts maps /nix/... to
# default_t and init_t may not create a sock_file of that type. This is a
# long-standing upstream issue (NixOS/nix#4913, #2374), not a quirk of the bind
# mount -- matchpathcon returns default_t for a native /nix as well, so socket
# activation fails the same way on any enforcing Fedora.
#
# nix-daemon.service creates the socket itself from a domain that is permitted
# to, and works. Verified on the running system: "Store URL: daemon,
# Trusted: 1". Disable the socket unit too, or it fails on every boot and
# leaves systemctl is-system-running reporting "degraded" forever.
systemctl disable nix-daemon.socket
systemctl enable nix-daemon.service

### Signature policy for this image
#
# CI signs the image with cosign, but a signature nothing checks is decoration.
# The base ships policy for ghcr.io/ublue-os only; ghcr.io/physarella would fall
# through to the catch-all "insecureAcceptAnything" entry and never be verified.
#
# Merged with jq rather than shipped as a static policy.json, so the base's own
# entries (ublue-os, Red Hat, toolbx) survive whatever upstream changes them to.
# The key and the registries.d entry come from system_files/.
jq --arg scope "ghcr.io/physarella" '
  .transports.docker[$scope] = [{
    "type": "sigstoreSigned",
    "keyPaths": ["/etc/pki/containers/physarella.pub"],
    "signedIdentity": {"type": "matchRepository"}
  }]
' /etc/containers/policy.json >/etc/containers/policy.json.new
mv /etc/containers/policy.json.new /etc/containers/policy.json
chmod 644 /etc/containers/policy.json

# Fail the build rather than ship an image whose own updates cannot be verified.
jq -e '.transports.docker["ghcr.io/physarella"][0].type == "sigstoreSigned"' \
  /etc/containers/policy.json >/dev/null

### Homebrew -- removed
#
# The base image carries a 126M homebrew.tar.zst and brew-setup.service, which
# unpacks it into /var/home/linuxbrew on first boot. Dropping the tarball alone
# already neuters the service (it has ConditionPathExists on that file), but
# mask the units too so nothing resurrects it, and reclaim the 126M.
systemctl disable brew-setup.service
systemctl mask \
  brew-setup.service brew-update.service brew-upgrade.service \
  brew-update.timer brew-upgrade.timer
rm -f /usr/share/homebrew.tar.zst

# /etc/profile.d/brew.sh is deliberately LEFT IN PLACE. It is guarded by
# [[ -d /home/linuxbrew/.linuxbrew ]], and the 6.3G install under
# /var/home/linuxbrew was deleted on 2026-08-12, so the guard already fails and
# the script is a no-op. It costs nothing to leave and keeps this build.sh from
# depending on host state that lives outside the image.
