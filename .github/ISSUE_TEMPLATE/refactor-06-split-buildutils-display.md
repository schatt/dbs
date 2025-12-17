---
name: Refactor 06 - Split BuildUtils - Display
about: Extract display and formatting functions from BuildUtils into BuildUtils::Display
title: '[Refactor] Split BuildUtils - Extract Display module'
labels: 'refactor, high-priority, phase-2'
assignees: ''
---

## Goal
Extract tree printing, formatting, and display functions from `BuildUtils.pm` into a focused `BuildUtils::Display` module.

## Current State
- Display functions mixed in BuildUtils.pm
- Functions: `print_node_tree()`, `print_enhanced_tree()`, `print_final_build_order()`, `format_node()`, etc.

## Target State
- New `BuildUtils/Display.pm` module
- Contains all display and formatting logic
- Clear API for tree/order display

## Implementation Steps

1. **Create BuildUtils/Display.pm**
   - Create module file
   - Define package namespace
   - Set up exports

2. **Move display functions**
   - Move `print_node_tree()`
   - Move `print_enhanced_tree()`
   - Move `print_final_build_order()`
   - Move `format_node()`
   - Move `print_build_order_legend()`
   - Move `is_empty_dependency_group()` (display-related)
   - Move related helper functions

3. **Update BuildUtils.pm**
   - Remove moved functions
   - Re-export from Display for backward compatibility

4. **Update imports**
   - Update build.pl
   - Update other modules if needed

5. **Add tests**
   - Test display functions
   - Test formatting
   - Test edge cases

## Files to Modify
- `Scripts/BuildUtils.pm` - Remove display functions
- `Scripts/BuildUtils/Display.pm` - New file
- `Scripts/build.pl` - Update imports

## Dependencies
- None (can be done independently)

## Acceptance Criteria
- [ ] BuildUtils::Display.pm created
- [ ] All display functions moved
- [ ] Backward compatibility maintained
- [ ] Tests added/updated
- [ ] No regression in display behavior
- [ ] Code review completed

## Estimated Effort
1 day

## Related Issues
- Part of Phase 2 refactoring
- Related to: Refactor 04, 05, 07, 08
