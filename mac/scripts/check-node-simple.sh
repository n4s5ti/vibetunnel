#!/bin/bash
#
# Simplified Node.js check for build process
#
# This is a simpler version that's more robust and easier to debug
#

set -e

echo "Checking for Node.js..."

node_version_supported() {
    local version="$1"
    local major minor
    major=$(echo "$version" | cut -d'.' -f1)
    minor=$(echo "$version" | cut -d'.' -f2)

    [[ ( "$major" -gt 22 && "$major" -le 24 ) || ( "$major" -eq 22 && "$minor" -ge 12 ) ]]
}

find_supported_node() {
    local candidates=()
    local path_dir candidate expanded version

    if command -v node &>/dev/null; then
        candidates+=("$(command -v node)")
    fi

    candidates+=(
        "$HOME/.volta/bin/node"            # Volta
        "$HOME/.nvm/versions/node/*/bin/node"  # NVM (glob)
        "$HOME/.fnm/node-versions/*/bin/node"  # fnm (glob)
        "/opt/homebrew/bin/node"           # Homebrew ARM
        "/usr/local/bin/node"              # Homebrew Intel
        "/usr/bin/node"                    # System
    )

    IFS=':' read -ra path_dirs <<< "$PATH"
    for path_dir in "${path_dirs[@]}"; do
        candidates+=("$path_dir/node")
    done

    for candidate in "${candidates[@]}"; do
        for expanded in $candidate; do
            [[ -x "$expanded" ]] || continue
            version=$("$expanded" --version 2>/dev/null | cut -d'v' -f2) || continue
            if node_version_supported "$version"; then
                NODE_BIN="$expanded"
                NODE_VERSION="$version"
                return 0
            fi
            if [[ -z "$FIRST_NODE_BIN" ]]; then
                FIRST_NODE_BIN="$expanded"
                FIRST_NODE_VERSION="$version"
            fi
        done
    done

    return 1
}

NODE_BIN=""
NODE_VERSION=""
FIRST_NODE_BIN=""
FIRST_NODE_VERSION=""
find_supported_node || true

# Verify Node.js
if [[ -z "$NODE_BIN" ]] || [[ ! -x "$NODE_BIN" ]]; then
    if [[ -n "$FIRST_NODE_BIN" ]]; then
        echo "❌ Node.js 22.12 through 24.x is required (found v$FIRST_NODE_VERSION at $FIRST_NODE_BIN)"
    else
        echo "❌ Node.js not found!"
    fi
    echo ""
    echo "Please install Node.js 22.12 through 24.x:"
    echo "  • Homebrew: brew install node"
    echo "  • Download: https://nodejs.org/"
    echo "  • NVM: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash"
    echo ""
    echo "After installation, restart your terminal and try again."
    exit 1
fi

echo "✅ Node.js found: $NODE_BIN"
echo "   Version: v$NODE_VERSION"

# Check pnpm
echo ""
echo "Checking for pnpm..."

PNPM_PATHS=(
    "$HOME/Library/pnpm/pnpm"          # User install
    "$HOME/.local/share/pnpm/pnpm"     # Linux user install
    "/opt/homebrew/bin/pnpm"           # Homebrew ARM
    "/usr/local/bin/pnpm"              # Homebrew Intel
)

PNPM_BIN=""
for path in "${PNPM_PATHS[@]}"; do
    if [[ -x "$path" ]]; then
        PNPM_BIN="$path"
        break
    fi
done

# Also check PATH
if [[ -z "$PNPM_BIN" ]] && command -v pnpm &>/dev/null; then
    PNPM_BIN=$(command -v pnpm)
fi

if [[ -z "$PNPM_BIN" ]] || [[ ! -x "$PNPM_BIN" ]]; then
    echo "❌ pnpm not found!"
    echo ""
    echo "Please install pnpm:"
    echo "  • NPM: npm install -g pnpm"
    echo "  • Homebrew: brew install pnpm"
    echo "  • Standalone: curl -fsSL https://get.pnpm.io/install.sh | sh -"
    exit 1
fi

PNPM_VERSION=$("$PNPM_BIN" --version 2>/dev/null)
echo "✅ pnpm found: $PNPM_BIN"
echo "   Version: $PNPM_VERSION"

# Export paths for build scripts
export NODE_PATH="$NODE_BIN"
export PNPM_PATH="$PNPM_BIN"

# Success
echo ""
echo "✅ All build dependencies found!"
exit 0
