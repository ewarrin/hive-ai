#!/usr/bin/env bash
# Hive Project Memory - Persistent knowledge across runs
#
# Stores accumulated project facts in .hive/memory.json
# Each run adds to the memory, so the 10th run is dramatically better than the 1st.

HIVE_DIR="${HIVE_DIR:-.hive}"
MEMORY_FILE="$HIVE_DIR/memory.json"

# ============================================================================
# Core Memory Functions
# ============================================================================

# Initialize memory if it doesn't exist
memory_init() {
    if [ ! -f "$MEMORY_FILE" ]; then
        mkdir -p "$HIVE_DIR"
        jq -n '{
            project: {
                name: null,
                type: null,
                language: null,
                framework: null,
                package_manager: null,
                build_command: null,
                test_command: null,
                deploy_target: null
            },
            tech_stack: [],
            conventions: [],
            gotchas: [],
            file_map: {},
            agent_history: [],
            run_count: 0,
            created_at: (now | todate),
            updated_at: (now | todate)
        }' > "$MEMORY_FILE"
    fi
}

# Read the full memory
memory_read() {
    if [ -f "$MEMORY_FILE" ]; then
        cat "$MEMORY_FILE"
    else
        memory_init
        cat "$MEMORY_FILE"
    fi
}

# Update memory with a jq expression
memory_update() {
    local jq_expr="$1"
    local current=$(memory_read)
    echo "$current" | jq "$jq_expr" | jq '.updated_at = (now | todate)' > "$MEMORY_FILE"
}

# ============================================================================
# Auto-detect Project Facts
# ============================================================================

