#!/usr/bin/env bash
# Hive Testing Orchestration
#
# Functions for detecting, bootstrapping, and running tests across multiple tiers:
# - Unit tests (Vitest/Jest)
# - Integration tests (Vitest + Testing Library)
# - E2E tests (Playwright with browser)

HIVE_DIR="${HIVE_DIR:-.hive}"
HIVE_ROOT="${HIVE_ROOT:-$HOME/.hive}"

# ============================================================================
# Test Infrastructure Detection
# ============================================================================

# Detect what test infrastructure exists in the project
# Returns JSON: {vitest: bool, playwright: bool, jest: bool, cypress: bool}
testing_detect_setup() {
    local has_vitest=false
    local has_playwright=false
    local has_jest=false
    local has_cypress=false
    local has_unit_tests=false
    local has_e2e_tests=false
    local has_integration_tests=false

    # Check config files
    [ -f "vitest.config.ts" ] || [ -f "vitest.config.js" ] || [ -f "vitest.config.mts" ] && has_vitest=true
    [ -f "playwright.config.ts" ] || [ -f "playwright.config.js" ] && has_playwright=true
    [ -f "jest.config.ts" ] || [ -f "jest.config.js" ] || [ -f "jest.config.json" ] && has_jest=true
    [ -f "cypress.config.ts" ] || [ -f "cypress.config.js" ] && has_cypress=true

    # Check package.json for dependencies
    if [ -f "package.json" ]; then
        grep -q '"vitest"' package.json 2>/dev/null && has_vitest=true
        grep -q '"@playwright/test"' package.json 2>/dev/null && has_playwright=true
        grep -q '"jest"' package.json 2>/dev/null && has_jest=true
        grep -q '"cypress"' package.json 2>/dev/null && has_cypress=true
    fi

    # Check for test directories
    [ -d "tests/unit" ] || [ -d "test/unit" ] || [ -d "__tests__" ] && has_unit_tests=true
    [ -d "tests/e2e" ] || [ -d "test/e2e" ] || [ -d "e2e" ] && has_e2e_tests=true
    [ -d "tests/integration" ] || [ -d "test/integration" ] && has_integration_tests=true

    # Check for test files
    if ! $has_unit_tests; then
        find . -maxdepth 4 -name "*.test.ts" -o -name "*.test.js" -o -name "*.spec.ts" 2>/dev/null | grep -v node_modules | grep -v e2e | head -1 | grep -q . && has_unit_tests=true
    fi
    if ! $has_e2e_tests; then
        find . -maxdepth 4 -path "*/e2e/*" -name "*.spec.ts" 2>/dev/null | head -1 | grep -q . && has_e2e_tests=true
    fi

    jq -cn \
        --argjson vitest "$has_vitest" \
        --argjson playwright "$has_playwright" \
        --argjson jest "$has_jest" \
        --argjson cypress "$has_cypress" \
        --argjson unit_tests "$has_unit_tests" \
        --argjson e2e_tests "$has_e2e_tests" \
        --argjson integration_tests "$has_integration_tests" \
        '{
            vitest: $vitest,
            playwright: $playwright,
            jest: $jest,
            cypress: $cypress,
            has_unit_tests: $unit_tests,
            has_e2e_tests: $e2e_tests,
            has_integration_tests: $integration_tests
        }'
}

# Check if any test framework is installed
testing_has_framework() {
    local setup=$(testing_detect_setup)
    local has_any=$(echo "$setup" | jq -r '.vitest or .playwright or .jest or .cypress')
    [ "$has_any" = "true" ]
}

# Get the unit test framework (vitest preferred)
testing_get_unit_framework() {
    local setup=$(testing_detect_setup)
    if [ "$(echo "$setup" | jq -r '.vitest')" = "true" ]; then
        echo "vitest"
    elif [ "$(echo "$setup" | jq -r '.jest')" = "true" ]; then
        echo "jest"
    else
        echo ""
    fi
}

