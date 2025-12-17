---
name: Refactor 05 - Split BuildUtils - Graph Building
about: Extract graph building logic from BuildUtils into BuildUtils::GraphBuilding
title: '[Refactor] Split BuildUtils - Extract Graph Building module'
labels: 'refactor, high-priority, phase-2'
assignees: ''
---

## Goal
Extract graph construction and worklist processing functions from `BuildUtils.pm` into a focused `BuildUtils::GraphBuilding` module.

## Current State
- Graph building functions mixed in BuildUtils.pm
- Functions: `build_graph_with_worklist()`, worklist processing, relationship handling

## Target State
- New `BuildUtils/GraphBuilding.pm` module
- Contains all graph construction logic
- Worklist processing
- Relationship processing

## Implementation Steps

1. **Create BuildUtils/GraphBuilding.pm**
   - Create module file
   - Define package namespace
   - Set up exports

2. **Move graph building functions**
   - Move `build_graph_with_worklist()`
   - Move worklist processing logic
   - Move `process_node_relationships_immediately()`
   - Move related helper functions

3. **Update BuildUtils.pm**
   - Remove moved functions
   - Re-export from GraphBuilding for backward compatibility

4. **Update imports**
   - Update build.pl if needed
   - Update other modules if needed

5. **Add tests**
   - Test graph building
   - Test worklist processing
   - Test relationship handling

## Files to Modify
- `Scripts/BuildUtils.pm` - Remove graph building functions
- `Scripts/BuildUtils/GraphBuilding.pm` - New file

## Dependencies
- None (can be done independently)

## Acceptance Criteria
- [ ] BuildUtils::GraphBuilding.pm created
- [ ] All graph building functions moved
- [ ] Backward compatibility maintained
- [ ] Tests added/updated
- [ ] No regression in functionality
- [ ] Code review completed

## Estimated Effort
1 day

## Related Issues
- Part of Phase 2 refactoring
- Related to: Refactor 04, 06, 07, 08
