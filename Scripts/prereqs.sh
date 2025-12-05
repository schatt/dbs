#!/bin/bash

# Prerequisite installer for Distributed Build System (DBS)
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

# Required Perl modules (non-core modules that need to be installed)
PERL_MODULES=(
  "YAML::XS"
  "JSON"
  "Parallel::ForkManager"
  "Term::ANSIColor"
  "Digest::SHA"
  "Time::Piece"
)

# Check for required Perl modules
MISSING_MODULES=()
for module in "${PERL_MODULES[@]}"; do
  if ! perl -M"$module" -e1 2>/dev/null; then
    MISSING_MODULES+=("$module")
  else
    echo "[OK] Perl module $module is installed"
  fi
done

# Report missing modules and exit with error if any are missing
if [ ${#MISSING_MODULES[@]} -gt 0 ]; then
  echo ""
  echo "Error: The following required Perl modules are not installed:"
  for module in "${MISSING_MODULES[@]}"; do
    echo "  - $module"
  done
  echo ""
  echo "Please install them using one of the following methods:"
  echo "  cpan install ${MISSING_MODULES[*]}"
  echo "  or"
  echo "  cpanm ${MISSING_MODULES[*]}"
  echo ""
  exit 1
fi

echo "[INFO] All prerequisites are installed." 