# Get the e2e test framework (playwright preferred)
testing_get_e2e_framework() {
    local setup=$(testing_detect_setup)
    if [ "$(echo "$setup" | jq -r '.playwright')" = "true" ]; then
        echo "playwright"
    elif [ "$(echo "$setup" | jq -r '.cypress')" = "true" ]; then
        echo "cypress"
    else
        echo ""
    fi
}

# ============================================================================
# Playwright Bootstrap
# ============================================================================

# Bootstrap Playwright with browser support
# Creates config file and installs chromium browser
testing_bootstrap_playwright() {
    local base_url="${1:-http://localhost:3000}"
    local dev_command="${2:-npm run dev}"

    echo "Installing Playwright..."
    npm install -D @playwright/test

    echo "Installing Chromium browser..."
    npx playwright install chromium

    echo "Creating playwright.config.ts..."
    cat > playwright.config.ts << EOF
import { defineConfig, devices } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [['html'], ['list']],
  use: {
    baseURL: '${base_url}',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'on-first-retry',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
  webServer: {
    command: '${dev_command}',
    url: '${base_url}',
    reuseExistingServer: !process.env.CI,
    timeout: 120 * 1000,
  },
});
EOF

    # Create e2e test directory
    mkdir -p tests/e2e

    # Add test scripts to package.json
    npm pkg set scripts.test:e2e="playwright test"
    npm pkg set scripts.test:e2e:headed="playwright test --headed"
    npm pkg set scripts.test:e2e:ui="playwright test --ui"
    npm pkg set scripts.test:e2e:debug="playwright test --debug"

    # Create a smoke test
    cat > tests/e2e/smoke.spec.ts << 'EOF'
import { test, expect } from '@playwright/test';

test.describe('Smoke Tests', () => {
  test('app loads successfully', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle(/.+/);
  });
});
EOF

    echo "Playwright setup complete!"
    echo "Run tests with: npm run test:e2e"
    echo "Run with visible browser: npm run test:e2e:headed"
    echo "Run with UI mode: npm run test:e2e:ui"
}

# ============================================================================
# Vitest Bootstrap
# ============================================================================

# Bootstrap Vitest for unit and integration tests
# Detects project type (Vue, React, Node) and configures accordingly
testing_bootstrap_vitest() {
    local project_type="${1:-node}"

    echo "Installing Vitest..."

    case "$project_type" in
        vue|nuxt)
            npm install -D vitest @vue/test-utils happy-dom @testing-library/vue
            cat > vitest.config.ts << 'EOF'
import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  test: {
    environment: 'happy-dom',
    globals: true,
    include: ['tests/unit/**/*.test.ts', 'tests/integration/**/*.test.ts', 'src/**/*.test.ts'],
  },
})
EOF
            ;;
        react|next)
            npm install -D vitest @testing-library/react @testing-library/jest-dom jsdom
            cat > vitest.config.ts << 'EOF'
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,
    include: ['tests/unit/**/*.test.ts', 'tests/integration/**/*.test.ts', 'src/**/*.test.ts'],
    setupFiles: ['./tests/setup.ts'],
  },
})
EOF
            # Create setup file for React Testing Library
            mkdir -p tests
            cat > tests/setup.ts << 'EOF'
import '@testing-library/jest-dom';
EOF
            ;;
        *)
            npm install -D vitest
            cat > vitest.config.ts << 'EOF'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    globals: true,
    include: ['tests/unit/**/*.test.ts', 'tests/integration/**/*.test.ts', 'src/**/*.test.ts'],
  },
})
EOF
            ;;
    esac

    # Create test directories
    mkdir -p tests/unit
    mkdir -p tests/integration

    # Add test scripts to package.json
    npm pkg set scripts.test:unit="vitest run --dir tests/unit"
    npm pkg set scripts.test:integration="vitest run --dir tests/integration"
    npm pkg set scripts.test:watch="vitest"
    npm pkg set scripts.test:coverage="vitest run --coverage"

    # Create a smoke test
    cat > tests/unit/smoke.test.ts << 'EOF'
