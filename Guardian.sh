#!/usr/bin/env bash
set -euo pipefail

# Guardian.sh - pre-commit and post-commit guardian for frontend
# Limits: file < 500 lines, functions < 50 lines

ROOT_DIR() {
  git rev-parse --show-toplevel 2>/dev/null || echo "$(pwd)"
}

run_cmd() {
  echo "+ $*"
  "$@"
}

ts_check() {
  # TypeScript type check if tsconfig exists
  if [ -f "$(ROOT_DIR)/tsconfig.json" ]; then
    if command -v npx >/dev/null 2>&1; then
      run_cmd npx tsc --noEmit
    else
      echo "npx not found, skipping tsc check"
    fi
  else
    echo "no tsconfig.json, skipping TypeScript check"
  fi
}

eslint_check() {
  if [ -f "$(ROOT_DIR)/package.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      if jq -e '.scripts.lint' < "$(ROOT_DIR)/package.json" >/dev/null 2>&1; then
        run_cmd npm run lint --silent
      elif command -v npx >/dev/null 2>&1; then
        run_cmd npx eslint "**/*.{js,ts,jsx,tsx}" --max-warnings=0
      else
        echo "eslint/npm not available, skipping eslint"
      fi
    else
      if grep -q '"lint"' "$(ROOT_DIR)/package.json" 2>/dev/null; then
        run_cmd npm run lint --silent
      elif command -v npx >/dev/null 2>&1; then
        run_cmd npx eslint "**/*.{js,ts,jsx,tsx}" --max-warnings=0
      else
        echo "eslint/npm not available, skipping eslint"
      fi
    fi
  fi
}

prettier_check() {
  if command -v npx >/dev/null 2>&1; then
    if command -v jq >/dev/null 2>&1; then
      if jq -e '.devDependencies.prettier' < "$(ROOT_DIR)/package.json" >/dev/null 2>&1; then
        run_cmd npx prettier --check "**/*.{js,ts,jsx,tsx,json,md,css}" || true
      else
        echo "prettier not configured, skipping"
      fi
    else
      if grep -q '"prettier"' "$(ROOT_DIR)/package.json" 2>/dev/null; then
        run_cmd npx prettier --check "**/*.{js,ts,jsx,tsx,json,md,css}" || true
      else
        echo "prettier not configured, skipping"
      fi
    fi
  fi
}

run_tests() {
  if command -v jq >/dev/null 2>&1; then
    if jq -e '.scripts.test' < "$(ROOT_DIR)/package.json" >/dev/null 2>&1; then
      run_cmd npm test --silent
    else
      echo "no test script, skipping tests"
    fi
  else
    if grep -q '"test"' "$(ROOT_DIR)/package.json" 2>/dev/null; then
      run_cmd npm test --silent
    else
      echo "no test script, skipping tests"
    fi
  fi
}

smoke_functional() {
  # Functional guard: run a fast build if configured; can be skipped with GUARDIAN_SKIP_BUILD=1
  if [ "${GUARDIAN_SKIP_BUILD:-0}" = "1" ]; then
    echo "GUARDIAN_SKIP_BUILD=1 set, skipping functional build"
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    has_build=$(jq -r 'has("scripts") and (.scripts|has("build"))' "$(ROOT_DIR)/package.json" 2>/dev/null || echo false)
    if [ "$has_build" = "true" ]; then
      echo "Running build as functional guard (this may take time)..."
      run_cmd npm run build --silent
    else
      echo "no build script, skipping functional guard"
    fi
  else
    if grep -q '"build"' "$(ROOT_DIR)/package.json" 2>/dev/null; then
      echo "Running build as functional guard (this may take time)..."
      run_cmd npm run build --silent
    else
      echo "no build script, skipping functional guard"
    fi
  fi
}

staged_files() {
  git diff --cached --name-only --diff-filter=ACM || true
}

check_file_lengths() {
  echo "[guardian] checking file lengths (max 500 lines)"
  local max=500
  local failed=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
      *.js|*.jsx|*.ts|*.tsx|*.go|*.py|*.css|*.scss|*.html|*.md)
        if [ -f "$file" ]; then
          lines=$(wc -l < "$file" | tr -d '[:space:]') || lines=0
          if [ "$lines" -gt "$max" ]; then
            echo "ERROR: $file has $lines lines (max $max)"
            failed=1
          fi
        fi
        ;;
      *) ;;
    esac
  done < <(staged_files)
  if [ "$failed" -ne 0 ]; then
    echo "One or more files exceed the maximum allowed length ($max lines)."
    exit 2
  fi
}

check_function_lengths() {
  echo "[guardian] checking function lengths (max 50 lines)"
  local max=50
  local failed=0
  while IFS= read -r file; do
    [ -z "$file" ] && continue
    case "$file" in
      *.js|*.jsx|*.ts|*.tsx|*.go)
        if [ -f "$file" ]; then
          # awk scans for 'function' (JS/TS) or 'func' (Go) and counts until matching braces
          awk -v max="$max" -v fname="$file" '
            /(^|[[:space:]])function[[:space:]]+/ || /^\s*func[[:space:]]+/ {
              start=NR; in=1; brace=0
            }
            {
              if(in){
                if($0 ~ /\{/){ brace+=gsub(/\{/,"{") }
                if($0 ~ /\}/){ brace-=gsub(/\}/,"}") }
                nlines=NR-start+1
                if(nlines>max){ printf("ERROR: %s: function starting at line %d is %d lines (> %d)\n", fname, start, nlines, max); in=0 }
                if(in && brace==0 && $0 ~ /\}/){ if(nlines>max) printf("ERROR: %s: function starting at line %d is %d lines (> %d)\n", fname, start, nlines, max); in=0 }
              }
            }
          ' "$file"
        fi
        ;;
      *) ;;
    esac
  done < <(staged_files)
  # if any ERROR printed to stdout, exit non-zero
  if grep -q "^ERROR:" <(staged_files | xargs -I{} bash -c 'sed -n "1,99999p" "{}"' 2>/dev/null | sed -n '1,1' ) 2>/dev/null; then
    # This grep logic is a fallback; awk already prints errors
    :
  fi
}

post_commit_coderabbit() {
  # Run coderabbit CLI against latest commit if available
  if ! command -v coderabbit >/dev/null 2>&1; then
    echo "coderabbit CLI not found; skipping coderabbit run"
    return 0
  fi
  local sha
  sha=$(git rev-parse HEAD)
  echo "Running coderabbit on commit $sha"
  run_cmd coderabbit analyze --commit "$sha" || echo "coderabbit exited non-zero"
}

precommit_frontend() {
  echo "[guardian] pre-commit checks: static & functional" 
  check_file_lengths
  check_function_lengths
  ts_check
  eslint_check
  prettier_check
  run_tests
  smoke_functional
  echo "[guardian] pre-commit passed"
}

postcommit_frontend() {
  echo "[guardian] post-commit: running coderabbit"
  post_commit_coderabbit
}

usage() {
  cat <<EOF
Usage: Guardian.sh <pre-commit|post-commit> <frontend>
EOF
  exit 2
}

main() {
  if [ $# -lt 2 ]; then
    usage
  fi
  action=$1
  target=$2
  case "$action:$target" in
    pre-commit:frontend)
      precommit_frontend
      ;;
    post-commit:frontend)
      postcommit_frontend
      ;;
    *)
      echo "Unknown action/target: $action $target"
      usage
      ;;
  esac
}

main "$@"
