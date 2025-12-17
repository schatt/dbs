---
name: Refactor 04 - Split BuildUtils - Node Creation
about: Extract node creation and registration logic from BuildUtils into BuildUtils::NodeCreation
title: '[Refactor] Split BuildUtils - Extract Node Creation module'
labels: 'refactor, high-priority, phase-2'
assignees: ''
---

## Goal
Extract node creation and registration functions from `BuildUtils.pm` into a focused `BuildUtils::NodeCreation` module.

## Current State
- `BuildUtils.pm` is 3165 lines - too large
- Node creation functions mixed with other utilities
- Functions: `build_and_register_node()`, `create_node()`, `get_or_create_node()`

## Target State
- New `BuildUtils/NodeCreation.pm` module
- Contains all node creation and registration logic
- Clear, focused API
- Maintains backward compatibility via BuildUtils exports

## Implementation Steps

1. **Create BuildUtils/NodeCreation.pm**
   - Create module directory structure
   - Define package namespace
   - Set up exports

2. **Move node creation functions**
   - Move `build_and_register_node()`
   - Move `create_node()` (if in BuildUtils)
   - Move `get_or_create_node()`
   - Move related helper functions

3. **Update BuildUtils.pm**
   - Remove moved functions
   - Re-export from NodeCreation for backward compatibility
   - Update @EXPORT_OK list

4. **Update imports in build.pl**
   - Import from BuildUtils::NodeCreation if needed
   - Or continue using BuildUtils (via re-exports)

5. **Add tests**
   - Test node creation functions
   - Test registration logic
   - Test edge cases

## Files to Modify
- `Scripts/BuildUtils.pm` - Remove node creation functions
- `Scripts/BuildUtils/NodeCreation.pm` - New file
- `Scripts/build.pl` - Update imports if needed

## Dependencies
- None (can be done independently)

## Acceptance Criteria
- [ ] BuildUtils::NodeCreation.pm created
- [ ] All node creation functions moved
- [ ] Backward compatibility maintained via re-exports
- [ ] Tests added/updated
- [ ] No regression in functionality
- [ ] Code review completed

## Estimated Effort
1 day

## Related Issues
- Part of Phase 2 refactoring
- Related to: Refactor 05, 06, 07, 08