# Scan project and populate memory with detected facts
memory_detect_project() {
    memory_init
    
    local mem=$(memory_read)
    
    # Detect project name
    local name=""
    if [ -f "package.json" ]; then
        name=$(jq -r '.name // empty' package.json 2>/dev/null)
    elif [ -f "Cargo.toml" ]; then
        name=$(grep '^name' Cargo.toml 2>/dev/null | head -1 | sed 's/.*= *"\(.*\)"/\1/')
    fi
    if [ -z "$name" ]; then
        name=$(basename "$(pwd)")
    fi
    
    # Detect framework
    local framework=""
    local project_type=""
    local language=""
    
    if [ -f "nuxt.config.ts" ] || [ -f "nuxt.config.js" ]; then
        framework="nuxt"
        project_type="web_app"
        language="typescript"
    elif [ -f "next.config.js" ] || [ -f "next.config.mjs" ]; then
        framework="next"
        project_type="web_app"
        language="typescript"
    elif [ -f "vite.config.ts" ] || [ -f "vite.config.js" ]; then
        framework="vite"
        project_type="web_app"
        language="typescript"
    elif [ -f "svelte.config.js" ]; then
        framework="svelte"
        project_type="web_app"
        language="typescript"
    elif [ -f "Cargo.toml" ]; then
        framework="rust"
        project_type="binary"
        language="rust"
    elif [ -f "go.mod" ]; then
        framework="go"
        project_type="binary"
        language="go"
    elif [ -f "requirements.txt" ] || [ -f "pyproject.toml" ]; then
        framework="python"
        project_type="application"
        language="python"
    fi
    
    # Detect package manager
    local pkg_manager=""
    if [ -f "pnpm-lock.yaml" ]; then
        pkg_manager="pnpm"
    elif [ -f "yarn.lock" ]; then
        pkg_manager="yarn"
    elif [ -f "bun.lockb" ]; then
        pkg_manager="bun"
    elif [ -f "package-lock.json" ]; then
        pkg_manager="npm"
    elif [ -f "Cargo.lock" ]; then
        pkg_manager="cargo"
    elif [ -f "go.sum" ]; then
        pkg_manager="go"
    fi
    
    # Detect build command
    local build_cmd=""
    if [ -f "package.json" ]; then
        build_cmd=$(jq -r '.scripts.build // empty' package.json 2>/dev/null)
        if [ -n "$build_cmd" ] && [ -n "$pkg_manager" ]; then
            build_cmd="$pkg_manager run build"
        fi
    elif [ -f "Cargo.toml" ]; then
        build_cmd="cargo build"
    elif [ -f "go.mod" ]; then
        build_cmd="go build ./..."
    fi
    
    # Detect test command
    local test_cmd=""
    if [ -f "package.json" ]; then
        test_cmd=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
        if [ -n "$test_cmd" ] && [ -n "$pkg_manager" ]; then
            test_cmd="$pkg_manager run test"
        fi
    elif [ -f "Cargo.toml" ]; then
        test_cmd="cargo test"
    elif [ -f "go.mod" ]; then
        test_cmd="go test ./..."
    fi
    
    # Detect deploy target
    local deploy_target=""
    if [ -f "wrangler.toml" ] || [ -f "wrangler.jsonc" ]; then
        deploy_target="cloudflare"
    elif [ -f "vercel.json" ]; then
        deploy_target="vercel"
    elif [ -f "netlify.toml" ]; then
        deploy_target="netlify"
    elif [ -f "fly.toml" ]; then
        deploy_target="fly.io"
    elif [ -f "Dockerfile" ]; then
        deploy_target="docker"
    fi
    
    # Detect tech stack
    local tech_stack="[]"
    if [ -f "package.json" ]; then
        local deps=$(jq -r '[.dependencies // {}, .devDependencies // {} | keys[]] | unique | .[]' package.json 2>/dev/null)
        
        # Pick important ones
        for dep in $deps; do
            case "$dep" in
                "@nuxt/ui"|"nuxt-ui"|"@nuxtjs/ui")
                    tech_stack=$(echo "$tech_stack" | jq '. += ["NuxtUI"]')
                    ;;
                "tailwindcss"|"@tailwindcss/"*)
                    tech_stack=$(echo "$tech_stack" | jq '. += ["Tailwind CSS"]')
                    ;;
                "prisma"|"@prisma/client")
                    tech_stack=$(echo "$tech_stack" | jq '. += ["Prisma"]')
                    ;;
                "drizzle-orm")
                    tech_stack=$(echo "$tech_stack" | jq '. += ["Drizzle"]')
                    ;;
                "vitest")
                    tech_stack=$(echo "$tech_stack" | jq '. += ["Vitest"]')
                    ;;
                "playwright"|"@playwright/test")
                    tech_stack=$(echo "$tech_stack" | jq '. += ["Playwright"]')
                    ;;
                "vue"|"vue-router")
                    tech_stack=$(echo "$tech_stack" | jq '. += ["Vue"]')
                    ;;
                "react"|"react-dom")
                    tech_stack=$(echo "$tech_stack" | jq '. += ["React"]')
                    ;;
                "typescript")
                    tech_stack=$(echo "$tech_stack" | jq '. += ["TypeScript"]')
                    ;;
                "eslint")
                    tech_stack=$(echo "$tech_stack" | jq '. += ["ESLint"]')
                    ;;
            esac
        done
        tech_stack=$(echo "$tech_stack" | jq 'unique')
    fi
    
    # Update memory with all detected info
    echo "$mem" | jq \
        --arg name "$name" \
        --arg type "$project_type" \
        --arg lang "$language" \
        --arg framework "$framework" \
        --arg pkg "$pkg_manager" \
        --arg build "$build_cmd" \
        --arg test "$test_cmd" \
        --arg deploy "$deploy_target" \
        --argjson tech "$tech_stack" \
        '
        .project.name = (if $name != "" then $name else .project.name end) |
        .project.type = (if $type != "" then $type else .project.type end) |
        .project.language = (if $lang != "" then $lang else .project.language end) |
        .project.framework = (if $framework != "" then $framework else .project.framework end) |
        .project.package_manager = (if $pkg != "" then $pkg else .project.package_manager end) |
        .project.build_command = (if $build != "" then $build else .project.build_command end) |
        .project.test_command = (if $test != "" then $test else .project.test_command end) |
        .project.deploy_target = (if $deploy != "" then $deploy else .project.deploy_target end) |
        .tech_stack = ((.tech_stack + $tech) | unique) |
        .updated_at = (now | todate)
        ' > "$MEMORY_FILE"
}

