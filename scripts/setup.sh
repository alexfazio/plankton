#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2155,SC2124,SC2034
# setup.sh - Install all plankton dependencies (macOS + Linux)
#
# Usage: bash scripts/setup.sh
#
# Idempotent — safe to re-run. Skips tools already on PATH.
# Linux installs use prebuilt binaries (no cargo/go required).

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────

BIN_DIR="${HOME}/.local/bin"

info() { printf '\033[1;34m[info]\033[0m %s\n' "$1"; }
ok() { printf '\033[1;32m[ok]\033[0m   %s\n' "$1"; }
skip() { printf '\033[1;33m[skip]\033[0m %s (already installed)\n' "$1"; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$1"; }

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    return 1
  fi
  skip "$1"
  return 0
}

# Fetch latest GitHub release binary URL matching a pattern (retries once)
github_release_url() {
  local repo="$1" pattern="$2"
  local url="" attempt
  for attempt in 1 2; do
    url=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
      | grep -o "\"browser_download_url\": *\"[^\"]*${pattern}[^\"]*\"" \
      | head -1 | cut -d'"' -f4 || true)
    [[ -n "${url}" ]] && break
    if [[ ${attempt} -eq 1 ]]; then
      info "GitHub API failed for ${repo}, retrying in 2s..."
      sleep 2
    fi
  done
  if [[ -z "${url}" ]]; then
    fail "Could not fetch release URL for ${repo} (pattern: ${pattern})"
    fail "Possible causes: GitHub API rate limit (60/hr unauthenticated), network error, or changed release assets"
    fail "Fix: wait a few minutes and retry, or export GITHUB_TOKEN to increase the rate limit"
    exit 1
  fi
  echo "${url}"
}

# Download a binary to BIN_DIR and make executable
install_binary() {
  local url="$1" name="$2"
  curl -fsSL "${url}" -o "${BIN_DIR}/${name}"
  chmod +x "${BIN_DIR}/${name}"
  ok "${name}"
}

# ── Platform detection ───────────────────────────────────────

OS="$(uname -s)"
ARCH="$(uname -m)"

case "${ARCH}" in
  x86_64 | amd64) ARCH="x86_64" ;;
  aarch64 | arm64) ARCH="aarch64" ;;
  *)
    fail "Unsupported architecture: ${ARCH}"
    exit 1
    ;;
esac

info "Platform: ${OS} ${ARCH}"

# ── Ensure BIN_DIR exists ────────────────────────────────────

mkdir -p "${BIN_DIR}"

if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  printf '\033[1;33m[warn]\033[0m %s is not on PATH. Add to your shell profile:\n' "${BIN_DIR}"
  # shellcheck disable=SC2016  # Intentional: $PATH should appear literally in output
  printf '       export PATH="%s:$PATH"\n' "${BIN_DIR}"
  export PATH="${BIN_DIR}:${PATH}"
fi

# ── macOS ────────────────────────────────────────────────────

