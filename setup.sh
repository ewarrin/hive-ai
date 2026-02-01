#!/usr/bin/env bash
# Hive Setup Script
# Installs Hive globally to ~/.hive

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${YELLOW}"
cat << 'LOGO'
     __    __    __
    /  \__/  \__/  \
    \__/  \__/  \__/
       \__/  \__/
LOGO
echo -e "${NC}"
echo -e "${BOLD}  H I V E${NC}  ${DIM}v2.0.0${NC}"
echo ""

# Get the directory where this script is located (the extracted hive folder)
HIVE_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIVE_ROOT="$HOME/.hive"

echo "Source: $HIVE_SRC"
echo "Installing to: $HIVE_ROOT"
echo ""

# Create Hive home directory
mkdir -p "$HIVE_ROOT"
mkdir -p "$HIVE_ROOT/bin"
mkdir -p "$HIVE_ROOT/lib"
mkdir -p "$HIVE_ROOT/agents"
mkdir -p "$HIVE_ROOT/contracts"
mkdir -p "$HIVE_ROOT/workflows"

# Copy files from source
echo "Copying files..."
cp "$HIVE_SRC/bin/hive" "$HIVE_ROOT/bin/"
cp "$HIVE_SRC/lib/"*.sh "$HIVE_ROOT/lib/"
cp "$HIVE_SRC/agents/"*.md "$HIVE_ROOT/agents/"
cp "$HIVE_SRC/contracts/"*.json "$HIVE_ROOT/contracts/"

# Make executable
chmod +x "$HIVE_ROOT/bin/hive"

echo -e "${GREEN}✓${NC} Files copied"

# Check shell and update config
SHELL_CONFIG=""
if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
    SHELL_CONFIG="$HOME/.zshrc"
elif [ -n "$BASH_VERSION" ] || [ -f "$HOME/.bashrc" ]; then
    SHELL_CONFIG="$HOME/.bashrc"
fi

# Add to PATH if not already there
if [ -n "$SHELL_CONFIG" ]; then
    if ! grep -q "HIVE_ROOT" "$SHELL_CONFIG" 2>/dev/null; then
        echo "" >> "$SHELL_CONFIG"
        echo "# Hive - AI Agent Orchestration" >> "$SHELL_CONFIG"
        echo "export HIVE_ROOT=\"$HIVE_ROOT\"" >> "$SHELL_CONFIG"
        echo "export PATH=\"\$HIVE_ROOT/bin:\$PATH\"" >> "$SHELL_CONFIG"
        echo -e "${GREEN}✓${NC} Added Hive to PATH in $SHELL_CONFIG"
    else
        echo -e "${YELLOW}⚠${NC} Hive already in $SHELL_CONFIG"
    fi
fi

# Check dependencies
echo ""
echo "Checking dependencies..."

DEPS_OK=true

if command -v jq &>/dev/null; then
    echo -e "${GREEN}✓${NC} jq installed"
else
    echo -e "${RED}✗${NC} jq not found - install with: brew install jq"
    DEPS_OK=false
fi

if command -v claude &>/dev/null; then
    echo -e "${GREEN}✓${NC} Claude Code CLI installed"
else
    echo -e "${RED}✗${NC} Claude Code CLI not found - install with: npm install -g @anthropic-ai/claude-code"
    DEPS_OK=false
fi

if command -v bd &>/dev/null; then
    echo -e "${GREEN}✓${NC} Beads installed"
else
    echo -e "${RED}✗${NC} Beads not found - install from: https://github.com/steveyegge/beads"
    DEPS_OK=false
fi

echo ""

if [ "$DEPS_OK" = true ]; then
    echo -e "${GREEN}${BOLD}Hive installed successfully!${NC}"
else
    echo -e "${YELLOW}${BOLD}Hive installed with missing dependencies.${NC}"
    echo "Please install missing dependencies before using Hive."
fi

echo ""
echo "Next steps:"
echo "  1. Reload your shell: source $SHELL_CONFIG"
echo "  2. Navigate to a project: cd your-project"
echo "  3. Initialize Hive: hive init"
echo "  4. Run a workflow: hive run \"your objective\""
echo ""
echo "For help: hive help"
