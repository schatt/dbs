---
name: Refactor 07 - Split BuildUtils - Queue Management
about: Extract queue management functions from BuildUtils into BuildUtils::QueueManagement
title: '[Refactor] Split BuildUtils - Extract Queue Management module'
labels: 'refactor, high-priority, phase-2'
assignees: ''
---

## Goal
Extract queue management functions from `BuildUtils.pm` into a focused `BuildUtils::QueueManagement` module.

## Current State
- Queue functions mixed in BuildUtils.pm
- Functions: `add_to_ready_queue()`, `remove_from_ready_queue()`, `get_next_ready_node()`, etc.
- Many queue-related functions

## Target State
- New `BuildUtils/QueueManagement.pm` module
- Contains all queue operations
- Clear API for queue management

## Implementation Steps

1. **Create BuildUtils/QueueManagement.pm**
   - Create module file
   - Define package namespace
   - Set up exports

2. **Move queue functions**
   - Move all `add_to_*` functions
   - Move all `remove_from_*` functions
   - Move all `get_*` queue functions
   - Move all `has_*` queue functions
   - Move all `is_node_in_*` functions
   - Move queue size functions

3. **Update BuildUtils.pm**
   - Remove moved functions
   - Re-export from QueueManagement for backward compatibility

4. **Update imports**
   - Update build.pl
   - Update BuildExecutionEngine if it exists
   - Update other modules if needed

5. **Add tests**
   - Test queue operations
   - Test queue state management
   - Test edge cases

## Files to Modify
- `Scripts/BuildUtils.pm` - Remove queue functions
- `Scripts/BuildUtils/QueueManagement.pm` - New file
- `Scripts/build.pl` - Update imports
- `Scripts/BuildExecutionEngine.pm` - Update imports if exists

## Dependencies
- None (can be done independently)

## Acceptance Criteria
- [ ] BuildUtils::QueueManagement.pm created
- [ ] All queue functions moved
- [ ] Backward compatibility maintained
- [ ] Tests added/updated
- [ ] No regression in queue behavior
- [ ] Code review completed

## Estimated Effort
1 day

## Related Issues
- Part of Phase 2 refactoring
- Related to: Refactor 04, 05, 06, 08
