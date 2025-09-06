#!/bin/bash

# Prerequisite installer for CarManager build system
# Installs all required Homebrew packages for development and CI

set -e

BREW_PACKAGES=(
  yq         # YAML processor for bash
  xcodegen   # Xcode project generator
  swiftlint  # Swift code linter
)

# Check for Homebrew and install if necessary
if ! command -v brew &>/dev/null; then
  echo "[INFO] Homebrew not found. Installing Homebrew..."
  
  # Install Homebrew
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  
  # Add Homebrew to PATH for this session
  if [[ -f "/opt/homebrew/bin/brew" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
  elif [[ -f "/usr/local/bin/brew" ]]; then
    export PATH="/usr/local/bin:$PATH"
  fi
  
  echo "[INFO] Homebrew installed successfully"
else
  echo "[OK] Homebrew already installed"
fi

echo "[INFO] Installing required Homebrew packages..."
for pkg in "${BREW_PACKAGES[@]}"; do
  if brew list "$pkg" &>/dev/null; then
    echo "[OK] $pkg already installed."
  else
    echo "[INFO] Installing $pkg..."
    brew install "$pkg"
  fi
done

# Check for Parallel::ForkManager Perl module
if ! perl -MParallel::ForkManager -e1 2>/dev/null; then
  echo "Error: Perl module Parallel::ForkManager is not installed. Please install it with 'cpan Parallel::ForkManager' or your preferred Perl package manager."
  exit 1
fi

echo "[INFO] All prerequisites are installed." 