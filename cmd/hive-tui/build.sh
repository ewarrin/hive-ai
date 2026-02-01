#!/bin/bash
# Build hive-tui
# Requires Go 1.21+

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building hive-tui..."
go build -o ../bin/hive-tui .

echo "✓ Built: $(dirname "$SCRIPT_DIR")/bin/hive-tui"
