---
name: Refactor 08 - Split BuildUtils - Config Processing
about: Extract config processing functions from BuildUtils into BuildUtils::ConfigProcessing
title: '[Refactor] Split BuildUtils - Extract Config Processing module'
labels: 'refactor, high-priority, phase-2'
assignees: ''
---

## Goal
Extract configuration extraction, merging, and processing functions from `BuildUtils.pm` into a focused `BuildUtils::ConfigProcessing` module.

## Current State
- Config functions mixed in BuildUtils.pm
- Functions: `load_config_entry()`, `extract_target_info()`, `apply_category_defaults()`, `merge_args()`, etc.

## Target State
- New `BuildUtils/ConfigProcessing.pm` module
- Contains all config processing logic
- Clear API for config operations

## Implementation Steps

1. **Create BuildUtils/ConfigProcessing.pm**
   - Create module file
   - Define package namespace
   - Set up exports

2. **Move config functions**
   - Move `load_config_entry()`
   - Move `extract_target_info()`
   - Move `apply_category_defaults()`
   - Move `extract_category_defaults()`
   - Move `extract_all_category_defaults()`
   - Move `merge_args()` (or keep in main BuildUtils if widely used)
   - Move related helper functions

3. **Update BuildUtils.pm**
   - Remove moved functions
   - Re-export from ConfigProcessing for backward compatibility

4. **Update imports**
   - Update build.pl
   - Update other modules if needed

5. **Add tests**
   - Test config loading
   - Test config merging
   - Test default application
   - Test edge cases

## Files to Modify
- `Scripts/BuildUtils.pm` - Remove config functions
- `Scripts/BuildUtils/ConfigProcessing.pm` - New file
- `Scripts/build.pl` - Update imports if needed

## Dependencies
- None (can be done independently)

## Acceptance Criteria
- [ ] BuildUtils::ConfigProcessing.pm created
- [ ] All config processing functions moved
- [ ] Backward compatibility maintained
- [ ] Tests added/updated
- [ ] No regression in config processing
- [ ] Code review completed

## Estimated Effort
1 day

## Related Issues
- Part of Phase 2 refactoring
- Related to: Refactor 04, 05, 06, 07
