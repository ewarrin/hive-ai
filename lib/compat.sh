#!/usr/bin/env bash
# Hive Cross-Platform Compatibility
#
# Provides consistent behavior across Linux, macOS, and WSL

# ============================================================================
# Platform Detection
# ============================================================================

_HIVE_PLATFORM=""

detect_platform() {
    if [ -n "$_HIVE_PLATFORM" ]; then
        echo "$_HIVE_PLATFORM"
        return
    fi
    
    case "$(uname -s)" in
        Linux*)
            if grep -q Microsoft /proc/version 2>/dev/null; then
                _HIVE_PLATFORM="wsl"
            else
                _HIVE_PLATFORM="linux"
            fi
            ;;
        Darwin*)
            _HIVE_PLATFORM="macos"
            ;;
        CYGWIN*|MINGW*|MSYS*)
            _HIVE_PLATFORM="windows"
            ;;
        *)
            _HIVE_PLATFORM="unknown"
            ;;
    esac
    
    echo "$_HIVE_PLATFORM"
}

# ============================================================================
# Date Functions
# ============================================================================

# Get current timestamp in ISO 8601 format
# Works on both Linux (date -Iseconds) and macOS
timestamp_iso() {
    if [ "$(detect_platform)" = "macos" ]; then
        date -u +"%Y-%m-%dT%H:%M:%SZ"
    else
        date -Iseconds 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ"
    fi
}

# Get current Unix timestamp in seconds
timestamp_epoch() {
    date +%s
}

# Get current timestamp with milliseconds (Linux only, falls back to seconds)
timestamp_ms() {
    date +%s%3N 2>/dev/null || echo "$(date +%s)000"
}

# ============================================================================
# File Operations
# ============================================================================

# Get file modification time as Unix timestamp
file_mtime() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        echo "0"
        return
    fi
    
    case "$(detect_platform)" in
        macos)
            stat -f %m "$file" 2>/dev/null || echo "0"
            ;;
        *)
            stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0"
            ;;
    esac
}

# In-place sed that works on both platforms
# Usage: sed_inplace 's/old/new/' file
sed_inplace() {
    local expression="$1"
    local file="$2"
    
    case "$(detect_platform)" in
        macos)
            sed -i '' "$expression" "$file"
            ;;
        *)
            sed -i "$expression" "$file"
            ;;
    esac
}

# ============================================================================
# Array Operations
# ============================================================================

# Read lines into array (bash 3 compatible)
# Usage: read_lines_to_array arrayname < file
# Note: In bash 3, use: IFS=$'\n' read -d '' -ra arrayname < file || true
read_lines_to_array() {
    local -n arr=$1
    arr=()
    while IFS= read -r line; do
        arr+=("$line")
    done
}

# ============================================================================
# Terminal Operations
# ============================================================================

# Check if terminal supports colors
supports_color() {
    if [ -t 1 ] && [ -n "$TERM" ] && [ "$TERM" != "dumb" ]; then
        return 0
    fi
    return 1
}

# Get terminal width (with fallback)
term_width() {
    tput cols 2>/dev/null || echo "80"
}

# Get terminal height (with fallback)
term_height() {
    tput lines 2>/dev/null || echo "24"
}

# ============================================================================
# Bash Version Check
# ============================================================================

# Check if bash version is sufficient
check_bash_version() {
    local required="${1:-4}"
    local current="${BASH_VERSINFO[0]}"
    
    if [ "$current" -lt "$required" ]; then
        return 1
    fi
    return 0
}

# ============================================================================
# Dependency Checks
# ============================================================================

# Check if a command exists
has_command() {
    command -v "$1" &>/dev/null
}

# Check platform-specific requirements
check_platform_requirements() {
    local platform=$(detect_platform)
    local issues=()
    
    # Bash version
    if ! check_bash_version 4; then
        if [ "$platform" = "macos" ]; then
            issues+=("Bash 4+ required. Install with: brew install bash")
        else
            issues+=("Bash 4+ required")
        fi
    fi
    
    # jq
    if ! has_command jq; then
        case "$platform" in
            macos)
                issues+=("jq required. Install with: brew install jq")
                ;;
            linux|wsl)
                issues+=("jq required. Install with: sudo apt install jq")
                ;;
            *)
                issues+=("jq required")
                ;;
        esac
    fi
    
    # Return issues
    if [ ${#issues[@]} -gt 0 ]; then
        printf '%s\n' "${issues[@]}"
        return 1
    fi
    
    return 0
}

# ============================================================================
# Path Handling
# ============================================================================

# Normalize path separators (for Windows compatibility)
normalize_path() {
    local path="$1"
    
    case "$(detect_platform)" in
        windows)
            # Convert forward slashes to backslashes for native Windows
            echo "$path" | sed 's|/|\\|g'
            ;;
        *)
            echo "$path"
            ;;
    esac
}

# Get home directory reliably
get_home() {
    echo "${HOME:-$(eval echo ~)}"
}
