---
name: Refactor 02 - Extract Phase Methods
about: Extract phase coordination methods from build.pl into BuildExecutionEngine
title: '[Refactor] Extract phase methods (phase1, phase2, phase3) into BuildExecutionEngine'
labels: 'refactor, high-priority, phase-1'
assignees: ''
---

## Goal
Extract the three phase methods (`phase1_coordination`, `phase2_execution_preparation`, `phase3_actual_execution`) from `build.pl` into the `BuildExecutionEngine` class.

## Current State
- Phase methods are defined in `build.pl` as standalone functions
- They access global state directly
- Logic is mixed with main script concerns

## Target State
- Phase methods are private methods of `BuildExecutionEngine`
- They receive necessary dependencies via instance variables
- Clear separation of concerns

## Implementation Steps

1. **Extract phase1_coordination()**
   - Move function from build.pl to BuildExecutionEngine
   - Convert to private method `_phase1_coordination()`
   - Update to use instance variables instead of globals

2. **Extract phase2_execution_preparation()**
   - Move function from build.pl to BuildExecutionEngine
   - Convert to private method `_phase2_execution_preparation()`
   - Update to use instance variables instead of globals

3. **Extract phase3_actual_execution()**
   - Move function from build.pl to BuildExecutionEngine
   - Convert to private method `_phase3_actual_execution()`
   - Update to use instance variables instead of globals
   - Extract command execution logic if needed

4. **Update BuildExecutionEngine::execute()**
   - Call phase methods in sequence
   - Handle return values (node counts)
   - Maintain existing loop structure

5. **Update build.pl**
   - Remove phase function definitions
   - Ensure BuildExecutionEngine is used correctly

## Files to Modify
- `Scripts/build.pl` - Remove phase function definitions
- `Scripts/BuildExecutionEngine.pm` - Add phase methods

## Dependencies
- Requires: Refactor 01 (BuildExecutionEngine class must exist)

## Acceptance Criteria
- [ ] All three phase methods extracted to BuildExecutionEngine
- [ ] Methods are private (prefixed with `_`)
- [ ] No global state access in phase methods
- [ ] Existing functionality preserved
- [ ] Tests updated/added for phase methods
- [ ] Code review completed

## Estimated Effort
1-2 days

## Related Issues
- Depends on: Refactor 01
- Part of Phase 1 refactoring
