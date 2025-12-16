---
name: Refactor 13 - Refactor Main Script
about: Simplify build.pl to be a thin orchestration layer after extracting modules
title: '[Refactor] Simplify build.pl to thin orchestration layer'
labels: 'refactor, high-priority, phase-3'
assignees: ''
---

## Goal
After extracting major components, simplify `build.pl` to be a thin orchestration layer that coordinates the extracted modules.

## Current State
- build.pl is 3635 lines
- Contains mixed concerns (CLI, config, execution, artifacts, output)
- Difficult to understand flow

## Target State
- build.pl is <500 lines
- Clear orchestration flow
- Uses extracted modules
- Easy to understand main execution path

## Implementation Steps

1. **Review current build.pl**
   - Identify remaining inline code
   - Identify code that should be extracted
   - Plan final structure

2. **Extract remaining utilities**
   - Move any remaining utility functions
   - Move helper functions to appropriate modules
   - Clean up global variable usage

3. **Simplify main execution flow**
   - Create clear main() function or top-level flow
   - Use extracted modules
   - Remove duplicate code

4. **Update module integration**
   - Ensure all modules work together
   - Fix any integration issues
   - Update error handling

5. **Clean up**
   - Remove commented code
   - Remove dead code
   - Improve documentation
   - Add inline comments for flow

6. **Add tests**
   - Integration tests for main flow
   - Test error paths
   - Test different execution modes

## Files to Modify
- `Scripts/build.pl` - Major simplification
- All extracted modules - Ensure integration works

## Dependencies
- Requires: Refactor 09, 10, 11, 12 (all Phase 3 extractions)
- Benefits from: All previous refactorings

## Acceptance Criteria
- [ ] build.pl reduced to <500 lines
- [ ] Clear orchestration flow
- [ ] All functionality preserved
- [ ] Integration tests pass
- [ ] No regression in behavior
- [ ] Code review completed

## Estimated Effort
2 days

## Related Issues
- Depends on: Refactor 09, 10, 11, 12
- Part of Phase 3 refactoring
- Final step of Phase 3