import { describe, it, expect } from 'vitest'

describe('Test Setup', () => {
  it('works', () => {
    expect(true).toBe(true)
  })
})
EOF

    echo "Vitest setup complete!"
    echo "Run unit tests: npm run test:unit"
    echo "Run integration tests: npm run test:integration"
    echo "Run in watch mode: npm run test:watch"
}

# ============================================================================
# Full Test Infrastructure Bootstrap
# ============================================================================

# Bootstrap complete test infrastructure (all tiers)
testing_bootstrap_all() {
    local project_type="${1:-}"
    local base_url="${2:-http://localhost:3000}"
    local dev_command="${3:-npm run dev}"

    # Auto-detect project type if not provided
    if [ -z "$project_type" ]; then
        if [ -f "nuxt.config.ts" ] || [ -f "nuxt.config.js" ]; then
            project_type="nuxt"
        elif [ -f "next.config.js" ] || [ -f "next.config.mjs" ]; then
            project_type="next"
        elif grep -q '"vue"' package.json 2>/dev/null; then
            project_type="vue"
        elif grep -q '"react"' package.json 2>/dev/null; then
            project_type="react"
        else
            project_type="node"
        fi
    fi

    echo "Detected project type: $project_type"
    echo ""

    # Bootstrap Vitest for unit + integration
    testing_bootstrap_vitest "$project_type"
    echo ""

    # Bootstrap Playwright for e2e
    testing_bootstrap_playwright "$base_url" "$dev_command"
    echo ""

    # Add combined test script
    npm pkg set scripts.test="npm run test:unit && npm run test:integration && npm run test:e2e"

    echo "Complete test infrastructure setup!"
    echo ""
    echo "Test tiers:"
    echo "  Unit:        npm run test:unit"
    echo "  Integration: npm run test:integration"
    echo "  E2E:         npm run test:e2e"
    echo "  All:         npm test"
}

# ============================================================================
# Test Execution
# ============================================================================

# Run e2e tests with visible browser
testing_run_e2e_headed() {
    npx playwright test --headed
}

# Run e2e tests in UI mode (interactive)
testing_run_e2e_ui() {
    npx playwright test --ui
}

# Run e2e tests in debug mode
testing_run_e2e_debug() {
    npx playwright test --debug
}

# Run all test tiers and return results as JSON
testing_run_all() {
    local results='{"unit": "skipped", "integration": "skipped", "e2e": "skipped"}'

    # Unit tests
    if npm run test:unit 2>/dev/null; then
        results=$(echo "$results" | jq '.unit = "pass"')
    elif npm run test:unit 2>&1 | grep -q "Missing script"; then
        results=$(echo "$results" | jq '.unit = "not_configured"')
    else
        results=$(echo "$results" | jq '.unit = "fail"')
    fi

    # Integration tests
    if npm run test:integration 2>/dev/null; then
        results=$(echo "$results" | jq '.integration = "pass"')
    elif npm run test:integration 2>&1 | grep -q "Missing script"; then
        results=$(echo "$results" | jq '.integration = "not_configured"')
    else
        results=$(echo "$results" | jq '.integration = "fail"')
    fi

    # E2E tests
    if npm run test:e2e 2>/dev/null; then
        results=$(echo "$results" | jq '.e2e = "pass"')
    elif npm run test:e2e 2>&1 | grep -q "Missing script"; then
        results=$(echo "$results" | jq '.e2e = "not_configured"')
    else
        results=$(echo "$results" | jq '.e2e = "fail"')
    fi

    echo "$results"
}

