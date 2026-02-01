#!/usr/bin/env bash
# Hive Installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yourrepo/hive/main/install.sh | bash
#   or
#   ./install.sh
#
# Options:
#   --prefix <path>   Install to custom location (default: ~/.hive)
#   --no-path         Don't modify shell profile
#   --uninstall       Remove Hive

set -e

VERSION="2.0.0"
INSTALL_DIR="${HOME}/.hive"
MODIFY_PATH=true
UNINSTALL=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================================
# Helpers
# ============================================================================

info() {
    echo -e "${CYAN}▶${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
    exit 1
}

# ============================================================================
# Parse Arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --no-path)
            MODIFY_PATH=false
            shift
            ;;
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        -h|--help)
            echo "Hive Installer v$VERSION"
            echo ""
            echo "Usage: ./install.sh [options]"
            echo ""
            echo "Options:"
            echo "  --prefix <path>   Install to custom location (default: ~/.hive)"
            echo "  --no-path         Don't modify shell profile"
            echo "  --uninstall       Remove Hive"
            echo ""
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# ============================================================================
# Uninstall
# ============================================================================

if [ "$UNINSTALL" = true ]; then
    echo ""
    echo -e "${BOLD}Uninstalling Hive${NC}"
    echo ""
    
    if [ -d "$INSTALL_DIR" ]; then
        info "Removing $INSTALL_DIR..."
        rm -rf "$INSTALL_DIR"
        success "Removed Hive installation"
    else
        warn "Hive not found at $INSTALL_DIR"
    fi
    
    # Check for PATH in shell profiles
    for profile in ~/.bashrc ~/.zshrc ~/.profile ~/.bash_profile; do
        if [ -f "$profile" ] && grep -q "\.hive/bin" "$profile"; then
            info "Removing PATH from $profile..."
            # Create backup
            cp "$profile" "$profile.hive-backup"
            # Remove the hive lines
            grep -v "\.hive/bin" "$profile" > "$profile.tmp" && mv "$profile.tmp" "$profile"
            success "Cleaned $profile (backup: $profile.hive-backup)"
        fi
    done
    
    echo ""
    success "Hive uninstalled. Restart your shell or run: source ~/.bashrc"
    echo ""
    exit 0
fi

# ============================================================================
# Pre-flight Checks
# ============================================================================

echo ""
echo -e "${BOLD}🐝 Hive Installer v$VERSION${NC}"
echo ""

# Check dependencies
info "Checking dependencies..."

# Required: bash 4+
BASH_VERSION_NUM=${BASH_VERSION%%.*}
if [ "$BASH_VERSION_NUM" -lt 4 ]; then
    error "Bash 4.0+ required (found: $BASH_VERSION)"
    echo ""
    case "$(uname -s)" in
        Darwin*)
            echo "  macOS ships with Bash 3. Install Bash 4+ with:"
            echo "    brew install bash"
            echo ""
            echo "  Then either:"
            echo "    1. Run installer with new bash: /usr/local/bin/bash ./install.sh"
            echo "    2. Or add to /etc/shells and change default: chsh -s /usr/local/bin/bash"
            ;;
        *)
            echo "  Update bash with your package manager."
            ;;
    esac
    echo ""
    exit 1
fi
success "Bash $BASH_VERSION"

# Required: jq
if ! command -v jq &>/dev/null; then
    warn "jq not found - required for Hive"
    echo ""
    echo "  Install jq:"
    echo "    macOS:  brew install jq"
    echo "    Ubuntu: sudo apt install jq"
    echo "    Fedora: sudo dnf install jq"
    echo ""
    error "Please install jq and re-run the installer"
fi
success "jq $(jq --version 2>&1 | head -1)"

# Optional: git
if command -v git &>/dev/null; then
    success "git $(git --version | cut -d' ' -f3)"
else
    warn "git not found - git integration will be disabled"
fi

# Optional: gh (GitHub CLI)
if command -v gh &>/dev/null; then
    success "gh $(gh --version | head -1 | cut -d' ' -f3)"
else
    echo -e "  ${DIM}○ gh (GitHub CLI) not found - PR creation will be manual${NC}"
fi

# Check for Claude CLI or beads
if command -v claude &>/dev/null; then
    success "claude CLI found"
elif command -v bd &>/dev/null; then
    success "beads (bd) found"
