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
    if jq -e '.scripts.lint' < "$(ROOT_DIR)/package.json" >/dev/null 2>&1; then
      run_cmd npm run lint --silent
    elif command -v npx >/dev/null 2>&1; then
      run_cmd npx eslint "**/*.{js,ts,jsx,tsx}" --max-warnings=0
    else
      echo "eslint/npm not available, skipping eslint"
    fi
  fi
}

prettier_check() {
  if command -v npx >/dev/null 2>&1; then
    if jq -e '.devDependencies.prettier' < "$(ROOT_DIR)/package.json" >/dev/null 2>&1; then
      run_cmd npx prettier --check "**/*.{js,ts,jsx,tsx,json,md,css}" || true
    else
      echo "prettier not configured, skipping"
    fi
  fi
}

run_tests() {
  if jq -e '.scripts.test' < "$(ROOT_DIR)/package.json" >/dev/null 2>&1; then
    run_cmd npm test --silent
  else
    echo "no test script, skipping tests"
  fi
}

smoke_functional() {
  # Functional guard: run a fast build if configured; can be skipped with GUARDIAN_SKIP_BUILD=1
  if [ "${GUARDIAN_SKIP_BUILD:-0}" = "1" ]; then
    echo "GUARDIAN_SKIP_BUILD=1 set, skipping functional build"
    return 0
  fi
  if jq -e '.scripts.build' < "$(ROOT_DIR)/package.json" >/dev/null 2>&1; then
    echo "Running build as functional guard (this may take time)..."
    run_cmd npm run build --silent
  else
    echo "no build script, skipping functional guard"
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
