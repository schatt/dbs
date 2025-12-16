---
name: Refactor 01 - Extract Execution Engine
about: Extract the main execution loop into a dedicated BuildExecutionEngine class
title: '[Refactor] Extract Execution Engine into BuildExecutionEngine class'
labels: 'refactor, high-priority, phase-1'
assignees: ''
---

## Goal
Extract the main execution loop and phase coordination logic from `build.pl` into a dedicated `BuildExecutionEngine` class to improve testability, maintainability, and separation of concerns.

## Current State
- Main execution loop is in `build.pl` (lines ~2600-2834)
- Three-phase execution system (coordination, preparation, execution) is embedded in the main script
- Global state is used throughout (`$REGISTRY`, `$STATUS_MANAGER`, queue arrays)
- Difficult to test in isolation

## Target State
- New `BuildExecutionEngine.pm` module
- Encapsulates execution loop and phase logic
- Accepts dependencies via constructor (registry, status manager, queues)
- Clear public API: `execute()` method
- Testable in isolation

## Implementation Steps

1. **Create BuildExecutionEngine.pm**
   - Create new module file
   - Define class structure with constructor
   - Move phase functions: `phase1_coordination()`, `phase2_execution_preparation()`, `phase3_actual_execution()`

2. **Extract execution loop**
   - Move main while loop from `execute_build_nodes()` into `BuildExecutionEngine::execute()`
   - Move loop condition checking
   - Move progress tracking logic

3. **Refactor phase methods**
   - Extract `phase1_coordination()` from `build.pl`
   - Extract `phase2_execution_preparation()` from `build.pl`
   - Extract `phase3_actual_execution()` from `build.pl`
   - Make them methods of BuildExecutionEngine

4. **Update build.pl**
   - Replace `execute_build_nodes()` implementation
   - Instantiate BuildExecutionEngine
   - Call `execute()` method
   - Maintain backward compatibility

5. **Add tests**
   - Unit tests for each phase method
   - Integration tests for full execution
   - Test edge cases (no progress, max iterations)

## Files to Modify
- `Scripts/build.pl` - Remove execution logic, use BuildExecutionEngine
- `Scripts/BuildExecutionEngine.pm` - New file

## Dependencies
- None (this is the first refactoring step)

## Acceptance Criteria
- [ ] BuildExecutionEngine.pm created with clear API
- [ ] All execution logic moved from build.pl
- [ ] Existing functionality preserved
- [ ] Tests added for execution engine
- [ ] No regression in build behavior
- [ ] Code review completed

## Estimated Effort
2-3 days

## Related Issues
- Part of Phase 1 refactoring
- Blocks: Refactor 02, Refactor 03