else
    warn "Neither 'claude' nor 'bd' found"
    echo ""
    echo "  Hive requires Claude CLI or Beads for full functionality."
    echo "  Install Claude CLI: https://docs.anthropic.com/claude-cli"
    echo ""
fi

echo ""

# ============================================================================
# Install
# ============================================================================

info "Installing to $INSTALL_DIR..."

# Create directory structure
mkdir -p "$INSTALL_DIR"/{bin,lib,agents,workflows}

# Detect if running from extracted tarball or curl
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -d "$SCRIPT_DIR/bin" ] && [ -d "$SCRIPT_DIR/lib" ]; then
    # Installing from extracted tarball
    info "Installing from local files..."
    
    cp -r "$SCRIPT_DIR/bin"/* "$INSTALL_DIR/bin/"
    cp -r "$SCRIPT_DIR/lib"/* "$INSTALL_DIR/lib/"
    cp -r "$SCRIPT_DIR/agents"/* "$INSTALL_DIR/agents/"
    
    if [ -d "$SCRIPT_DIR/workflows" ]; then
        cp -r "$SCRIPT_DIR/workflows"/* "$INSTALL_DIR/workflows/" 2>/dev/null || true
    fi
else
    # Installing from curl - need to download
    error "Please extract the tarball first: tar -xzf hive-v2.tar.gz && cd hive && ./install.sh"
fi

# Make binaries executable
chmod +x "$INSTALL_DIR/bin"/*

success "Installed Hive files"

# ============================================================================
# PATH Setup
# ============================================================================

HIVE_BIN="$INSTALL_DIR/bin"
PATH_LINE="export PATH=\"\$PATH:$HIVE_BIN\""

# Check if already in PATH
if echo "$PATH" | grep -q "$HIVE_BIN"; then
    success "PATH already configured"
elif [ "$MODIFY_PATH" = true ]; then
    info "Adding Hive to PATH..."
    
    # Detect shell
    SHELL_NAME=$(basename "$SHELL")
    PROFILE=""
    
    case "$SHELL_NAME" in
        zsh)
            PROFILE="$HOME/.zshrc"
            ;;
        bash)
            if [ -f "$HOME/.bashrc" ]; then
                PROFILE="$HOME/.bashrc"
            elif [ -f "$HOME/.bash_profile" ]; then
                PROFILE="$HOME/.bash_profile"
            else
                PROFILE="$HOME/.profile"
            fi
            ;;
        *)
            PROFILE="$HOME/.profile"
            ;;
    esac
    
    # Add to profile if not already there
    if [ -f "$PROFILE" ] && grep -q "\.hive/bin" "$PROFILE"; then
        success "PATH already in $PROFILE"
    else
        echo "" >> "$PROFILE"
        echo "# Hive - AI agent orchestrator" >> "$PROFILE"
        echo "$PATH_LINE" >> "$PROFILE"
        success "Added to $PROFILE"
    fi
else
    echo ""
    warn "PATH not modified. Add manually:"
    echo "    $PATH_LINE"
fi

# ============================================================================
# Create version file
# ============================================================================

echo "$VERSION" > "$INSTALL_DIR/VERSION"

# ============================================================================
# Verify Installation
# ============================================================================

echo ""
info "Verifying installation..."

# Test that hive runs
if "$INSTALL_DIR/bin/hive" --version &>/dev/null; then
    success "Installation verified"
else
    # Try to see what's wrong
    "$INSTALL_DIR/bin/hive" --version 2>&1 || true
    error "Installation verification failed"
fi

# ============================================================================
# Done
# ============================================================================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  🐝 Hive v$VERSION installed successfully!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  To get started:"
echo ""
echo "    1. Restart your shell or run:"
echo -e "       ${CYAN}source $PROFILE${NC}"
echo ""
echo "    2. Initialize Hive in your project:"
echo -e "       ${CYAN}cd your-project && hive init${NC}"
echo ""
echo "    3. Run your first workflow:"
echo -e "       ${CYAN}hive run \"add user authentication\"${NC}"
echo ""
echo "  Commands:"
echo "    hive run \"objective\"    Run a workflow"
echo "    hive status --tui       Monitor in real-time"
echo "    hive doctor             Check setup"
echo "    hive help               Show all commands"
echo ""
