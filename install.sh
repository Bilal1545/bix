#!/usr/bin/env bash
set -e

REPO_URL="https://raw.githubusercontent.com/Bilal1545/bix/main/bix.sh"
TARGET="/usr/local/bin/bix"

echo "Installing bix to $TARGET"

if [[ $EUID -ne 0 ]]; then
    if command -v doas >/dev/null 2>&1; then
        exec doas bash "$0"
    elif command -v sudo >/dev/null 2>&1; then
        exec sudo bash "$0"
    else
        echo "Error: need root (sudo or doas)"
        exit 1
    fi
fi

curl -fsSL "$REPO_URL" -o "$TARGET"
chmod +x "$TARGET"

echo ""
echo "bix installed successfully."
echo "Run: bix help"