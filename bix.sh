#!/usr/bin/env bash

# --- CLI argument parsing (GNU getopt) ---
PARSED=$(getopt -o uc: -l update,config: -- "$@")
if [[ $? -ne 0 ]]; then
    exit 1
fi

eval set -- "$PARSED"

DO_UPDATE=0
BIX_CONFIG=""

while true; do
    case "$1" in
        -u|--update)
            DO_UPDATE=1
            shift
            ;;
        -c|--config)
            BIX_CONFIG="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
    esac
done

CMD="$1"
shift || true

SYSTEM_CONFIG="/etc/bix/packages.bix"
USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/bix/packages.bix"

conf_control () {
    if [[ -n "$BIX_CONFIG" ]]; then
        CONFIG="$BIX_CONFIG"
    elif [[ -f "$SYSTEM_CONFIG" ]]; then
        CONFIG="$SYSTEM_CONFIG"
    else
        echo "No bix config found."
        echo "Looked for:"
        echo "  $SYSTEM_CONFIG"
        exit 1
    fi
}

BACKUP="$CONFIG.bak"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/bix"
mkdir -p "$CACHE_DIR"

is_system_config() {
    [[ "$CONFIG" == /etc/bix/* ]]
}

# --- Privilege escalation detection ---
doas_control() {
    if command -v doas >/dev/null 2>&1; then
        priv="doas"
        doas true
    elif command -v sudo >/dev/null 2>&1; then
        priv="sudo"
        sudo -v
    else
        echo "Error: neither doas nor sudo found."
        exit 1
    fi
}

# --- Config flags ---
pm_aur_enabled() {
    grep -qE 'pm\s*\{[^}]*aur\s*=\s*true' "$CONFIG"
}

# --- Package manager abstraction ---
pm_install() {
    local pkgs=("$@")
    for pkg in "${pkgs[@]}"; do
        run_hooks pre-install "$pkg"
    done
    if command -v yay &>/dev/null && pm_aur_enabled; then
        yay -S --noconfirm "$@"
    elif command -v pacman &>/dev/null; then
        $priv pacman -S --noconfirm "$@"
    elif command -v apt &>/dev/null; then
        $priv apt install -y "$@"
    elif command -v dnf &>/dev/null; then
        $priv dnf install -y "$@"
    elif command -v apk &>/dev/null; then
        $priv apk add "$@"
    fi
    for pkg in "${pkgs[@]}"; do
        run_hooks post-install "$pkg"
    done
}

pm_remove() {
    local pkgs=("$@")
    for pkg in "${pkgs[@]}"; do
        run_hooks pre-remove "$pkg"
    done
    if command -v yay &>/dev/null && pm_aur_enabled; then
        yay -R --noconfirm "$@"
    elif command -v pacman &>/dev/null; then
        $priv pacman -R --noconfirm "$@"
    elif command -v apt &>/dev/null; then
        $priv apt remove -y "$@"
    elif command -v dnf &>/dev/null; then
        $priv dnf remove -y "$@"
    elif command -v apk &>/dev/null; then
        $priv apk del "$@"
    fi
    for pkg in "${pkgs[@]}"; do
        run_hooks post-remove "$pkg"
    done
}

pm_apply() {
    local pkgs=("$@")
    for pkg in "${pkgs[@]}"; do
        run_hooks pre-install "$pkg"
    done
    if command -v pacman &>/dev/null; then
        $priv pacman -U --noconfirm "$@"
    elif command -v apt &>/dev/null; then
        $priv dpkg -i "$@" || $priv apt-get -f install -y
    elif command -v dnf &>/dev/null; then
        $priv dnf install -y "$@"
    elif command -v apk &>/dev/null; then
        $priv apk add --allow-untrusted "$@"
    fi
    for pkg in "${pkgs[@]}"; do
        run_hooks post-install "$pkg"
    done
}

# --- Version detection ---
get_installed_version() {
    if command -v yay &>/dev/null && pm_aur_enabled; then
        LANG=C yay -Qi "$1" 2>/dev/null | awk -F': ' '/^Version/{print $2}'
    elif command -v pacman &>/dev/null; then
        LANG=C pacman -Qi "$1" 2>/dev/null | awk -F': ' '/^Version/{print $2}'
    elif command -v apt &>/dev/null; then
        dpkg-query -W -f='${Version}\n' "$1" 2>/dev/null
    elif command -v dnf &>/dev/null; then
        rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$1" 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk info -e "$1" && apk info "$1" | head -n1 | sed 's/^[^-]*-//'
    fi
}

get_latest_version() {
    if command -v yay &>/dev/null && pm_aur_enabled; then
        LANG=C yay -Si "$1" 2>/dev/null | awk -F': ' '/^Version/{print $2}'
    elif command -v pacman &>/dev/null; then
        LANG=C pacman -Si "$1" 2>/dev/null | awk -F': ' '/^Version/{print $2}'
    elif command -v apt &>/dev/null; then
        apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}'
    elif command -v dnf &>/dev/null; then
        repoquery --qf '%{VERSION}-%{RELEASE}' "$1" 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk policy "$1" 2>/dev/null | awk '/<available>/{print $1}'
    fi
}

# --- Config helpers ---
get_packages_from_config() {
    grep -E 'package "' "$1" | sed -E 's/.*package "([^"]+)".*/\1/'
}

package_exists() {
    grep -qE "package \"$1\"" "$CONFIG"
}

# --- Add package ---
add_package() {
    conf_control
    doas_control
    local pkg="$1"

    if is_system_config; then
        echo "Refusing to modify system config without explicit intent."
        echo "Use: sudo bix add $pkg"
        exit 1
    fi

    if package_exists "$pkg"; then
        echo "Package already exists: $pkg"
    else
        mkdir -p "$(dirname "$CONFIG")"
        echo -e "\npackage \"$pkg\" {}" >> "$CONFIG"
        echo "Package added: $pkg"
    fi
}

# Global veya package hook al
get_hooks() {
    local hook_type="$1"  # pre-install, post-update, vs
    local pkg_name="$2"   # boşsa global, doluysa paket özel

    if [[ -z "$pkg_name" ]]; then
        # global
        grep -E "^\s*$hook_type\s+\"" "$CONFIG" | sed -E 's/.*"([^"]+)".*/\1/'
    else
        # package özel
        awk -v pkg="$pkg_name" -v hook="$hook_type" '
            $0 ~ "package \""pkg"\"" { inpkg=1 }
            inpkg && $0 ~ hook { match($0, /"([^"]+)"/, a); print a[1] }
            $0 ~ "}" && inpkg { inpkg=0 }
        ' "$CONFIG"
    fi
}

run_hooks() {
    local hook="$1"
    shift
    local pkg="$1"
    shift

    local cmds
    cmds=$(get_hooks "$hook" "$pkg")

    [[ -z "$cmds" ]] && return 0

    export bix_EVENT="$hook"
    export bix_PACKAGES="$pkg"
    export bix_ARGS="$*"

    while IFS= read -r cmd; do
        echo "running: $hook (${pkg:-global}): $cmd"
        if is_system_config; then
            $priv bash -c "$cmd"
        else
            bash -c "$cmd"
        fi
    done <<< "$cmds"
}

# --- Sync ---
sync_packages() {
    conf_control
    doas_control
    local do_update="$DO_UPDATE"

    # Removed packages
    if [[ -f "$BACKUP" ]]; then
        old_pkgs=$(get_packages_from_config "$BACKUP")
        new_pkgs=$(get_packages_from_config "$CONFIG")

        for pkg in $old_pkgs; do
            if ! echo "$new_pkgs" | grep -qx "$pkg"; then
                read -rp "Package removed from config: $pkg. Remove from system? [Y/n]: " ans
                if [[ "$ans" =~ ^[Yy]?$ ]]; then
                    pm_remove "$pkg"
                else
                    echo "Skipped: $pkg"
                fi
            fi
        done
    fi

    cp "$CONFIG" "$BACKUP"

    local repo_install=()
    local pkg="" source="" repo="" asset="" url=""

    while read -r line; do
        [[ $line =~ package\ \"([^\"]+)\" ]] && pkg="${BASH_REMATCH[1]}"
        [[ $line =~ source\ *=\ *\"([^\"]+)\" ]] && source="${BASH_REMATCH[1]}"
        [[ $line =~ repo\ *=\ *\"([^\"]+)\" ]] && repo="${BASH_REMATCH[1]}"
        [[ $line =~ asset\ *=\ *\"([^\"]+)\" ]] && asset="${BASH_REMATCH[1]}"
        [[ $line =~ url\ *=\ *\"([^\"]+)\" ]] && url="${BASH_REMATCH[1]}"

        if [[ $line =~ \} ]]; then
            if [[ -n "$pkg" ]]; then
                installed_ver=$(get_installed_version "$pkg")
                latest_ver=$(get_latest_version "$pkg")

                if [[ -z "$source" || "$source" == "repo" ]]; then
                    if [[ -z "$installed_ver" ]]; then
                        echo "Will install (repo): $pkg"
                        repo_install+=("$pkg")
                    elif [[ $do_update -eq 1 && "$installed_ver" != "$latest_ver" ]]; then
                        echo "Will update (repo): $pkg"
                        repo_install+=("$pkg")
                    fi
                elif [[ "$source" == "github" ]]; then
                    echo "Will install (github): $pkg"
                    dl="$CACHE_DIR/$asset"
                    curl -L "https://github.com/$repo/releases/latest/download/$asset" -o "$dl"
                    pm_apply "$dl"
                elif [[ "$source" == "url" ]]; then
                    echo "Will install (url): $pkg"
                    dl="$CACHE_DIR/$(basename "$url")"
                    curl -L "$url" -o "$dl"
                    pm_apply "$dl"
                fi
            fi

            pkg=""; source=""; repo=""; asset=""; url=""
        fi
    done < "$CONFIG"

    if [[ ${#repo_install[@]} -gt 0 ]]; then
        echo ""
        pm_install "${repo_install[@]}"
    fi
}

# --- Diff ---
diff() {
    conf_control
    # Removed packages
    if [[ -f "$BACKUP" ]]; then
        old_pkgs=$(get_packages_from_config "$BACKUP")
        new_pkgs=$(get_packages_from_config "$CONFIG")

        for pkg in $old_pkgs; do
            if ! echo "$new_pkgs" | grep -qx "$pkg"; then
                echo "Will remove (repo): $pkg"
            fi
        done
    fi

    # Added / updated packages
    local repo_install=()
    local pkg="" source="" repo="" asset="" url=""

    while read -r line; do
        [[ $line =~ package\ \"([^\"]+)\" ]] && pkg="${BASH_REMATCH[1]}"
        [[ $line =~ source\ *=\ *\"([^\"]+)\" ]] && source="${BASH_REMATCH[1]}"
        [[ $line =~ repo\ *=\ *\"([^\"]+)\" ]] && repo="${BASH_REMATCH[1]}"
        [[ $line =~ asset\ *=\ *\"([^\"]+)\" ]] && asset="${BASH_REMATCH[1]}"
        [[ $line =~ url\ *=\ *\"([^\"]+)\" ]] && url="${BASH_REMATCH[1]}"

        if [[ $line =~ \} ]]; then
            if [[ -n "$pkg" ]]; then
                installed_ver=$(get_installed_version "$pkg")
                latest_ver=$(get_latest_version "$pkg")

                if [[ -z "$source" || "$source" == "repo" ]]; then
                    if [[ -z "$installed_ver" ]]; then
                        echo "Will install (repo): $pkg"
                    elif [[ "$installed_ver" != "$latest_ver" ]]; then
                        echo "Will update (repo): $pkg"
                    fi
                elif [[ "$source" == "github" ]]; then
                    echo "Will install (github): $pkg"
                elif [[ "$source" == "url" ]]; then
                    echo "Will install (url): $pkg"
                fi
            fi
            # blok sonunda sıfırla
            pkg=""; source=""; repo=""; asset=""; url=""
        fi
    done < "$CONFIG"
}

# --- List ---
list_packages() {
    grep -E 'package "' "$CONFIG" | sed -E 's/.*package "([^"]+)".*/\1/'
}


init_config() {
    doas_control

    if [[ -f "$SYSTEM_CONFIG" ]]; then
        echo "System config already exists:"
        echo "  $SYSTEM_CONFIG"
        exit 0
    fi

    echo "Initializing bix system config at:"
    echo "  $SYSTEM_CONFIG"

    $priv mkdir -p /etc/bix

    $priv tee "$SYSTEM_CONFIG" >/dev/null <<'EOF'
# bix system configuration
# created with bix init

pm {
    # if you are not using arch, you can delete this
    # aur = true
}

# Example:
# package "htop" {}
# package "git" {
#     pre-install  "echo installing git"
#     post-install "git --version"
# }
EOF

    $priv chmod 644 "$SYSTEM_CONFIG"

    echo "bix system config created."
}

# --- Help ---
show_help() {
    cat <<EOF
Usage: bix [options] <command>

Options:
  -u, --update           Update packages during sync
  -c, --config <path>    Use alternate config file

Commands:
  list           List packages
  init           Create config file
  diff           Show what if you execute sync -u
  add <package>  Add repository package
  sync           Install missing packages
  help           Show this help
EOF
}

# --- CLI ---
case "$CMD" in
    list)
        list_packages
        ;;
    init)
        init_config
        ;;
    diff)
        diff
        ;;
    add)
        [[ -z "$1" ]] && { echo "Package name required."; exit 1; }
        add_package "$1"
        ;;
    sync)
        sync_packages
        ;;
    help|"")
        show_help
        ;;
    *)
        echo "Unknown command: $CMD"
        show_help
        exit 1
        ;;
esac