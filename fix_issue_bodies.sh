#!/bin/bash

# Script to fix the bodies of all refactoring issues (remove YAML frontmatter)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/.github/ISSUE_TEMPLATE"

# Function to extract and update issue body
fix_issue_body() {
    local template_file="$1"
    local issue_num="$2"
    
    if [ ! -f "$template_file" ]; then
        echo "Warning: Template file not found: $template_file"
        return 1
    fi
    
    # Create temporary file with body (strip YAML frontmatter)
    local body_file=$(mktemp)
    # Remove everything from start to the second "---" (inclusive)
    sed '1,/^---$/d' "$template_file" > "$body_file"
    
    echo "Updating body for issue #$issue_num..."
    
    # Update issue body
    gh issue edit "$issue_num" --body-file "$body_file"
    
    # Clean up temp file
    rm -f "$body_file"
    
    if [ $? -eq 0 ]; then
        echo "✓ Updated body for issue #$issue_num"
    else
        echo "✗ Failed to update body for issue #$issue_num"
        return 1
    fi
}

# Main execution
echo "Fixing issue bodies (removing YAML frontmatter)..."
echo ""

# Phase 1
fix_issue_body "$TEMPLATE_DIR/refactor-01-extract-execution-engine.md" "1"
fix_issue_body "$TEMPLATE_DIR/refactor-02-extract-phase-methods.md" "2"
fix_issue_body "$TEMPLATE_DIR/refactor-03-extract-command-executor.md" "3"

# Phase 2
fix_issue_body "$TEMPLATE_DIR/refactor-04-split-buildutils-node.md" "4"
fix_issue_body "$TEMPLATE_DIR/refactor-05-split-buildutils-graph.md" "5"
fix_issue_body "$TEMPLATE_DIR/refactor-06-split-buildutils-display.md" "6"
fix_issue_body "$TEMPLATE_DIR/refactor-07-split-buildutils-queue.md" "7"
fix_issue_body "$TEMPLATE_DIR/refactor-08-split-buildutils-config.md" "8"

# Phase 3
fix_issue_body "$TEMPLATE_DIR/refactor-09-extract-cli-handler.md" "9"
fix_issue_body "$TEMPLATE_DIR/refactor-10-extract-config-loader.md" "10"
fix_issue_body "$TEMPLATE_DIR/refactor-11-extract-artifact-manager.md" "11"
fix_issue_body "$TEMPLATE_DIR/refactor-12-extract-output-handler.md" "12"
fix_issue_body "$TEMPLATE_DIR/refactor-13-refactor-main-script.md" "13"

# Phase 4
fix_issue_body "$TEMPLATE_DIR/refactor-14-encapsulate-global-state.md" "14"

# Phase 5
fix_issue_body "$TEMPLATE_DIR/refactor-15-consolidate-artifact-retention.md" "15"

# Phase 6
fix_issue_body "$TEMPLATE_DIR/refactor-16-improve-error-handling.md" "16"
fix_issue_body "$TEMPLATE_DIR/refactor-17-extract-constants.md" "17"
fix_issue_body "$TEMPLATE_DIR/refactor-18-reduce-code-duplication.md" "18"

echo ""
echo "Done! Fixed all issue bodies."


















