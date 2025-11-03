#!/bin/bash

# Script to create symlinks to DBS scripts for use from other projects
# This allows the build system to be used from anywhere
#
# Usage:
#   ./create_symlinks.sh [target_directory] [--force]
#
# Examples:
#   ./create_symlinks.sh                    # Creates symlinks in ~/bin
#   ./create_symlinks.sh /usr/local/bin      # Creates symlinks in /usr/local/bin
#   ./create_symlinks.sh ~/bin --force      # Non-interactive mode

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBS_ROOT="$SCRIPT_DIR"
SCRIPTS_DIR="$DBS_ROOT/Scripts"

# Default target directory for symlinks (user's local bin)
DEFAULT_TARGET_DIR="$HOME/bin"

# Parse arguments
FORCE=false
TARGET_DIR=""

for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE=true
            ;;
        --help|-h)
            echo "Usage: $0 [target_directory] [--force]"
            echo ""
            echo "Creates symlinks to DBS scripts for use from other projects."
            echo ""
            echo "Options:"
            echo "  target_directory  Directory where symlinks will be created (default: ~/bin)"
            echo "  --force, -f       Overwrite existing symlinks without prompting"
            echo "  --help, -h        Show this help message"
            exit 0
            ;;
        -*)
            echo "Unknown option: $arg" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            if [ -z "$TARGET_DIR" ]; then
                TARGET_DIR="$arg"
            else
                echo "Error: Multiple target directories specified" >&2
                exit 1
            fi
            ;;
    esac
done

# Use default if not specified
TARGET_DIR="${TARGET_DIR:-$DEFAULT_TARGET_DIR}"

# Expand ~ to home directory
TARGET_DIR="${TARGET_DIR/#\~/$HOME}"

# Convert to absolute path
if [ -d "$TARGET_DIR" ]; then
    TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
else
    # If directory doesn't exist, resolve parent and append basename
    PARENT_DIR="$(dirname "$TARGET_DIR")"
    BASENAME="$(basename "$TARGET_DIR")"
    if [ -d "$PARENT_DIR" ]; then
        TARGET_DIR="$(cd "$PARENT_DIR" && pwd)/$BASENAME"
    else
        # If parent doesn't exist either, use as-is (will be created)
        TARGET_DIR="$(cd "$(dirname "$PARENT_DIR")" 2>/dev/null && pwd)/$(basename "$PARENT_DIR")/$BASENAME" || TARGET_DIR="$TARGET_DIR"
    fi
fi

echo "Creating symlinks to DBS scripts..."
echo "DBS root: $DBS_ROOT"
echo "Target directory: $TARGET_DIR"
echo ""

# Create target directory if it doesn't exist
if [ ! -d "$TARGET_DIR" ]; then
    echo "Creating target directory: $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
fi

# Function to create symlink with confirmation
create_symlink() {
    local source="$1"
    local target="$2"
    local link_name="$3"
    
    local link_path="$TARGET_DIR/$link_name"
    
    # Check if link already exists
    if [ -L "$link_path" ]; then
        local existing_target="$(readlink "$link_path")"
        if [ "$existing_target" = "$source" ]; then
            echo "[SKIP] $link_name already symlinked correctly"
            return 0
        else
            echo "[WARN] $link_name exists but points to different location: $existing_target"
            if [ "$FORCE" = true ]; then
                rm "$link_path"
            else
                read -p "Overwrite? (y/N): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo "[SKIP] Keeping existing symlink"
                    return 0
                fi
                rm "$link_path"
            fi
        fi
    elif [ -e "$link_path" ]; then
        echo "[WARN] $link_name exists but is not a symlink"
        if [ "$FORCE" = true ]; then
            rm "$link_path"
        else
            read -p "Overwrite? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "[SKIP] Keeping existing file"
                return 0
            fi
            rm "$link_path"
        fi
    fi
    
    # Create symlink
    ln -s "$source" "$link_path"
    echo "[OK] Created symlink: $link_name -> $source"
}

# Create symlinks for executable scripts
if [ -f "$SCRIPTS_DIR/build.pl" ]; then
    create_symlink "$SCRIPTS_DIR/build.pl" "$TARGET_DIR" "dbs-build"
fi

if [ -f "$SCRIPTS_DIR/prereqs.sh" ]; then
    create_symlink "$SCRIPTS_DIR/prereqs.sh" "$TARGET_DIR" "dbs-prereqs"
fi

# Also create a symlink to the Scripts directory for easy access
SCRIPTS_LINK="$TARGET_DIR/dbs-scripts"
if [ -L "$SCRIPTS_LINK" ]; then
    existing_target="$(readlink "$SCRIPTS_LINK")"
    if [ "$existing_target" = "$SCRIPTS_DIR" ]; then
        echo "[SKIP] dbs-scripts directory already symlinked correctly"
    else
        echo "[WARN] dbs-scripts exists but points to different location"
        if [ "$FORCE" = true ]; then
            rm "$SCRIPTS_LINK"
            ln -s "$SCRIPTS_DIR" "$SCRIPTS_LINK"
            echo "[OK] Updated symlink: dbs-scripts -> $SCRIPTS_DIR"
        else
            read -p "Overwrite? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm "$SCRIPTS_LINK"
                ln -s "$SCRIPTS_DIR" "$SCRIPTS_LINK"
                echo "[OK] Updated symlink: dbs-scripts -> $SCRIPTS_DIR"
            fi
        fi
    fi
elif [ -e "$SCRIPTS_LINK" ]; then
    echo "[WARN] dbs-scripts exists but is not a symlink"
    if [ "$FORCE" = true ]; then
        rm "$SCRIPTS_LINK"
        ln -s "$SCRIPTS_DIR" "$SCRIPTS_LINK"
        echo "[OK] Created symlink: dbs-scripts -> $SCRIPTS_DIR"
    else
        read -p "Overwrite? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm "$SCRIPTS_LINK"
            ln -s "$SCRIPTS_DIR" "$SCRIPTS_LINK"
            echo "[OK] Created symlink: dbs-scripts -> $SCRIPTS_DIR"
        fi
    fi
else
    ln -s "$SCRIPTS_DIR" "$SCRIPTS_LINK"
    echo "[OK] Created symlink: dbs-scripts -> $SCRIPTS_DIR"
fi

echo ""
echo "Symlinks created successfully!"
echo ""
echo "To use the scripts, add $TARGET_DIR to your PATH:"
echo "  export PATH=\"\$PATH:$TARGET_DIR\""
echo ""
echo "Then you can use:"
echo "  dbs-build --help"
echo "  dbs-prereqs"
echo ""
echo "Or access the Scripts directory at: $TARGET_DIR/dbs-scripts"

