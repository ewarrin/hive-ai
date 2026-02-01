#!/usr/bin/env bash
# Hive Codebase Index - Lightweight project map for agent context
#
# Builds a compact representation of the codebase that tells agents:
#   - What directories and files exist
#   - What each key file does (one-liner)
#   - What patterns/conventions are in use
#   - What types/interfaces are defined
#
# The index is stored at .hive/index.md and rebuilt at workflow start
# and after each agent that modifies files.
#
# Target budget: ~400-600 tokens. Enough to orient, not enough to bloat.

HIVE_DIR="${HIVE_DIR:-.hive}"
INDEX_FILE="$HIVE_DIR/index.md"

# ============================================================================
# Build Index
# ============================================================================

# Build the full codebase index from scratch
# Uses file system inspection only — no Claude calls needed
index_build() {
    mkdir -p "$HIVE_DIR"
    
    # Fast path: if index exists and is recent (< 5 min), skip rebuild
    if [ -f "$INDEX_FILE" ]; then
        local age=$(( $(date +%s) - $(stat -f %m "$INDEX_FILE" 2>/dev/null || stat -c %Y "$INDEX_FILE" 2>/dev/null || echo 0) ))
        if [ "$age" -lt 300 ]; then
            return 0
        fi
    fi
    
    local index=""
    
    # ── Directory tree (simplified, with timeout) ──
    index="## Codebase Index

### Structure
\`\`\`
$(timeout 5 bash -c 'index_build_tree_fast' 2>/dev/null || echo "Project files (index timed out)")
\`\`\`"
    
    # ── Key files (fast - just check if files exist) ──
    local key_files=$(index_find_key_files_fast)
    if [ -n "$key_files" ]; then
        index="$index

### Key Files
$key_files"
    fi
    
    # ── Patterns detected ──
    local patterns=$(index_detect_patterns)
    if [ -n "$patterns" ]; then
        index="$index

### Patterns
$patterns"
    fi
    
    echo "$index" > "$INDEX_FILE"
}

# Fast key files check - just existence, no parsing
index_find_key_files_fast() {
    local output=""
    
    for f in nuxt.config.ts next.config.js vite.config.ts svelte.config.js \
             package.json tsconfig.json Cargo.toml go.mod pyproject.toml \
             tailwind.config.js docker-compose.yml Dockerfile; do
        [ -f "$f" ] && output="$output
- \`$f\`"
    done
    
    echo "$output"
}

# Fast tree - just top-level directories with counts
index_build_tree_fast() {
    for dir in src app lib pages components server api utils types; do
        if [ -d "$dir" ]; then
            local count=$(find "$dir" -type f \( -name "*.ts" -o -name "*.js" -o -name "*.vue" -o -name "*.tsx" \) 2>/dev/null | head -100 | wc -l | tr -d ' ')
            echo "$dir/ ($count files)"
        fi
    done
}

# Rebuild only the parts affected by changed files
index_update() {
    # For now, full rebuild. It's fast enough (<1s on most projects).
    # Optimize later if needed with incremental updates.
    index_build
}

# ============================================================================
# Tree Builder
# ============================================================================

# Build a compact directory tree: dir/ (N files) - description
index_build_tree() {
    # Find all directories with source files, excluding noise
    local dirs=$(find . -type f \
        \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
           -o -name "*.vue" -o -name "*.svelte" -o -name "*.py" \
           -o -name "*.rs" -o -name "*.go" -o -name "*.rb" \) \
        -not -path "*/node_modules/*" \
        -not -path "*/.nuxt/*" \
        -not -path "*/.next/*" \
        -not -path "*/.svelte-kit/*" \
        -not -path "*/.angular/*" \
        -not -path "*/.output/*" \
        -not -path "*/dist/*" \
        -not -path "*/build/*" \
        -not -path "*/.git/*" \
        -not -path "*/.hive/*" \
        -not -path "*/target/*" \
        -not -path "*/__pycache__/*" \
        -not -path "*/venv/*" \
        -not -path "*/.venv/*" \
        -not -path "*/vendor/*" \
        -not -path "*/.tox/*" \
        -not -path "*/.mypy_cache/*" \
        -not -path "*/site-packages/*" \
        -not -path "*/.astro/*" \
        2>/dev/null \
        | sed 's|/[^/]*$||' \
        | sort -u)
    
    # Count files per directory and format
    echo "$dirs" | while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        local count=$(find "$dir" -maxdepth 1 -type f \
            \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \
               -o -name "*.vue" -o -name "*.svelte" -o -name "*.py" \
               -o -name "*.rs" -o -name "*.go" -o -name "*.rb" \) \
            2>/dev/null | wc -l)
        
        local clean_dir="${dir#./}"
        [ "$count" -gt 0 ] 2>/dev/null && echo "$clean_dir/ ($count files)"
    done
}

# ============================================================================
# Key File Detection
# ============================================================================

# Find important files and generate one-line descriptions
index_find_key_files() {
    local output=""
    
    # Config files
    for f in nuxt.config.ts nuxt.config.js next.config.ts next.config.js next.config.mjs \
             vite.config.ts vite.config.js svelte.config.js svelte.config.ts \
             angular.json astro.config.mjs remix.config.js \
             Cargo.toml go.mod pyproject.toml setup.py setup.cfg \
             tailwind.config.ts tailwind.config.js \
             vitest.config.ts vitest.config.js jest.config.ts jest.config.js \
             playwright.config.ts playwright.config.js \
             tsconfig.json webpack.config.js esbuild.config.js \
             docker-compose.yml Dockerfile Makefile; do
        if [ -f "$f" ]; then
            output="$output
- \`$f\` — $(index_one_liner "$f")"
        fi
    done
    
    # Entry points
    for f in src/main.ts src/main.js src/main.tsx src/index.ts src/index.js src/index.tsx \
             app.vue src/App.vue src/App.tsx app/app.vue app/app.tsx \
             pages/index.vue pages/index.tsx src/routes/+page.svelte \
             src/lib.rs src/main.rs main.go cmd/main.go \
             app.py main.py manage.py wsgi.py asgi.py \
             cmd/server/main.go internal/app.go; do
        if [ -f "$f" ]; then
            output="$output
- \`$f\` — $(index_one_liner "$f")"
        fi
    done
    
    # Layout / root components (framework-agnostic check)
    for f in app/layouts/default.vue src/layouts/default.vue layouts/default.vue \
             src/app/app.component.ts src/app/layout.tsx app/layout.tsx \
             src/routes/+layout.svelte templates/base.html; do
        if [ -f "$f" ]; then
            output="$output
- \`$f\` — $(index_one_liner "$f")"
        fi
    done
    
    # API / server routes (generic detection)
    local api_dir=""
    for d in server/api src/server/api api src/api routes src/routes/api app/api; do
        if [ -d "$d" ]; then
            api_dir="$d"
            break
        fi
    done
    
    if [ -n "$api_dir" ]; then
        local api_count=$(find "$api_dir" -type f \
            \( -name "*.ts" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.rs" \) \
            2>/dev/null | wc -l)
        [ "$api_count" -gt 0 ] 2>/dev/null && output="$output
- \`$api_dir/\` — $api_count API routes"
    fi
    
    echo "$output"
}

# Extract a one-line description from a file
# Looks for: comments at top, main export, or falls back to file type
index_one_liner() {
    local file="$1"
    
    # Try to find a description comment in the first 5 lines
    local comment=$(head -5 "$file" 2>/dev/null \
        | grep -E '^\s*(//|#|/\*|\*)\s+\w' \
        | head -1 \
        | sed 's|^\s*[/#*]*\s*||' \
        | cut -c1-80)
    
    if [ -n "$comment" ]; then
        echo "$comment"
        return
    fi
    
    # For config files, extract key settings
    case "$file" in
        *nuxt.config*)
            local modules=$(grep -oE 'modules:\s*\[[^]]+' "$file" 2>/dev/null \
                | sed 's/modules:\s*\[//' | tr -d "'" | tr -d '"' | xargs)
            [ -n "$modules" ] && echo "modules: $modules" && return
            echo "Nuxt configuration" && return
            ;;
        *next.config*)
            echo "Next.js configuration" && return
            ;;
        *vite.config*)
            echo "Vite build configuration" && return
            ;;
        *svelte.config*)
            echo "SvelteKit configuration" && return
            ;;
        *angular.json)
            echo "Angular workspace configuration" && return
            ;;
        *tailwind.config*)
            echo "Tailwind CSS configuration" && return
            ;;
        *vitest.config*|*jest.config*)
            echo "test runner configuration" && return
            ;;
        *playwright.config*)
            echo "E2E test configuration" && return
            ;;
        *tsconfig.json)
            echo "TypeScript compiler configuration" && return
            ;;
        *Cargo.toml)
            local crate_name=$(grep -m1 -oE 'name\s*=\s*"[^"]+"' "$file" 2>/dev/null \
                | sed 's/name\s*=\s*"//' | sed 's/"//')
            [ -n "$crate_name" ] && echo "Rust crate: $crate_name" && return
            echo "Rust project configuration" && return
            ;;
        *go.mod)
            local mod_path=$(head -1 "$file" 2>/dev/null | awk '{print $2}')
            [ -n "$mod_path" ] && echo "Go module: $mod_path" && return
            ;;
        *pyproject.toml)
            local proj_name=$(grep -m1 -oE 'name\s*=\s*"[^"]+"' "$file" 2>/dev/null \
                | sed 's/name\s*=\s*"//' | sed 's/"//')
            [ -n "$proj_name" ] && echo "Python project: $proj_name" && return
            echo "Python project configuration" && return
            ;;
        *docker-compose*)
            local svc_count=$(grep -cE '^\s+\w+:' "$file" 2>/dev/null || echo "?")
            echo "$svc_count services" && return
            ;;
        *Dockerfile)
            local base=$(grep -m1 -oE '^FROM \S+' "$file" 2>/dev/null | sed 's/FROM //')
            [ -n "$base" ] && echo "base: $base" && return
            ;;
        *Makefile)
            echo "build automation" && return
            ;;
    esac
    
    # Fallback: first export name
    local first_export=$(grep -m1 -oE 'export (default |const |function |class )\w+' "$file" 2>/dev/null | awk '{print $NF}')
    if [ -n "$first_export" ]; then
        echo "exports $first_export"
        return
    fi
    
    echo "$(basename "$file")"
}

# ============================================================================
# Export / Type Detection
# ============================================================================

# Find exported types, interfaces, composables, and utilities
# Detects patterns across JS/TS, Python, Rust, Go, Ruby
index_find_exports() {
    local output=""
    
    # ── JS/TS: Composables & Hooks (use*.ts / use*.js) ──
    local composables=$(find . \( -name "use*.ts" -o -name "use*.js" -o -name "use*.tsx" -o -name "use*.jsx" \) \
        -not -path "*/node_modules/*" \
        -not -path "*/.nuxt/*" -not -path "*/.next/*" \
        -not -path "*/dist/*" -not -path "*/build/*" \
        2>/dev/null | sort)
    
    if [ -n "$composables" ]; then
        local comp_list=$(echo "$composables" | while read -r f; do
            basename "$f" | sed 's/\.\(ts\|js\|tsx\|jsx\)$//'
        done | sort -u | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        output="$output
- Composables/Hooks: $comp_list"
    fi
    
    # ── JS/TS: Types & Interfaces ──
    local type_files=$(find . \( -name "types.ts" -o -name "*.types.ts" -o -name "*.d.ts" -o -path "*/types/*.ts" \) \
        -not -path "*/node_modules/*" \
        -not -path "*/.nuxt/*" -not -path "*/.next/*" \
        -not -path "*/dist/*" \
        2>/dev/null | head -10)
    
    if [ -n "$type_files" ]; then
        local types=$(echo "$type_files" | while read -r f; do
            grep -oE 'export (type|interface) \w+' "$f" 2>/dev/null | awk '{print $NF}'
        done | sort -u | head -15 | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        [ -n "$types" ] && output="$output
- Types: $types"
    fi
    
    # ── JS/TS: Utilities ──
    local util_files=$(find . \( -path "*/utils/*" -o -path "*/helpers/*" -o -path "*/lib/*" \) \
        \( -name "*.ts" -o -name "*.js" \) \
        -not -path "*/node_modules/*" \
        -not -path "*/.nuxt/*" -not -path "*/.next/*" \
        -not -path "*/dist/*" -not -path "*/.hive/*" \
        2>/dev/null | head -10)
    
    if [ -n "$util_files" ]; then
        local utils=$(echo "$util_files" | while read -r f; do
            grep -oE 'export (const|function) \w+' "$f" 2>/dev/null | awk '{print $NF}'
        done | sort -u | head -15 | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        [ -n "$utils" ] && output="$output
- Utilities: $utils"
    fi
    
    # ── JS/TS: State management (Pinia, Vuex, Redux, Zustand, MobX) ──
    local stores=$(find . \( -name "*store*" -o -name "*Store*" -o -path "*/stores/*" \
        -o -name "*slice*" -o -name "*Slice*" -o -path "*/slices/*" \) \
        \( -name "*.ts" -o -name "*.js" \) \
        -not -path "*/node_modules/*" -not -path "*/dist/*" \
        2>/dev/null | head -10)
    
    if [ -n "$stores" ]; then
        local store_names=$(echo "$stores" | while read -r f; do
            basename "$f" | sed 's/\.\(ts\|js\)$//'
        done | sort -u | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        output="$output
- Stores: $store_names"
    fi
    
    # ── Python: Modules and classes ──
    local py_files=$(find . -name "*.py" \
        -not -path "*/__pycache__/*" -not -path "*/venv/*" \
        -not -path "*/.venv/*" -not -path "*/site-packages/*" \
        2>/dev/null | head -30)
    
    if [ -n "$py_files" ]; then
        local py_classes=$(echo "$py_files" | while read -r f; do
            grep -oE '^class \w+' "$f" 2>/dev/null | awk '{print $2}' | sed 's/[:(].*//'
        done | sort -u | head -15 | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        [ -n "$py_classes" ] && output="$output
- Python classes: $py_classes"
        
        # Models (Django, SQLAlchemy, Pydantic)
        local py_models=$(echo "$py_files" | while read -r f; do
            grep -oE 'class \w+\((Model|Base|BaseModel|Schema)' "$f" 2>/dev/null \
                | sed 's/class //' | sed 's/(.*//'
        done | sort -u | head -10 | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        [ -n "$py_models" ] && output="$output
- Models: $py_models"
    fi
    
    # ── Rust: Public modules and structs ──
    local rs_files=$(find . -name "*.rs" \
        -not -path "*/target/*" \
        2>/dev/null | head -30)
    
    if [ -n "$rs_files" ]; then
        local rs_pub=$(echo "$rs_files" | while read -r f; do
            grep -oE 'pub (struct|enum|trait|fn) \w+' "$f" 2>/dev/null | awk '{print $NF}'
        done | sort -u | head -15 | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        [ -n "$rs_pub" ] && output="$output
- Rust public API: $rs_pub"
        
        # Mod declarations
        local rs_mods=$(grep -rlE '^pub mod \w+' --include="*.rs" . 2>/dev/null \
            | grep -v target | head -5 | while read -r f; do
            grep -oE '^pub mod \w+' "$f" | awk '{print $NF}'
        done | sort -u | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        [ -n "$rs_mods" ] && output="$output
- Rust modules: $rs_mods"
    fi
    
    # ── Go: Packages and exported funcs ──
    local go_files=$(find . -name "*.go" \
        -not -path "*/vendor/*" \
        2>/dev/null | head -30)
    
    if [ -n "$go_files" ]; then
        # Go packages
        local go_pkgs=$(echo "$go_files" | while read -r f; do
            head -5 "$f" | grep -oE '^package \w+' | awk '{print $2}'
        done | sort -u | grep -v main | head -10 | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        [ -n "$go_pkgs" ] && output="$output
- Go packages: $go_pkgs"
        
        # Exported functions (capitalized)
        local go_funcs=$(echo "$go_files" | while read -r f; do
            grep -oE '^func [A-Z]\w+' "$f" | awk '{print $2}' | sed 's/(.*//';
        done | sort -u | head -15 | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
        [ -n "$go_funcs" ] && output="$output
- Go exports: $go_funcs"
    fi
    
    echo "$output"
}

# ============================================================================
# Pattern Detection
# ============================================================================

# Detect coding patterns and conventions from the codebase
# Only reports what it actually finds — no framework assumptions
index_detect_patterns() {
    local output=""
    
    # ── Language detection ──
    local ts_count=$(find . \( -name "*.ts" -o -name "*.tsx" \) -not -path "*/node_modules/*" -not -path "*/dist/*" -not -path "*/.nuxt/*" -not -path "*/.next/*" 2>/dev/null | wc -l)
    local js_count=$(find . \( -name "*.js" -o -name "*.jsx" \) -not -path "*/node_modules/*" -not -path "*/dist/*" 2>/dev/null | wc -l)
    local py_count=$(find . -name "*.py" -not -path "*/venv/*" -not -path "*/.venv/*" -not -path "*/__pycache__/*" 2>/dev/null | wc -l)
    local rs_count=$(find . -name "*.rs" -not -path "*/target/*" 2>/dev/null | wc -l)
    local go_count=$(find . -name "*.go" -not -path "*/vendor/*" 2>/dev/null | wc -l)
    local vue_count=$(find . -name "*.vue" -not -path "*/node_modules/*" -not -path "*/.nuxt/*" 2>/dev/null | wc -l)
    local svelte_count=$(find . -name "*.svelte" -not -path "*/node_modules/*" 2>/dev/null | wc -l)
    
    [ "$ts_count" -gt 0 ] 2>/dev/null && output="$output
- TypeScript ($ts_count files)"
    [ "$vue_count" -gt 0 ] 2>/dev/null && output="$output
- Vue ($vue_count files)"
    [ "$svelte_count" -gt 0 ] 2>/dev/null && output="$output
- Svelte ($svelte_count files)"
    [ "$py_count" -gt 0 ] 2>/dev/null && output="$output
- Python ($py_count files)"
    [ "$rs_count" -gt 0 ] 2>/dev/null && output="$output
- Rust ($rs_count files)"
    [ "$go_count" -gt 0 ] 2>/dev/null && output="$output
- Go ($go_count files)"
    
    # ── Vue: script style ──
    if [ "$vue_count" -gt 0 ] 2>/dev/null; then
        local setup_count=$(grep -rl '<script setup' --include="*.vue" . 2>/dev/null \
            | grep -v node_modules | wc -l)
        if [ "$setup_count" -gt 0 ] 2>/dev/null; then
            output="$output
- Vue \`<script setup>\` style"
        fi
    fi
    
    # ── CSS strategy ──
    local tailwind_usage=$(grep -rl 'class="[^"]*\b\(flex\|grid\|p-\|m-\|text-\|bg-\)' \
        --include="*.vue" --include="*.tsx" --include="*.jsx" --include="*.html" --include="*.svelte" \
        . 2>/dev/null | grep -v node_modules | wc -l)
    [ "$tailwind_usage" -gt 3 ] 2>/dev/null && output="$output
- Tailwind CSS"
    
    # ── Testing ──
    local test_files=$(find . \( -name "*.test.ts" -o -name "*.spec.ts" \
        -o -name "*.test.js" -o -name "*.spec.js" \
        -o -name "*.test.tsx" -o -name "*.spec.tsx" \
        -o -name "test_*.py" -o -name "*_test.py" \
        -o -name "*_test.go" -o -name "*_test.rs" \) \
        -not -path "*/node_modules/*" -not -path "*/target/*" 2>/dev/null | wc -l)
    [ "$test_files" -gt 0 ] 2>/dev/null && output="$output
- $test_files test files"
    
    # Test location
    local colocated=$(find . \( -name "*.test.*" -o -name "*.spec.*" -o -name "*_test.*" -o -name "test_*" \) \
        -not -path "*/node_modules/*" -not -path "*/tests/*" -not -path "*/test/*" -not -path "*/__tests__/*" \
        -not -path "*/target/*" 2>/dev/null | wc -l)
    local separated=$(find . \( -path "*/tests/*" -o -path "*/test/*" -o -path "*/__tests__/*" \) \
        -not -path "*/node_modules/*" -type f 2>/dev/null | wc -l)
    
    if [ "$colocated" -gt "$separated" ] 2>/dev/null && [ "$colocated" -gt 0 ] 2>/dev/null; then
        output="$output
- Tests colocated with source"
    elif [ "$separated" -gt 0 ] 2>/dev/null; then
        output="$output
- Tests in separate directory"
    fi
    
    # ── Framework-specific notes (only if detected) ──
    if [ -f "nuxt.config.ts" ] || [ -f "nuxt.config.js" ]; then
        output="$output
- Nuxt auto-imports (ref, computed, etc. available globally)"
    fi
    
    if [ -f "angular.json" ]; then
        local standalone=$(grep -rl 'standalone: true' --include="*.ts" . 2>/dev/null | grep -v node_modules | wc -l)
        [ "$standalone" -gt 0 ] 2>/dev/null && output="$output
- Angular standalone components ($standalone files)"
    fi
    
    # ── Python: Framework detection ──
    if [ "$py_count" -gt 0 ] 2>/dev/null; then
        [ -f "manage.py" ] && output="$output
- Django project"
        [ -f "app.py" ] || [ -f "wsgi.py" ] && grep -q "Flask\|flask" app.py 2>/dev/null && output="$output
- Flask project"
        [ -f "main.py" ] && grep -q "FastAPI\|fastapi" main.py 2>/dev/null && output="$output
- FastAPI project"
    fi
    
    # ── Rust: Workspace detection ──
    if [ "$rs_count" -gt 0 ] 2>/dev/null; then
        grep -q '\[workspace\]' Cargo.toml 2>/dev/null && output="$output
- Rust workspace (multi-crate)"
    fi
    
    echo "$output"
}

# ============================================================================
# Context Injection
# ============================================================================

# Return the index as markdown for agent context injection
# Returns empty string if no index exists
index_context_for_agent() {
    if [ ! -f "$INDEX_FILE" ]; then
        return
    fi
    
    cat "$INDEX_FILE"
}
