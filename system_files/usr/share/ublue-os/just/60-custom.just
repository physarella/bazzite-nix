# vim: set ft=make :
#
# Imported automatically by /usr/share/ublue-os/justfile via
#   import? "/usr/share/ublue-os/just/60-custom.just"
# so no patching of the main justfile is needed.

CLEAN_HOME_CONF := "/usr/share/ublue-os/clean-home.conf"

# Show what `ujust clean-home` would delete, without deleting anything
clean-home-preview:
    #!/usr/bin/bash
    set -uo pipefail
    echo "== trash + caches older than 30 days =="
    # systemd-tmpfiles logs "Would remove ..." to stderr, not stdout, so 2>&1
    # is required here -- redirecting stderr to /dev/null silently yields zero
    # results and makes the preview look like there is nothing to clean.
    out=$(systemd-tmpfiles --user --clean --dry-run "{{ CLEAN_HOME_CONF }}" 2>&1 \
          | sed -n 's/^Would remove "\(.*\)"$/\1/p')
    n=$(printf '%s' "$out" | grep -c . || true)
    printf '%s\n' "$out" | head -25 | sed 's/^/  /'
    [ "$n" -gt 25 ] && echo "  ... and $((n - 25)) more"
    echo "  $n paths total"
    echo
    echo "== nix store =="
    if command -v nix >/dev/null 2>&1; then
        nix store gc --dry-run 2>&1 | tail -3 | sed 's/^/  /'
    else
        echo "  nix not installed"
    fi

# Delete trash and caches older than 30 days, then collect nix store garbage
clean-home:
    #!/usr/bin/bash
    set -uo pipefail
    before=$(df -B1 --output=avail /var/home | tail -1 | tr -d ' ')

    echo ":: trash + caches older than 30 days"
    systemd-tmpfiles --user --clean "{{ CLEAN_HOME_CONF }}"

    if command -v nix >/dev/null 2>&1; then
        echo ":: nix store"
        # Old profile generations pin their whole closure, so they have to go
        # first or gc has nothing it is allowed to collect.
        nix profile wipe-history --older-than 30d || true
        nix store gc || true
    fi

    after=$(df -B1 --output=avail /var/home | tail -1 | tr -d ' ')
    freed=$((after - before))
    if [ "$freed" -gt 0 ]; then
        echo ":: freed $(numfmt --to=iec "$freed") on /var/home"
    else
        echo ":: nothing to reclaim"
    fi

# Report every top-level entry in $HOME by size and last interaction date
home-report:
    #!/usr/bin/bash
    set -uo pipefail
    cd "$HOME" || exit 1
    echo "scanning $HOME ..." >&2
    find . -xdev -mindepth 1 -printf '%T@\t%s\t%P\n' 2>/dev/null | awk -F'\t' '
    {
      split($3, a, "/"); top = a[1]
      if (top == "") next
      if ($1 > mt[top]) mt[top] = $1
      sz[top] += $2; n[top]++
    }
    END { for (t in mt) printf "%d\t%d\t%d\t%s\n", mt[t], sz[t], n[t], t }
    ' | sort -n | awk -F'\t' '{
      s = $2
      h = (s >= 1073741824) ? sprintf("%.1fG", s/1073741824) \
        : (s >= 1048576)    ? sprintf("%.0fM", s/1048576) \
        :                     sprintf("%.0fK", s/1024)
      printf "%-26s %9s  %8d files  %s\n", $4, h, $3, strftime("%Y-%m-%d", $1)
    }'

OPENXR_ACTIVE := "$HOME/.config/openxr/1/active_runtime.json"
OPENVR_PATHS := "$HOME/.config/openvr/openvrpaths.vrpath"
STEAMVR_DIR := "$HOME/.local/share/Steam/steamapps/common/SteamVR"

