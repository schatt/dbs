#!/bin/bash

# setup_project_build_system.sh
# Sets up the build system in a new project by creating symlinks
# Usage: ./setup_project_build_system.sh <project_path>
# Example: ./setup_project_build_system.sh ~/code/github/MyNewProject

set -e

# Configuration
DBS_PATH="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="$1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_usage() {
    echo "Usage: $0 <project_path>"
    echo "Example: $0 ~/code/github/MyNewProject"
    echo ""
    echo "This script sets up the build system in a project by creating symlinks"
    echo "to the core build system files from this repository."
}

# Check arguments
if [ $# -ne 1 ]; then
    print_error "Project path is required"
    print_usage
    exit 1
fi

# Validate project path
if [ ! -d "$PROJECT_PATH" ]; then
    print_error "Project path $PROJECT_PATH does not exist"
    exit 1
fi

# Convert to absolute path
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"
SCRIPTS_DIR="$PROJECT_PATH/Scripts"

print_status "Setting up build system in project: $PROJECT_PATH"
print_status "Build system source: $DBS_PATH"

# Check if Scripts directory exists, create if not
if [ ! -d "$SCRIPTS_DIR" ]; then
    print_status "Creating Scripts directory"
    mkdir -p "$SCRIPTS_DIR"
fi

# Function to create backup and symlink
create_symlink() {
    local file="$1"
    local source_path="$DBS_PATH/Scripts/$file"
    local target_path="$SCRIPTS_DIR/$file"
    
    if [ ! -f "$source_path" ]; then
        print_error "Source file $source_path does not exist"
        return 1
    fi
    
    # Create backup if target exists and is not already a symlink
    if [ -f "$target_path" ] && [ ! -L "$target_path" ]; then
        print_status "Creating backup of $file"
        mv "$target_path" "$target_path.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Remove existing file/symlink
    if [ -e "$target_path" ]; then
        rm -f "$target_path"
    fi
    
    # Create symlink
    ln -s "$source_path" "$target_path"
    print_success "Created symlink for $file"
}

# List of core build system files to symlink
BUILD_FILES=(
    "build.pl"
    "BuildNode.pm"
    "BuildNodeRegistry.pm"
    "BuildStatusManager.pm"
    "BuildUtils.pm"
    "prereqs.sh"
)

# Create symlinks for each build system file
for file in "${BUILD_FILES[@]}"; do
    create_symlink "$file"
done

# Handle buildconfig.yml
print_status "Setting up buildconfig.yml"
if [ -f "$DBS_PATH/buildconfig.sample.yml" ]; then
    if [ ! -f "$PROJECT_PATH/buildconfig.yml" ]; then
        print_status "Copying buildconfig.sample.yml to buildconfig.yml"
        cp "$DBS_PATH/buildconfig.sample.yml" "$PROJECT_PATH/buildconfig.yml"
        print_success "Created buildconfig.yml from sample"
    else
        print_warning "buildconfig.yml already exists, not overwriting"
    fi
else
    print_warning "No buildconfig.sample.yml found in build system"
fi

# Copy release process template (optional)
print_status "Setting up release process template"
if [ -f "$DBS_PATH/Scripts/release-process.sh.template" ]; then
    if [ ! -f "$PROJECT_PATH/release-process.sh" ]; then
        print_status "Copying release-process.sh.template to release-process.sh"
        cp "$DBS_PATH/Scripts/release-process.sh.template" "$PROJECT_PATH/release-process.sh"
        chmod +x "$PROJECT_PATH/release-process.sh"
        print_success "Created release-process.sh from template"
        print_warning "⚠️  Remember to customize the configuration section in release-process.sh for your project"
    else
        print_warning "release-process.sh already exists, not overwriting"
    fi
else
    print_warning "No release-process.sh.template found in build system"
fi

# Verify symlinks were created correctly
print_status "Verifying symlinks..."
all_good=true
for file in "${BUILD_FILES[@]}"; do
    if [ -L "$SCRIPTS_DIR/$file" ]; then
        print_success "✓ $file is properly symlinked"
    else
        print_error "✗ $file symlink failed"
        all_good=false
    fi
done

if [ "$all_good" = true ]; then
    print_success "Build system setup complete!"
    print_status "You can now use the build system in your project"
    print_status "Example: cd $PROJECT_PATH && ./Scripts/build.pl --help"
else
    print_error "Some symlinks failed to create properly"
    exit 1
fi

# Create a simple README for the project
cat > "$PROJECT_PATH/BUILD_SYSTEM_README.md" << EOF
# Build System

This project uses a shared build system from the DBS (Distributed Build System) repository.

## Files

The following files are symlinked from the shared build system:
- \`Scripts/build.pl\` - Main build script
- \`Scripts/BuildNode.pm\` - Build node implementation
- \`Scripts/BuildNodeRegistry.pm\` - Node registry
- \`Scripts/BuildStatusManager.pm\` - Status management
- \`Scripts/BuildUtils.pm\` - Utility functions
- \`Scripts/prereqs.sh\` - Prerequisites setup

The following files are copied (not symlinked) and should be customized:
- \`release-process.sh\` - Release process script (customize configuration section)
- \`buildconfig.yml\` - Build configuration (project-specific)

## Usage

\`\`\`bash
# Show help
./Scripts/build.pl --help

# Run a build
./Scripts/build.pl --target <target_name>

# Validate build configuration
./Scripts/build.pl --validate

# Run release process (after customizing release-process.sh)
./release-process.sh minor 1.2.3
\`\`\`

## Configuration

Edit \`buildconfig.yml\` to configure your project's build targets and dependencies.

Edit \`release-process.sh\` to configure release validation for your project type.

## Updating

To update to the latest build system, simply pull the latest changes from the DBS repository.
The symlinks will automatically point to the updated files.

Note: \`release-process.sh\` and \`buildconfig.yml\` are copied (not symlinked), so they won't automatically update.

## Restoring

If you need to restore local build system files, look for \`*.backup.*\` files in the Scripts directory.
EOF

print_success "Created BUILD_SYSTEM_README.md with usage instructions"
