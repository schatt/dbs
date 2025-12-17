#!/bin/bash

# Script to create GitHub issues from refactoring templates
# Requires GitHub CLI (gh) to be installed and authenticated

# Don't exit on error - we want to continue creating issues even if some fail
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/.github/ISSUE_TEMPLATE"

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    echo "Error: GitHub CLI (gh) is not installed."
    echo "Install it from: https://cli.github.com/"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo "Error: Not authenticated with GitHub CLI."
    echo "Run: gh auth login"
    exit 1
fi

# Function to create issue from template
create_issue() {
    local template_file="$1"
    local issue_num="$2"
    
    if [ ! -f "$template_file" ]; then
        echo "Warning: Template file not found: $template_file"
        return 1
    fi
    
    echo "Creating issue #$issue_num from $template_file..."
    
    # Extract title from template (title is on the same line as "title:")
    local title=$(grep "^title:" "$template_file" | sed 's/^title: //' | sed "s/^'//" | sed "s/'$//")
    
    # Extract labels from template
    local labels=$(grep "^labels:" "$template_file" | sed 's/labels: //' | tr -d "'")
    
    # Create temporary file with body (strip YAML frontmatter)
    local body_file=$(mktemp)
    # Remove everything from start to the second "---" (inclusive)
    sed '1,/^---$/d' "$template_file" > "$body_file"
    
    # Create issue using gh CLI
    # Try with labels first, fall back to creating without labels if that fails
    local issue_output
    issue_output=$(gh issue create \
        --title "$title" \
        --label "$labels" \
        --body-file "$body_file" \
        --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)" 2>&1)
    
    # Clean up temp file
    rm -f "$body_file"
    
    if [ $? -eq 0 ]; then
        return 0
    else
        # Try creating without labels first
        # Create temporary file with body (strip YAML frontmatter)
        local body_file=$(mktemp)
        # Remove everything from start to the second "---" (inclusive)
        sed '1,/^---$/d' "$template_file" > "$body_file"
        
        issue_output=$(gh issue create \
            --title "$title" \
            --body-file "$body_file" \
            --repo "$(gh repo view --json nameWithOwner -q .nameWithOwner)" 2>&1)
        
        # Clean up temp file
        rm -f "$body_file"
        
        if [ $? -eq 0 ]; then
            # Extract issue number from output (format: "https://github.com/owner/repo/issues/123")
            local issue_num=$(echo "$issue_output" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+' | head -1)
            
            if [ -n "$issue_num" ]; then
                # Add labels separately
                echo "$labels" | tr ',' '\n' | while read -r label; do
                    label=$(echo "$label" | xargs) # trim whitespace
                    if [ -n "$label" ]; then
                        gh issue edit "$issue_num" --add-label "$label" 2>/dev/null || true
                    fi
                done
            fi
            return 0
        else
            echo "Error: $issue_output"
            return 1
        fi
    fi
    
    if [ $? -eq 0 ]; then
        echo "✓ Created issue #$issue_num: $title"
    else
        echo "✗ Failed to create issue #$issue_num"
        return 1
    fi
}

# Function to ensure labels exist
ensure_labels() {
    echo "Ensuring labels exist..."
    
    local labels=("refactor" "high-priority" "medium-priority" "lower-priority" "phase-1" "phase-2" "phase-3" "phase-4" "phase-5" "phase-6")
    local colors=("1d76db" "b60205" "d93f0b" "fbca04" "0e8a16" "0e8a16" "0e8a16" "0e8a16" "0e8a16" "0e8a16")
    
    for i in "${!labels[@]}"; do
        local label="${labels[$i]}"
        local color="${colors[$i]}"
        
        # Check if label exists
        if ! gh label list | grep -q "^$label"; then
            echo "Creating label: $label"
            gh label create "$label" --color "$color" --description "Refactoring label: $label" 2>/dev/null || true
        else
            echo "Label already exists: $label"
        fi
    done
    echo ""
}

# Main execution
echo "Creating refactoring issues..."
ensure_labels
echo ""

# Phase 1
create_issue "$TEMPLATE_DIR/refactor-01-extract-execution-engine.md" "1"
create_issue "$TEMPLATE_DIR/refactor-02-extract-phase-methods.md" "2"
create_issue "$TEMPLATE_DIR/refactor-03-extract-command-executor.md" "3"

# Phase 2
create_issue "$TEMPLATE_DIR/refactor-04-split-buildutils-node.md" "4"
create_issue "$TEMPLATE_DIR/refactor-05-split-buildutils-graph.md" "5"
create_issue "$TEMPLATE_DIR/refactor-06-split-buildutils-display.md" "6"
create_issue "$TEMPLATE_DIR/refactor-07-split-buildutils-queue.md" "7"
create_issue "$TEMPLATE_DIR/refactor-08-split-buildutils-config.md" "8"

# Phase 3
create_issue "$TEMPLATE_DIR/refactor-09-extract-cli-handler.md" "9"
create_issue "$TEMPLATE_DIR/refactor-10-extract-config-loader.md" "10"
create_issue "$TEMPLATE_DIR/refactor-11-extract-artifact-manager.md" "11"
create_issue "$TEMPLATE_DIR/refactor-12-extract-output-handler.md" "12"
create_issue "$TEMPLATE_DIR/refactor-13-refactor-main-script.md" "13"

# Phase 4
create_issue "$TEMPLATE_DIR/refactor-14-encapsulate-global-state.md" "14"

# Phase 5
create_issue "$TEMPLATE_DIR/refactor-15-consolidate-artifact-retention.md" "15"

# Phase 6
create_issue "$TEMPLATE_DIR/refactor-16-improve-error-handling.md" "16"
create_issue "$TEMPLATE_DIR/refactor-17-extract-constants.md" "17"
create_issue "$TEMPLATE_DIR/refactor-18-reduce-code-duplication.md" "18"

echo ""
echo "Done! Created all refactoring issues."
echo ""
echo "To view issues: gh issue list"
echo "To view a specific issue: gh issue view <number>"
