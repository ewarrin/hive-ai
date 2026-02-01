#!/usr/bin/env bash
# Hive Migration Tools - Database migration detection and validation
#
# Supports: Prisma, Drizzle, Alembic, Knex, TypeORM, Sequelize, Rails

HIVE_DIR="${HIVE_DIR:-.hive}"

# ============================================================================
# Migration Tool Detection
# ============================================================================

# Detect which migration tool is in use
# Returns: prisma, drizzle, alembic, knex, typeorm, sequelize, rails, unknown
migration_detect_tool() {
    local project_dir="${1:-.}"

    # Prisma
    if [ -f "$project_dir/prisma/schema.prisma" ]; then
        echo "prisma"
        return 0
    fi

    # Drizzle
    if [ -f "$project_dir/drizzle.config.ts" ] || [ -f "$project_dir/drizzle.config.js" ] || [ -d "$project_dir/drizzle" ]; then
        echo "drizzle"
        return 0
    fi

    # Alembic (Python)
    if [ -f "$project_dir/alembic.ini" ] || [ -d "$project_dir/alembic" ]; then
        echo "alembic"
        return 0
    fi

    # Knex
    if [ -f "$project_dir/knexfile.js" ] || [ -f "$project_dir/knexfile.ts" ]; then
        echo "knex"
        return 0
    fi

    # TypeORM
    if [ -f "$project_dir/ormconfig.json" ] || [ -f "$project_dir/ormconfig.js" ] || \
       grep -q "typeorm" "$project_dir/package.json" 2>/dev/null; then
        echo "typeorm"
        return 0
    fi

    # Sequelize
    if [ -f "$project_dir/.sequelizerc" ] || [ -d "$project_dir/migrations" ] && \
       grep -q "sequelize" "$project_dir/package.json" 2>/dev/null; then
        echo "sequelize"
        return 0
    fi

    # Rails
    if [ -d "$project_dir/db/migrate" ] && [ -f "$project_dir/Gemfile" ]; then
        echo "rails"
        return 0
    fi

    echo "unknown"
    return 1
}

# Detect database type from configuration
# Returns: postgresql, mysql, sqlite, mongodb, unknown
migration_detect_db_type() {
    local project_dir="${1:-.}"
    local tool=$(migration_detect_tool "$project_dir")

    case "$tool" in
        prisma)
            local provider=$(grep -oP 'provider\s*=\s*"\K[^"]+' "$project_dir/prisma/schema.prisma" 2>/dev/null | head -1)
            case "$provider" in
                postgresql) echo "postgresql" ;;
                mysql) echo "mysql" ;;
                sqlite) echo "sqlite" ;;
                mongodb) echo "mongodb" ;;
                *) echo "unknown" ;;
            esac
            ;;
        alembic)
            # Check alembic.ini for sqlalchemy.url
            local url=$(grep "sqlalchemy.url" "$project_dir/alembic.ini" 2>/dev/null)
            if echo "$url" | grep -q "postgresql"; then
                echo "postgresql"
            elif echo "$url" | grep -q "mysql"; then
                echo "mysql"
            elif echo "$url" | grep -q "sqlite"; then
                echo "sqlite"
            else
                echo "unknown"
            fi
            ;;
        knex|typeorm|sequelize)
            # Check for DATABASE_URL or config files
            if [ -n "$DATABASE_URL" ]; then
                if echo "$DATABASE_URL" | grep -q "postgres"; then
                    echo "postgresql"
                elif echo "$DATABASE_URL" | grep -q "mysql"; then
                    echo "mysql"
                elif echo "$DATABASE_URL" | grep -q "sqlite"; then
                    echo "sqlite"
                else
                    echo "unknown"
                fi
            else
                echo "unknown"
            fi
            ;;
        rails)
            # Check database.yml
            if [ -f "$project_dir/config/database.yml" ]; then
                if grep -q "postgres" "$project_dir/config/database.yml"; then
                    echo "postgresql"
                elif grep -q "mysql" "$project_dir/config/database.yml"; then
                    echo "mysql"
                elif grep -q "sqlite" "$project_dir/config/database.yml"; then
                    echo "sqlite"
                else
                    echo "unknown"
                fi
            else
                echo "unknown"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# ============================================================================
# Migration Validation
# ============================================================================

# Validate migration file syntax
# Returns 0 if valid, 1 if invalid with error message
migration_validate_syntax() {
    local tool="$1"
    local migration_file="$2"

    if [ ! -f "$migration_file" ]; then
        echo "Migration file not found: $migration_file"
        return 1
    fi

    case "$tool" in
        prisma)
            # Check SQL syntax (basic validation)
            if grep -qiE "syntax error|unexpected" "$migration_file" 2>/dev/null; then
                echo "SQL syntax error detected"
                return 1
            fi
            # Check for common issues
            if grep -qiE "drop table.*cascade" "$migration_file" 2>/dev/null; then
                echo "Warning: CASCADE DROP detected - potential data loss"
            fi
            ;;
        drizzle)
            # Similar SQL validation
            if [ "${migration_file##*.}" = "sql" ]; then
                # Basic SQL check
                if grep -qiE "^\s*$" "$migration_file" && [ ! -s "$migration_file" ]; then
                    echo "Empty migration file"
                    return 1
                fi
            fi
            ;;
        alembic)
            # Python syntax check
            python3 -m py_compile "$migration_file" 2>&1
            if [ $? -ne 0 ]; then
                echo "Python syntax error in migration"
                return 1
            fi
            ;;
        *)
            # Generic file check
            if [ ! -s "$migration_file" ]; then
                echo "Empty migration file"
                return 1
            fi
            ;;
    esac

    echo "valid"
    return 0
}

