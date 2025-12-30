# Release Process Script Template

This directory contains a generic, configurable release process script template that can be adapted for any project using DBS.

## Overview

The `release-process.sh.template` script provides a comprehensive release validation process that:

- Extracts and validates version numbers
- Runs project regeneration (if configured)
- Executes test suites
- Validates git repository state
- Checks documentation files for version consistency
- Validates release notes
- Optionally checks GitHub milestones and issues
- Creates and pushes git tags

## Quick Start

1. **Copy the template to your project:**
   ```bash
   cp /path/to/dbs/scripts/release-process.sh.template ./release-process.sh
   chmod +x ./release-process.sh
   ```

2. **Customize the configuration section** at the top of the script for your project

3. **Run the script:**
   ```bash
   ./release-process.sh minor 1.2.3
   # or
   ./release-process.sh minor  # Auto-detects current version and suggests next
   ```

## Configuration

Edit the `CONFIGURATION` section at the top of the script to customize it for your project:

### Required Configuration

- `PROJECT_NAME` - Your project name
- `GITHUB_OWNER` - GitHub username or organization
- `GITHUB_REPO` - GitHub repository name
- `VERSION_EXTRACTION_METHOD` - How to extract version (see below)

### Version Extraction Methods

Choose one of the following methods:

- **`version_file`** - Read from a simple VERSION file (default)
- **`package_json`** - Extract from Node.js package.json
- **`package_swift`** - Extract from Swift Package.swift
- **`setup_py`** - Extract from Python setup.py
- **`readme`** - Extract from README.md using regex
- **`custom`** - Define your own `extract_version_custom()` function

### Optional Configuration

- **`PROJECT_REGENERATE_CMD`** - Command to regenerate project files (e.g., `xcodegen`, `npm install`)
- **`TEST_CMD`** - Command to run your test suite
- **`DOC_FILES`** - Array of documentation files that should contain the version
- **`RELEASE_NOTES_FILE`** - Path to release notes file
- **`RELEASE_NOTES_DIR`** - Directory containing `RELEASE_v{VERSION}.md` files
- **`ENABLE_GITHUB_CHECKS`** - Enable GitHub milestone/issue validation (requires `gh` CLI)
- **`AUTO_TAG`** - Automatically create and push tags (default: false, prompts user)

## Examples

### Example 1: Swift/Xcode Project

```bash
# Configuration
PROJECT_NAME="MySwiftFramework"
VERSION_EXTRACTION_METHOD="package_swift"
PROJECT_REGENERATE_CMD="xcodegen"
TEST_CMD="xcodebuild test -project MyProject.xcodeproj -scheme MyProjectTests"
DOC_FILES=("README.md" "Package.swift")
RELEASE_NOTES_DIR="Development"
ENABLE_GITHUB_CHECKS="true"
```

### Example 2: Node.js Project

```bash
# Configuration
PROJECT_NAME="my-node-app"
VERSION_EXTRACTION_METHOD="package_json"
TEST_CMD="npm test"
DOC_FILES=("README.md" "package.json")
RELEASE_NOTES_FILE="CHANGELOG.md"
```

### Example 3: Python Project

```bash
# Configuration
PROJECT_NAME="my-python-package"
VERSION_EXTRACTION_METHOD="setup_py"
TEST_CMD="python -m pytest"
DOC_FILES=("README.md" "setup.py")
RELEASE_NOTES_FILE="CHANGELOG.md"
```

### Example 4: Simple Project with VERSION File

```bash
# Configuration
PROJECT_NAME="my-project"
VERSION_EXTRACTION_METHOD="version_file"
VERSION_FILE="VERSION"
TEST_CMD=""  # No tests
DOC_FILES=("README.md")
RELEASE_NOTES_FILE="RELEASE_NOTES.md"
```

## Custom Version Extraction

If your project uses a unique version storage method, you can define a custom extraction function:

```bash
extract_version_custom() {
    # Your custom extraction logic here
    # Should output version number (e.g., "1.2.3") and return 0 on success
    # Return 1 on failure
    if [ -f "custom_version_file.txt" ]; then
        grep -oE "[0-9]+\.[0-9]+\.[0-9]+" custom_version_file.txt | head -1
        return 0
    fi
    return 1
}
```

Then set:
```bash
VERSION_EXTRACTION_METHOD="custom"
```

## Usage

The script accepts arguments in flexible formats:

```bash
# Auto-detect version, suggest next patch version
./release-process.sh

# Auto-detect version, suggest next minor version
./release-process.sh minor

# Explicit version, patch release (default)
./release-process.sh 1.2.3

# Explicit type and version
./release-process.sh minor 1.2.3

# Version first, then type (also works)
./release-process.sh 1.2.3 minor
```

## Validation Steps

The script performs the following validations (based on configuration):

1. **Project Regeneration** - Regenerates project files if configured
2. **Tests** - Runs test suite if configured
3. **Git State** - Ensures repository is clean (if `REQUIRE_CLEAN_GIT=true`)
4. **Git Branch** - Ensures on main/master branch (if `REQUIRE_MAIN_BRANCH=true`)
5. **Documentation** - Validates version appears in configured documentation files
6. **Release Notes** - Checks for release notes file/directory
7. **GitHub** - Validates milestones and issues (if `ENABLE_GITHUB_CHECKS=true`)

## Integration with DBS Setup

You can optionally integrate this into your DBS setup script to automatically copy the template to user projects. Add to `setup_project_build_system.sh`:

```bash
# Copy release process template (optional)
if [ ! -f "$PROJECT_PATH/release-process.sh" ]; then
    print_status "Copying release process template..."
    cp "$DBS_PATH/scripts/release-process.sh.template" "$PROJECT_PATH/release-process.sh"
    chmod +x "$PROJECT_PATH/release-process.sh"
    print_success "Release process template copied (customize before use)"
fi
```

## Troubleshooting

### Version Not Detected

- Check that `VERSION_EXTRACTION_METHOD` matches your project type
- Verify the version file exists and contains a valid version
- Check that `VERSION_PATTERN` matches your version format

### Tests Failing

- Ensure `TEST_CMD` is correctly configured
- Test the command manually before running the release script
- Consider making tests optional for initial setup

### GitHub Checks Not Working

- Install GitHub CLI: `brew install gh` (macOS) or see [GitHub CLI docs](https://cli.github.com/)
- Authenticate: `gh auth login`
- Ensure `ENABLE_GITHUB_CHECKS=true` is set

## Best Practices

1. **Start Simple** - Begin with minimal configuration, add features as needed
2. **Test First** - Run the script with `--dry-run` or test on a branch first
3. **Version Consistency** - Keep version numbers in sync across all files
4. **Documentation** - Update release notes before running the script
5. **Git Hygiene** - Keep main branch clean and use feature branches

## Contributing

If you create useful customizations or find bugs, consider contributing back to the DBS project!















