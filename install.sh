#!/usr/bin/env bash
set -e

REPO_URL="https://raw.githubusercontent.com/Bilal1545/bix/main/bix.sh"
TARGET="/usr/local/bin/bix"
priv="sudo"

echo "Installing bix to $TARGET"

if [[ $EUID -ne 0 ]]; then
    if command -v doas >/dev/null 2>&1; then
        doas true
        priv="doas"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -v
    fi
fi

$priv rm -f "$TARGET"
$priv curl -fsSL "$REPO_URL" -o "$TARGET"
$priv chmod +x "$TARGET"

echo ""
echo "bix installed successfully."
echo "Run: bix help"