# Check for destructive operations in migration
migration_check_destructive() {
    local migration_file="$1"

    local destructive_ops="[]"

    # Check for DROP operations
    if grep -qiE "\bdrop\s+(table|column|index|constraint)" "$migration_file" 2>/dev/null; then
        destructive_ops=$(echo "$destructive_ops" | jq '. += ["DROP operation found"]')
    fi

    # Check for TRUNCATE
    if grep -qiE "\btruncate\b" "$migration_file" 2>/dev/null; then
        destructive_ops=$(echo "$destructive_ops" | jq '. += ["TRUNCATE operation found"]')
    fi

    # Check for DELETE without WHERE
    if grep -qiE "\bdelete\s+from\b" "$migration_file" 2>/dev/null; then
        if ! grep -qiE "\bdelete\s+from\s+\S+\s+where\b" "$migration_file" 2>/dev/null; then
            destructive_ops=$(echo "$destructive_ops" | jq '. += ["DELETE without WHERE clause"]')
        fi
    fi

    # Check for type changes
    if grep -qiE "\balter\s+.*\s+type\b" "$migration_file" 2>/dev/null; then
        destructive_ops=$(echo "$destructive_ops" | jq '. += ["Column type change"]')
    fi

    echo "$destructive_ops"
}

# ============================================================================
# Rollback Generation
# ============================================================================

# Generate a basic rollback script from an up migration
# This is a helper - agents should verify and customize
migration_generate_rollback() {
    local tool="$1"
    local up_migration="$2"

    case "$tool" in
        prisma|drizzle)
            # Parse CREATE TABLE statements and generate DROP
            local tables=$(grep -oiE "create\s+table\s+\S+" "$up_migration" 2>/dev/null | awk '{print $3}' | tr -d '(')
            local rollback=""

            for table in $tables; do
                rollback="${rollback}DROP TABLE IF EXISTS ${table};\n"
            done

            # Parse CREATE INDEX and generate DROP INDEX
            local indexes=$(grep -oiE "create\s+index\s+\S+" "$up_migration" 2>/dev/null | awk '{print $3}')
            for idx in $indexes; do
                rollback="${rollback}DROP INDEX IF EXISTS ${idx};\n"
            done

            echo -e "$rollback"
            ;;
        alembic)
            echo "# Auto-generated rollback - verify before use"
            echo "def downgrade():"
            echo "    # TODO: Implement rollback"
            echo "    pass"
            ;;
        *)
            echo "-- Auto-generated rollback - verify before use"
            echo "-- TODO: Implement rollback operations"
            ;;
    esac
}

# ============================================================================
# Migration Info
# ============================================================================

# Get migration history (list of applied migrations)
migration_get_history() {
    local tool="$1"
    local project_dir="${2:-.}"

    case "$tool" in
        prisma)
            if [ -d "$project_dir/prisma/migrations" ]; then
                ls -1 "$project_dir/prisma/migrations" 2>/dev/null | grep -v "migration_lock.toml" | sort
            fi
            ;;
        drizzle)
            if [ -d "$project_dir/drizzle/migrations" ]; then
                ls -1 "$project_dir/drizzle/migrations" 2>/dev/null | sort
            fi
            ;;
        alembic)
            if [ -d "$project_dir/alembic/versions" ]; then
                ls -1 "$project_dir/alembic/versions" 2>/dev/null | grep "\.py$" | sort
            fi
            ;;
        rails)
            if [ -d "$project_dir/db/migrate" ]; then
                ls -1 "$project_dir/db/migrate" 2>/dev/null | sort
            fi
            ;;
        *)
            if [ -d "$project_dir/migrations" ]; then
                ls -1 "$project_dir/migrations" 2>/dev/null | sort
            fi
            ;;
    esac
}

# Get schema file path for the tool
migration_get_schema_path() {
    local tool="$1"
    local project_dir="${2:-.}"

    case "$tool" in
        prisma)
            echo "$project_dir/prisma/schema.prisma"
            ;;
        drizzle)
            # Drizzle can have schema in various locations
            for f in "$project_dir/drizzle/schema.ts" "$project_dir/src/db/schema.ts" "$project_dir/schema.ts"; do
                if [ -f "$f" ]; then
                    echo "$f"
                    return 0
                fi
            done
            ;;
        alembic)
            echo "$project_dir/alembic.ini"
            ;;
        rails)
            echo "$project_dir/db/schema.rb"
            ;;
        *)
            echo ""
            ;;
    esac
}

# ============================================================================
# Migration Summary
# ============================================================================

# Get a summary of migration environment
migration_summary() {
    local project_dir="${1:-.}"

    local tool=$(migration_detect_tool "$project_dir")
    local db_type=$(migration_detect_db_type "$project_dir")
    local schema_path=$(migration_get_schema_path "$tool" "$project_dir")
    local migration_count=$(migration_get_history "$tool" "$project_dir" | wc -l | tr -d ' ')

    jq -n \
        --arg tool "$tool" \
        --arg db_type "$db_type" \
        --arg schema_path "$schema_path" \
        --argjson migration_count "$migration_count" \
        '{
            tool: $tool,
            db_type: $db_type,
            schema_path: $schema_path,
            migration_count: $migration_count,
            detected: ($tool != "unknown")
        }'
}