# ============================================================================
# Memory Accessors
# ============================================================================

memory_get_project() {
    memory_read | jq '.project'
}

memory_get_tech_stack() {
    memory_read | jq '.tech_stack'
}

memory_get_conventions() {
    memory_read | jq '.conventions'
}

memory_get_gotchas() {
    memory_read | jq '.gotchas'
}

memory_get_package_manager() {
    memory_read | jq -r '.project.package_manager // "npm"'
}

memory_get_build_command() {
    memory_read | jq -r '.project.build_command // ""'
}

memory_get_test_command() {
    memory_read | jq -r '.project.test_command // ""'
}

# ============================================================================
# Memory Mutators (called during/after runs)
# ============================================================================

memory_add_convention() {
    local convention="$1"
    local current=$(memory_read)
    echo "$current" | jq --arg c "$convention" \
        '.conventions += [$c] | .conventions |= unique | .updated_at = (now | todate)' \
        > "$MEMORY_FILE"
}

memory_add_gotcha() {
    local gotcha="$1"
    local current=$(memory_read)
    echo "$current" | jq --arg g "$gotcha" \
        '.gotchas += [$g] | .gotchas |= unique | .updated_at = (now | todate)' \
        > "$MEMORY_FILE"
}

memory_add_tech() {
    local tech="$1"
    local current=$(memory_read)
    echo "$current" | jq --arg t "$tech" \
        '.tech_stack += [$t] | .tech_stack |= unique | .updated_at = (now | todate)' \
        > "$MEMORY_FILE"
}

memory_set_file_purpose() {
    local file="$1"
    local purpose="$2"
    local current=$(memory_read)
    echo "$current" | jq --arg f "$file" --arg p "$purpose" \
        '.file_map[$f] = $p | .updated_at = (now | todate)' \
        > "$MEMORY_FILE"
}

# Record agent run stats
memory_record_agent_run() {
    local agent="$1"
    local duration="$2"
    local success="$3"
    local attempts="$4"
    
    local current=$(memory_read)
    local entry=$(jq -n \
        --arg agent "$agent" \
        --arg duration "$duration" \
        --argjson success "$success" \
        --argjson attempts "$attempts" \
        '{agent: $agent, duration: $duration, success: $success, attempts: $attempts, ts: (now | todate)}'
    )
    
    echo "$current" | jq --argjson e "$entry" \
        '.agent_history += [$e] | .agent_history = .agent_history[-50:] | .updated_at = (now | todate)' \
        > "$MEMORY_FILE"
}

# Increment run count
memory_increment_runs() {
    memory_update '.run_count += 1'
}

# ============================================================================
# Memory for Agent Prompts
# ============================================================================

