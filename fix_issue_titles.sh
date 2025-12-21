#!/bin/bash

# Script to fix the titles of all refactoring issues

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/.github/ISSUE_TEMPLATE"

# Function to extract and update issue title
fix_issue_title() {
    local template_file="$1"
    local issue_num="$2"
    
    if [ ! -f "$template_file" ]; then
        echo "Warning: Template file not found: $template_file"
        return 1
    fi
    
    # Extract title from template (title is on the same line as "title:")
    local title=$(grep "^title:" "$template_file" | sed 's/^title: //' | sed "s/^'//" | sed "s/'$//")
    
    if [ -z "$title" ]; then
        echo "Warning: Could not extract title from $template_file"
        return 1
    fi
    
    echo "Updating issue #$issue_num: $title"
    
    # Update issue title
    gh issue edit "$issue_num" --title "$title"
    
    if [ $? -eq 0 ]; then
        echo "✓ Updated issue #$issue_num"
    else
        echo "✗ Failed to update issue #$issue_num"
        return 1
    fi
}

# Main execution
echo "Fixing issue titles..."
echo ""

# Phase 1
fix_issue_title "$TEMPLATE_DIR/refactor-01-extract-execution-engine.md" "1"
fix_issue_title "$TEMPLATE_DIR/refactor-02-extract-phase-methods.md" "2"
fix_issue_title "$TEMPLATE_DIR/refactor-03-extract-command-executor.md" "3"

# Phase 2
fix_issue_title "$TEMPLATE_DIR/refactor-04-split-buildutils-node.md" "4"
fix_issue_title "$TEMPLATE_DIR/refactor-05-split-buildutils-graph.md" "5"
fix_issue_title "$TEMPLATE_DIR/refactor-06-split-buildutils-display.md" "6"
fix_issue_title "$TEMPLATE_DIR/refactor-07-split-buildutils-queue.md" "7"
fix_issue_title "$TEMPLATE_DIR/refactor-08-split-buildutils-config.md" "8"

# Phase 3
fix_issue_title "$TEMPLATE_DIR/refactor-09-extract-cli-handler.md" "9"
fix_issue_title "$TEMPLATE_DIR/refactor-10-extract-config-loader.md" "10"
fix_issue_title "$TEMPLATE_DIR/refactor-11-extract-artifact-manager.md" "11"
fix_issue_title "$TEMPLATE_DIR/refactor-12-extract-output-handler.md" "12"
fix_issue_title "$TEMPLATE_DIR/refactor-13-refactor-main-script.md" "13"

# Phase 4
fix_issue_title "$TEMPLATE_DIR/refactor-14-encapsulate-global-state.md" "14"

# Phase 5
fix_issue_title "$TEMPLATE_DIR/refactor-15-consolidate-artifact-retention.md" "15"

# Phase 6
fix_issue_title "$TEMPLATE_DIR/refactor-16-improve-error-handling.md" "16"
fix_issue_title "$TEMPLATE_DIR/refactor-17-extract-constants.md" "17"
fix_issue_title "$TEMPLATE_DIR/refactor-18-reduce-code-duplication.md" "18"

echo ""
echo "Done! Fixed all issue titles."


















