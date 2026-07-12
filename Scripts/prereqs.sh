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

# Token Killer exposes `rtk init` / `rtk hook`; do not use `rtk gain` before init (needs stats DB).
rtk_binary_ok() {
  command -v rtk &>/dev/null && rtk --version &>/dev/null
}

rtk_is_token_killer_binary() {
  rtk_binary_ok && rtk init -h &>/dev/null
}

rtk_cursor_hook_configured() {
  rtk init -g --agent cursor --show 2>&1 | grep -q 'Cursor hook: registered'
}

install_rtk() {
  if rtk_is_token_killer_binary; then
    echo "[OK] rtk (Rust Token Killer) already installed."
    return
  fi

  if rtk_binary_ok; then
    echo "[ERROR] 'rtk' is on PATH but does not look like Rust Token Killer (wrong package?)."
    echo "[ERROR] Uninstall the wrong rtk, then re-run ./Scripts/prereqs.sh"
    echo "[ERROR] See https://github.com/rtk-ai/rtk — never use bare 'cargo install rtk'."
    exit 1
  fi

  echo "[INFO] Installing rtk (Rust Token Killer) via Homebrew tap..."
  if ! brew install "${RTK_BREW_FORMULA}"; then
    echo "[INFO] Tap install failed; trying 'brew install rtk'..."
    brew install rtk
  fi

  if ! rtk_is_token_killer_binary; then
    echo "[ERROR] rtk install failed or wrong package. See https://github.com/rtk-ai/rtk"
    exit 1
  fi
  echo "[OK] rtk (Rust Token Killer) installed."
}

configure_rtk_for_cursor() {
  if [[ -n "${CI:-}" ]]; then
    echo "[INFO] CI environment; skipping rtk init (global Cursor hooks)."
    return
  fi

  if ! rtk_is_token_killer_binary; then
    echo "[ERROR] rtk is not installed; cannot run rtk init."
    exit 1
  fi

  if rtk_cursor_hook_configured; then
    echo "[OK] RTK Cursor hook already configured (~/.cursor/hooks.json)."
    return
  fi

  echo "[INFO] Configuring global RTK for Cursor (rtk init -g --agent cursor --auto-patch)..."
  rtk init -g --agent cursor --auto-patch

  if ! rtk_cursor_hook_configured; then
    echo "[ERROR] rtk init finished but Cursor hook is not registered. Check ~/.cursor/hooks.json"
    exit 1
  fi
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
  local repo_root worktree_root
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  if [[ -n "${CM_WIP_ROOT:-}" ]]; then
    echo "[ERROR] CM_WIP_ROOT is retired (was ~/code/github/cm-wip). Unset it; worktrees live under ~/code/github/cm/."
    exit 1
  fi
  worktree_root="${CM_WORKTREE_ROOT:-$(dirname "$repo_root")}"
  if [[ "$worktree_root" == *cm-wip* ]]; then
    echo "[ERROR] CM_WORKTREE_ROOT must not point at cm-wip (retired). Use ~/code/github/cm/."
    exit 1
  fi
  if [[ -d "$worktree_root" ]]; then
    echo "[OK] Agent worktree root exists: $worktree_root"
  else
    mkdir -p "$worktree_root"
    echo "[OK] Created agent worktree root: $worktree_root"
  fi
  echo "[INFO] Add issue worktrees with: Scripts/issue_worktree.sh add <issue> <slug>"
}
ensure_cursor_workspace_link() {
  local repo_root worktree_root integration link target
  repo_root="$(cd "$(dirname "$0")/.." && pwd)"
  worktree_root="${CM_WORKTREE_ROOT:-$(dirname "$repo_root")}"
  integration="${worktree_root}/CarManager"
  link="${worktree_root}/.cursor"
  target="CarManager/.cursor"

  if [[ ! -f "${integration}/.cursor/hooks/git-prevent-multi-file-dirty.sh" ]]; then
    return 0
  fi

  chmod +x "${integration}/.cursor/hooks/"*.sh 2>/dev/null || true

  if [[ -L "$link" ]]; then
    if [[ "$(readlink "$link")" == "$target" ]]; then
      echo "[OK] Cursor workspace .cursor already linked: ${link} -> ${target}"
      return 0
    fi
    rm "$link"
  elif [[ -e "$link" ]]; then
    echo "[WARN] Replacing ${link} with symlink to ${target}"
    rm -rf "$link"
  fi

  ln -s "$target" "$link"
  echo "[OK] Cursor workspace .cursor linked: ${link} -> ${target}"
}


main() {
  require_brew
  install_brew_packages
  install_rtk
  configure_rtk_for_cursor
  ensure_perl_modules
  install_pre_commit_hooks
  ensure_agent_worktree_root
  ensure_cursor_workspace_link
  echo "[INFO] All prerequisites are installed."
}

main "$@"