# Generate a context block suitable for including in agent prompts
memory_context_for_agent() {
    local mem=$(memory_read)
    local run_count=$(echo "$mem" | jq '.run_count')
    
    if [ "$run_count" -eq 0 ] 2>/dev/null; then
        # First run - no memory context to share
        echo ""
        return
    fi
    
    local project=$(echo "$mem" | jq -r '.project | to_entries | map(select(.value != null and .value != "")) | from_entries')
    local tech=$(echo "$mem" | jq -r '.tech_stack')
    local conventions=$(echo "$mem" | jq -r '.conventions')
    local gotchas=$(echo "$mem" | jq -r '.gotchas')
    local file_map=$(echo "$mem" | jq -r '.file_map | to_entries | map(select(.value != null)) | from_entries')
    
    local context="## Project Memory (from previous Hive runs)

\`\`\`json
{
  \"project\": $project,
  \"tech_stack\": $tech,
  \"conventions\": $conventions,
  \"gotchas\": $gotchas,
  \"key_files\": $file_map,
  \"total_runs\": $run_count
}
\`\`\`

Use this context to make better decisions. Follow established conventions."
    
    echo "$context"
}

# Apply self-eval report data to memory
memory_learn_from_selfeval() {
    local report="$1"
    
    if [ -z "$report" ]; then
        return
    fi
    
    # Learn about files
    local files=$(echo "$report" | jq -c '.files_modified // []')
    if [ "$files" != "[]" ]; then
        echo "$files" | jq -r '.[]' | while read -r file; do
            if [ -n "$file" ]; then
                memory_set_file_purpose "$file" "modified"
            fi
        done
    fi
    
    # Learn about tech from decisions (handles both string[] and object[] formats)
    local decisions=$(echo "$report" | jq -c '.decisions // []')
    echo "$decisions" | jq -r '.[] | if type == "string" then . elif type == "object" then (.decision // empty) else empty end' 2>/dev/null | while read -r decision; do
        # Extract tech mentions from decisions
        case "$decision" in
            *pnpm*) memory_add_tech "pnpm" ;;
            *yarn*) memory_add_tech "yarn" ;;
            *bun*) memory_add_tech "bun" ;;
            *Tailwind*|*tailwind*) memory_add_tech "Tailwind CSS" ;;
            *NuxtUI*|*nuxt-ui*|*"nuxt ui"*) memory_add_tech "NuxtUI" ;;
            *Prisma*|*prisma*) memory_add_tech "Prisma" ;;
            *Cloudflare*|*cloudflare*) memory_add_convention "Deploy target: Cloudflare" ;;
            *Vercel*|*vercel*) memory_add_convention "Deploy target: Vercel" ;;
        esac
    done
}

# ============================================================================
# Challenge Pattern Memory
# ============================================================================

# Record a challenge for pattern learning
memory_record_challenge() {
    local from="$1" to="$2" issue="$3" resolution="$4"
    local category=$(memory_categorize_issue "$issue")

    local entry=$(jq -n \
        --arg from "$from" --arg to "$to" \
        --arg cat "$category" --arg res "$resolution" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{from:$from, to:$to, category:$cat, resolution:$res, timestamp:$ts}')

    memory_update --argjson entry "$entry" \
        '.challenge_history = ((.challenge_history // []) + [$entry])[-100:]'
}

# Categorize issue text into known categories
memory_categorize_issue() {
    local issue="$1"
    local lower=$(echo "$issue" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        *path*|*file*|*"not found"*|*"doesn't exist"*) echo "wrong_path" ;;
        *type*|*interface*|*undefined*|*null*) echo "type_error" ;;
        *import*|*module*|*dependency*) echo "dependency" ;;
        *design*|*architecture*|*pattern*) echo "architecture" ;;
        *missing*|*incomplete*|*unfinished*) echo "missing_code" ;;
        *bug*|*wrong*|*incorrect*) echo "implementation" ;;
        *) echo "other" ;;
    esac
}

# Get challenge stats for reporting
memory_get_challenge_stats() {
    memory_read | jq '
        .challenge_history // [] |
        {
            total: length,
            resolved: [.[] | select(.resolution=="resolved")] | length,
            by_pair: (group_by(.from + "->" + .to) | map({
                pair: .[0].from + " -> " + .[0].to,
                count: length
            }) | sort_by(-.count)[:5])
        }'
}

# Inject challenge context into agent prompt
# Shows past challenges against this agent so it can be more careful
memory_challenge_context_for() {
    local agent="$1"
    local history=$(memory_read | jq -r --arg a "$agent" '
        [(.challenge_history // [])[] | select(.to == $a)] |
        if length < 2 then empty else
            group_by(.category) | map({cat: .[0].category, n: length}) |
            sort_by(-.n)[:3][] | "- \(.cat): \(.n) times"
        end')

    [ -n "$history" ] && echo "
## Past Challenges Against Your Work
$history
Pay extra attention to these areas."
}
