#!/usr/bin/env bash

# --- CLI argument parsing (GNU getopt) ---
PARSED=$(getopt -o uc: -l update,config: -- "$@")
if [[ $? -ne 0 ]]; then
    exit 1
fi

eval set -- "$PARSED"

DO_UPDATE=0
BIX_CONFIG=""

detect_aur_helper() {
    for h in yay paru trizen aura pikaur; do
        command -v "$h" &>/dev/null && { AUR_HELPER="$h" }
    done
}

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
    if command -v pacman &>/dev/null && pm_aur_enabled; then
        $AUR_HELPER -S --noconfirm "$@"
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
    if command -v pacman &>/dev/null && pm_aur_enabled; then
        $AUR_HELPER -R --noconfirm "$@"
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
    if command -v pacman &>/dev/null && pm_aur_enabled; then
        LANG=C $AUR_HELPER -Qi "$1" 2>/dev/null | awk -F': ' '/^Version/{print $2}'
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
    if command -v pacman &>/dev/null && pm_aur_enabled; then
        LANG=C $AUR_HELPER -Si "$1" 2>/dev/null | awk -F': ' '/^Version/{print $2}'
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
    grep -E '^\s*package "' "$1" | grep -v '^\s*#' | sed -E 's/.*package "([^"]+)".*/\1/'
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

btow_sync() {
    # Eğer btow yoksa, sorarak kur
    if ! command -v btow &>/dev/null; then
        read -rp "btow komutu bulunamadı. Kurmak ister misiniz? [Y/n]: " ans
        if [[ "$ans" =~ ^[Yy]?$ ]]; then
            echo "Installing btow..."
            curl -fsSL https://raw.githubusercontent.com/Bilal1545/btow/main/install.sh | bash
        else
            echo "Skipping btow integration."
            return 0
        fi
    fi

    local loaded_name=""
    local pkg_url=""
    
    # btow block parser
    awk '
        /^\s*btow\s*\{/ { in_btow=1; next }
        in_btow && /loaded\s*:/ { match($0, /loaded:\s*"([^"]+)"/, a); print "LOADED:" a[1] }
        in_btow && /package\s*"([^"]+)"/ { pkg=$2 }
        in_btow && /url\s*:/ { match($0, /url:\s*"([^"]+)"/, a); print "PACKAGE:" pkg ":" a[1] }
        in_btow && /^\s*\}/ { exit }
    ' "$CONFIG" | while IFS= read -r line; do
        if [[ $line == LOADED:* ]]; then
            loaded_name="${line#LOADED:}"
        elif [[ $line == PACKAGE:* ]]; then
            IFS=':' read -r pkgname pkg_url <<< "${line#PACKAGE:}"
            dl="$CACHE_DIR/$pkgname.btow"
            echo "Downloading btow package '$pkgname' from $pkg_url ..."
            curl -L "$pkg_url" -o "$dl"
            btow import "$dl"
            btow load "$loaded_name"
        fi
    done

    # load profile eğer set edilmişse
    if [[ -n "$loaded_name" ]]; then
        echo "Loading btow profile '$loaded_name' ..."
        btow load "$loaded_name"
    fi
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
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        [[ $line =~ package\ \"([^\"]+)\" ]] && pkg="${BASH_REMATCH[1]}"
        [[ $line =~ version\ *=\ *\"([^\"]+)\" ]] && version="${BASH_REMATCH[1]}"
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
    btow_sync
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
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        [[ $line =~ package\ \"([^\"]+)\" ]] && pkg="${BASH_REMATCH[1]}"
        [[ $line =~ version\ *=\ *\"([^\"]+)\" ]] && version="${BASH_REMATCH[1]}"
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

capture() {
    echo "# bix package config"
    echo "# generated: $(date -Is)"
    echo

    # ---- pacman & forks ----
    if command -v pacman >/dev/null 2>&1; then
        echo "packages {"
        pacman -Qqe | sed 's/^/    /'
        echo "}"

        if [ "${pm_aur_enabled:-false}" = "true" ]; then
            local aur_pkgs=""
            if [ -n "${AUR_HELPER:-}" ] && command -v "$AUR_HELPER" >/dev/null 2>&1; then
                aur_pkgs=$("$AUR_HELPER" -Qqm 2>/dev/null)
            else
                aur_pkgs=$(pacman -Qqm)
            fi

            if [ -n "$aur_pkgs" ]; then
                echo
                echo "aur {"
                echo "$aur_pkgs" | sed 's/^/    /'
                echo "}"
            fi
        fi
        return 0
    fi

    # ---- apt & forks ----
    if command -v apt >/dev/null 2>&1; then
        echo 'pm "apt"'
        echo

        echo "packages {"
        apt-mark showmanual | sed 's/^/    /'
        echo "}"
        return 0
    fi

    # ---- dnf & forks ----
    if command -v dnf >/dev/null 2>&1; then
        echo 'pm "dnf"'
        echo

        echo "packages {"
        dnf repoquery --userinstalled --qf '%{name}' 2>/dev/null | sed 's/^/    /'
        echo "}"
        return 0
    fi

    # ---- apk ----
    if command -v apk >/dev/null 2>&1; then
        echo 'pm "apk"'
        echo

        echo "packages {"
        apk info --installed | sed 's/^/    /'
        echo "}"
        return 0
    fi

    echo "# unsupported package manager"
    return 1
}

# --- List ---
list_packages() {
    conf_control
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
  capture        Capture the packages YOU installed
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