# Make Monado the OpenXR runtime and xrizer the OpenVR runtime
vr-monado:
    #!/usr/bin/bash
    set -euo pipefail
    # Steam's container sees $HOME but not the host's /usr, and a symlink into
    # /usr would resolve against the container's own /usr. So xrizer needs a
    # real copy here; refreshed on every run so an image bump reaches it.
    xrizer="$HOME/.local/share/xrizer"
    rm -rf "$xrizer"
    cp -r /usr/lib64/xrizer "$xrizer"

    # A copy with absolute paths, not a symlink: the manifest's paths are
    # relative ("../../../lib64/..."), and loaders that resolve them from the
    # symlink's directory end up under $HOME.
    manifest=/usr/share/openxr/1/openxr_monado.json
    manifest_dir=$(dirname "$manifest")
    abs_path() {
        local p
        p=$(jq -r "$1" "$manifest")
        [[ $p == /* ]] || p="$manifest_dir/$p"
        realpath -ms "$p"
    }
    mkdir -p "$(dirname "{{ OPENXR_ACTIVE }}")"
    rm -f "{{ OPENXR_ACTIVE }}"
    jq --arg lib "$(abs_path .runtime.library_path)" \
       --arg mnd "$(abs_path .runtime.MND_libmonado_path)" \
       '.runtime.library_path = $lib | .runtime.MND_libmonado_path = $mnd' \
       "$manifest" >"{{ OPENXR_ACTIVE }}"

    just --justfile "{{ justfile() }}" _vr-set-openvr-runtime "$xrizer"
    # SteamVR rewrites this file to point back at itself whenever it starts,
    # including for Room Setup. Read-only keeps xrizer in place.
    chmod 444 "{{ OPENVR_PATHS }}"

    systemctl --user enable --now monado.socket
    echo ":: Monado + xrizer active. Restart Steam if it is running."

# Make SteamVR the OpenXR and OpenVR runtime again
vr-steamvr:
    #!/usr/bin/bash
    set -euo pipefail
    if [ ! -f "{{ STEAMVR_DIR }}/steamxr_linux64.json" ]; then
        echo "SteamVR not found at {{ STEAMVR_DIR }}; install it from Steam first." >&2
        exit 1
    fi
    systemctl --user disable --now monado.socket monado.service || true

    mkdir -p "$(dirname "{{ OPENXR_ACTIVE }}")"
    ln -sfn "{{ STEAMVR_DIR }}/steamxr_linux64.json" "{{ OPENXR_ACTIVE }}"

    [ -f "{{ OPENVR_PATHS }}" ] && chmod 644 "{{ OPENVR_PATHS }}"
    just --justfile "{{ justfile() }}" _vr-set-openvr-runtime "{{ STEAMVR_DIR }}"
    echo ":: SteamVR active. Restart Steam if it is running."

# Show which OpenXR and OpenVR runtimes are active
vr-status:
    #!/usr/bin/bash
    set -uo pipefail
    echo "OpenXR: $(readlink -f "{{ OPENXR_ACTIVE }}" 2>/dev/null || echo 'none (system default)')"
    echo "OpenVR: $(jq -r '.runtime[0] // "none"' "{{ OPENVR_PATHS }}" 2>/dev/null || echo none)"
    echo "monado.socket: $(systemctl --user is-active monado.socket)"

# Point openvrpaths.vrpath at one runtime, keeping SteamVR's config and log paths
_vr-set-openvr-runtime runtime:
    #!/usr/bin/bash
    set -euo pipefail
    paths="{{ OPENVR_PATHS }}"
    steam="$HOME/.local/share/Steam"
    mkdir -p "$(dirname "$paths")"
    current=$(cat "$paths" 2>/dev/null || echo '{}')
    jq --arg rt "{{ runtime }}" --arg steam "$steam" '
      .runtime = [$rt]
      | .config //= [$steam + "/config"]
      | .log //= [$steam + "/logs"]
      | .external_drivers //= null
      | .jsonid = "vrpathreg"
      | .version = 1
    ' <<<"$current" >"$paths.new"
    mv -f "$paths.new" "$paths"
