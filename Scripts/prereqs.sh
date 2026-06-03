#!/bin/bash

# Prerequisite installer for CarManager development (DBS build.pl, Xcode, agents)
# Installs Homebrew packages, RTK, hooks tooling, and Perl modules for Scripts/build.pl

set -e

BREW_PACKAGES=(
  yq           # YAML processor for bash / buildconfig
  xcodegen     # Xcode project generator
  swiftlint    # Swift code linter
  pre-commit   # local hook: block commits on main/next (.pre-commit-config.yaml)
  gh           # GitHub CLI (issues, PRs, CI)
  cpanm        # Perl module installer (build.pl dependencies)
)

# Rust Token Killer (rtk-ai/rtk) — not the unrelated crates.io "Rust Type Kit"
RTK_BREW_FORMULA="rtk-ai/tap/rtk"

require_brew() {
  if command -v brew &>/dev/null; then
    echo "[OK] Homebrew already installed"
    return
  fi

  echo "[INFO] Homebrew not found. Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  if [[ -f "/opt/homebrew/bin/brew" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
  elif [[ -f "/usr/local/bin/brew" ]]; then
    export PATH="/usr/local/bin:$PATH"
  fi

  echo "[INFO] Homebrew installed successfully"
}

install_brew_packages() {
  echo "[INFO] Installing required Homebrew packages..."
  for pkg in "${BREW_PACKAGES[@]}"; do
    if brew list "$pkg" &>/dev/null; then
      echo "[OK] $pkg already installed."
    else
      echo "[INFO] Installing $pkg..."
      brew install "$pkg"
    fi
  done
}

rtk_is_token_killer() {
  command -v rtk &>/dev/null && rtk gain &>/dev/null
}

install_rtk() {
  if rtk_is_token_killer; then
    echo "[OK] rtk (Rust Token Killer) already installed."
    return
  fi

  if command -v rtk &>/dev/null; then
    echo "[WARN] 'rtk' is present but 'rtk gain' failed — wrong package (Rust Type Kit?)."
    echo "[WARN] Uninstall it, then re-run this script."
  fi

  echo "[INFO] Installing rtk (Rust Token Killer) via Homebrew tap..."
  if ! brew install "${RTK_BREW_FORMULA}"; then
    echo "[INFO] Tap install failed; trying 'brew install rtk'..."
    brew install rtk
  fi

  if ! rtk_is_token_killer; then
    echo "[ERROR] rtk install did not produce a working 'rtk gain'. See https://github.com/rtk-ai/rtk"
    exit 1
  fi
  echo "[OK] rtk (Rust Token Killer) installed."
}

configure_rtk_for_cursor() {
  if [[ -n "${CI:-}" ]]; then
    echo "[INFO] CI environment; skipping rtk init (global Cursor hooks)."
    return
  fi

  if ! rtk_is_token_killer; then
    echo "[ERROR] rtk is not installed; cannot run rtk init."
    exit 1
  fi

  echo "[INFO] Configuring global RTK for Cursor (rtk init -g --agent cursor --auto-patch)..."
  rtk init -g --agent cursor --auto-patch
  echo "[OK] RTK Cursor hook configured (~/.cursor/hooks.json)."
}

PERL_MODULES=(
  "YAML::XS"
  "JSON"
  "Parallel::ForkManager"
  "Term::ANSIColor"
  "Digest::SHA"
  "Time::Piece"
)

ensure_perl_modules() {
  local missing=()
  local module

  for module in "${PERL_MODULES[@]}"; do
    if perl -M"$module" -e1 2>/dev/null; then
      echo "[OK] Perl module $module is installed"
    else
      missing+=("$module")
    fi
  done

  if [ ${#missing[@]} -eq 0 ]; then
    return
  fi

  if ! command -v cpanm &>/dev/null; then
    echo ""
    echo "Error: Missing Perl modules and cpanm is not available:"
    printf '  - %s\n' "${missing[@]}"
    echo ""
    echo "Install cpanm (brew install cpanm) and re-run ./Scripts/prereqs.sh"
    exit 1
  fi

  echo "[INFO] Installing Perl modules via cpanm: ${missing[*]}"
  cpanm --notest "${missing[@]}"
}

install_pre_commit_hooks() {
  local script_dir repo_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"

  if [[ ! -f "${repo_root}/.pre-commit-config.yaml" ]]; then
    echo "[WARN] No .pre-commit-config.yaml in repo root; skipping pre-commit install."
    return
  fi

  echo "[INFO] Installing pre-commit hooks (integration-branch guard)..."
  (cd "${repo_root}" && pre-commit install)
  echo "[OK] pre-commit hooks installed."
}

ensure_agent_worktree_root() {
  local wip_root="${CM_WIP_ROOT:-$HOME/code/github/cm-wip}"
  if [[ -d "$wip_root" ]]; then
    echo "[OK] Agent worktree root exists: $wip_root"
  else
    mkdir -p "$wip_root"
    echo "[OK] Created agent worktree root: $wip_root"
  fi
  echo "[INFO] Add issue worktrees with: Scripts/issue_worktree.sh add <issue> <slug>"
}

main() {
  require_brew
  install_brew_packages
  install_rtk
  configure_rtk_for_cursor
  ensure_perl_modules
  install_pre_commit_hooks
  ensure_agent_worktree_root
  echo "[INFO] All prerequisites are installed."
}

main "$@"