# Run specific test tier
testing_run_tier() {
    local tier="$1"

    case "$tier" in
        unit)
            npm run test:unit
            ;;
        integration)
            npm run test:integration
            ;;
        e2e)
            npm run test:e2e
            ;;
        e2e:headed)
            npm run test:e2e:headed
            ;;
        e2e:ui)
            npm run test:e2e:ui
            ;;
        all)
            npm test
            ;;
        *)
            echo "Unknown test tier: $tier"
            echo "Available: unit, integration, e2e, e2e:headed, e2e:ui, all"
            return 1
            ;;
    esac
}

# ============================================================================
# Browser Validation
# ============================================================================

# Run browser validation - starts dev server and runs visual checks
testing_run_browser_validation() {
    local validation_spec="${1:-tests/validation/visual-check.spec.ts}"

    if [ ! -f "$validation_spec" ]; then
        echo "Creating validation spec template..."
        mkdir -p "$(dirname "$validation_spec")"
        cat > "$validation_spec" << 'EOF'
import { test, expect } from '@playwright/test';

test.describe('Visual Validation', () => {
  test('captures homepage screenshot', async ({ page }) => {
    await page.goto('/');
    await page.screenshot({ path: 'screenshots/homepage.png', fullPage: true });
  });

  test('app is functional', async ({ page }) => {
    await page.goto('/');
    // Add assertions for your specific app
    await expect(page).toHaveTitle(/.+/);
  });
});
EOF
    fi

    # Create screenshots directory
    mkdir -p screenshots

    # Run validation with headed browser
    npx playwright test "$validation_spec" --headed
}

# Take screenshots of key pages
testing_capture_screenshots() {
    local pages=("$@")

    if [ ${#pages[@]} -eq 0 ]; then
        pages=("/")
    fi

    mkdir -p screenshots

    local script_file=$(mktemp)
    cat > "$script_file" << 'EOF'
import { chromium } from '@playwright/test';

async function captureScreenshots() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();

  const pages = process.argv.slice(2);
  const baseUrl = process.env.BASE_URL || 'http://localhost:3000';

  for (const pagePath of pages) {
    const url = pagePath.startsWith('http') ? pagePath : `${baseUrl}${pagePath}`;
    console.log(`Capturing: ${url}`);

    await page.goto(url, { waitUntil: 'networkidle' });

    const filename = pagePath === '/' ? 'homepage' : pagePath.replace(/\//g, '_').replace(/^_/, '');
    await page.screenshot({
      path: `screenshots/${filename}.png`,
      fullPage: true
    });
  }

  await browser.close();
}

captureScreenshots().catch(console.error);
EOF

    npx tsx "$script_file" "${pages[@]}"
    rm -f "$script_file"
}

# ============================================================================
# Test Results Analysis
# ============================================================================

# Analyze test results and return summary
testing_analyze_results() {
    local results_dir="${1:-.}"
    local summary='{"total": 0, "passed": 0, "failed": 0, "skipped": 0}'

    # Check for Playwright results
    if [ -f "$results_dir/test-results/.last-run.json" ]; then
        local pw_results=$(cat "$results_dir/test-results/.last-run.json")
        summary=$(echo "$summary" | jq --argjson pw "$pw_results" '
            .total += ($pw.suites | map(.specs | length) | add // 0) |
            .passed += ($pw.suites | map(.specs | map(select(.ok)) | length) | add // 0) |
            .failed += ($pw.suites | map(.specs | map(select(.ok | not)) | length) | add // 0)
        ')
    fi

    # Check for Vitest results (if JSON reporter configured)
    if [ -f "$results_dir/vitest-results.json" ]; then
        local vt_results=$(cat "$results_dir/vitest-results.json")
        summary=$(echo "$summary" | jq --argjson vt "$vt_results" '
            .total += ($vt.numTotalTests // 0) |
            .passed += ($vt.numPassedTests // 0) |
            .failed += ($vt.numFailedTests // 0) |
            .skipped += ($vt.numPendingTests // 0)
        ')
    fi

    echo "$summary"
}