install_macos() {
  if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew not found. Install from https://brew.sh"
    exit 1
  fi

  local to_install=()
  local brew_tools=(jaq ruff uv shellcheck shfmt hadolint taplo)

  for tool in "${brew_tools[@]}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      to_install+=("${tool}")
    else
      skip "${tool}"
    fi
  done

  if [[ ${#to_install[@]} -gt 0 ]]; then
    info "Installing via brew: ${to_install[*]}"
    brew install "${to_install[@]}"
    for tool in "${to_install[@]}"; do ok "${tool}"; done
  fi

  # bun
  if ! command -v bun >/dev/null 2>&1; then
    info "Installing bun..."
    brew install oven-sh/bun/bun
    ok "bun"
  else
    skip "bun"
  fi
}

# ── Linux ────────────────────────────────────────────────────

install_linux() {
  # ruff
  # shellcheck disable=SC2310
  if ! need_cmd ruff; then
    info "Installing ruff..."
    curl -LsSf https://astral.sh/ruff/install.sh | sh
    ok "ruff"
  fi

  # uv
  # shellcheck disable=SC2310
  if ! need_cmd uv; then
    info "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    ok "uv"
  fi

  # jaq
  # shellcheck disable=SC2310
  if ! need_cmd jaq; then
    info "Installing jaq..."
    local jaq_arch
    case "${ARCH}" in
      x86_64) jaq_arch="x86_64-unknown-linux-musl" ;;
      aarch64) jaq_arch="aarch64-unknown-linux-gnu" ;;
      *)
        fail "Unsupported arch for jaq: ${ARCH}"
        exit 1
        ;;
    esac
    local url
    url=$(github_release_url "01mf02/jaq" "jaq-${jaq_arch}")
    install_binary "${url}" "jaq"
  fi

  # shellcheck disable=SC2310
  if ! need_cmd shellcheck; then
    info "Installing shellcheck..."
    local sc_arch
    case "${ARCH}" in
      x86_64) sc_arch="x86_64" ;;
      aarch64) sc_arch="aarch64" ;;
      *)
        fail "Unsupported arch for shellcheck: ${ARCH}"
        exit 1
        ;;
    esac
    local url
    url=$(github_release_url "koalaman/shellcheck" "linux.${sc_arch}.tar.xz")
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL "${url}" | tar xJ -C "${tmp}"
    mv "${tmp}"/shellcheck-*/shellcheck "${BIN_DIR}/shellcheck"
    chmod +x "${BIN_DIR}/shellcheck"
    rm -rf "${tmp}"
    ok "shellcheck"
  fi

  # shfmt
  # shellcheck disable=SC2310
  if ! need_cmd shfmt; then
    info "Installing shfmt..."
    local shfmt_arch
    case "${ARCH}" in
      x86_64) shfmt_arch="amd64" ;;
      aarch64) shfmt_arch="arm64" ;;
      *)
        fail "Unsupported arch for shfmt: ${ARCH}"
        exit 1
        ;;
    esac
    local url
    url=$(github_release_url "mvdan/sh" "linux_${shfmt_arch}")
    install_binary "${url}" "shfmt"
  fi

  # hadolint
  # shellcheck disable=SC2310
  if ! need_cmd hadolint; then
    info "Installing hadolint..."
    local hadolint_arch
    case "${ARCH}" in
      x86_64) hadolint_arch="x86_64" ;;
      aarch64) hadolint_arch="arm64" ;;
      *)
        fail "Unsupported arch for hadolint: ${ARCH}"
        exit 1
        ;;
    esac
    local url
    url=$(github_release_url "hadolint/hadolint" "hadolint-linux-${hadolint_arch}")
    install_binary "${url}" "hadolint"
  fi

  # taplo
  # shellcheck disable=SC2310
  if ! need_cmd taplo; then
    info "Installing taplo..."
    local taplo_arch
    case "${ARCH}" in
      x86_64) taplo_arch="x86_64" ;;
      aarch64) taplo_arch="aarch64" ;;
      *)
        fail "Unsupported arch for taplo: ${ARCH}"
        exit 1
        ;;
    esac
    local url
    url=$(github_release_url "tamasfe/taplo" "taplo-linux-${taplo_arch}.gz")
    curl -fsSL "${url}" | gunzip >"${BIN_DIR}/taplo"
    chmod +x "${BIN_DIR}/taplo"
    ok "taplo"
  fi

  # bun
  # shellcheck disable=SC2310
  if ! need_cmd bun; then
    info "Installing bun..."
    curl -fsSL https://bun.sh/install | bash
    ok "bun"
  fi
}

# ── JS tools (both platforms) ────────────────────────────────

install_js_tools() {
  local project_dir
  project_dir="$(cd "$(dirname "$0")/.." && pwd)"

  info "Installing JS tools from package.json..."
  (cd "${project_dir}" && bun install)
  ok "biome + oxlint (from package.json)"

  # markdownlint-cli2 wrapper (bun global installs may not land on PATH)
  if ! command -v markdownlint-cli2 >/dev/null 2>&1; then
    info "Creating markdownlint-cli2 wrapper..."
    printf '#!/bin/sh\nexec bunx markdownlint-cli2@0.17.2 "$@"\n' >"${BIN_DIR}/markdownlint-cli2"
    chmod +x "${BIN_DIR}/markdownlint-cli2"
    ok "markdownlint-cli2 (bunx wrapper)"
  else
    skip "markdownlint-cli2"
  fi
}

# ── Python tools (both platforms) ────────────────────────────

install_python_tools() {
  local project_dir
  project_dir="$(cd "$(dirname "$0")/.." && pwd)"

  info "Installing Python tools via uv..."
  (cd "${project_dir}" && uv sync --all-extras --no-install-project)
  ok "Python linting tools (ruff, ty, bandit, vulture, flake8, yamllint)"
}

# ── Verification ─────────────────────────────────────────────

verify_setup() {
  echo ""
  info "Verification:"

  local all_ok=true
  local tools=(jaq ruff uv shellcheck shfmt hadolint taplo bun markdownlint-cli2)

  for tool in "${tools[@]}"; do
    local loc
    if loc=$(command -v "${tool}" 2>/dev/null); then
      printf '  \033[1;32m[ok]\033[0m     %-20s %s\n' "${tool}" "${loc}"
    else
      printf '  \033[1;31m[MISSING]\033[0m %-20s\n' "${tool}"
      all_ok=false
    fi
  done

  echo ""
  if ${all_ok}; then
    ok "All tools installed. Run: claude"
  else
    fail "Some tools are missing. Check the output above."
    exit 1
  fi
}

# ── Main ─────────────────────────────────────────────────────

echo ""
info "Plankton setup — installing all dependencies"
echo ""

case "${OS}" in
  Darwin) install_macos ;;
  Linux) install_linux ;;
  *)
    fail "Unsupported OS: ${OS} (use macOS or Linux)"
    exit 1
    ;;
esac

install_js_tools
install_python_tools
verify_setup
