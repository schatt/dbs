---
name: Refactor 03 - Extract Command Executor
about: Extract command execution logic into a dedicated CommandExecutor class
title: '[Refactor] Extract command execution logic into BuildCommandExecutor class'
labels: 'refactor, high-priority, phase-1'
assignees: ''
---

## Goal
Extract command execution, logging, and result tracking logic from `phase3_actual_execution()` into a dedicated `BuildCommandExecutor` class.

## Current State
- Command execution logic is embedded in `phase3_actual_execution()` (lines ~2500-2554)
- Handles logging, verbosity, result tracking inline
- Code duplication for command logging
- Difficult to test command execution in isolation

## Target State
- New `BuildCommandExecutor.pm` module
- Handles all command execution concerns
- Supports different verbosity levels
- Comprehensive logging
- Testable in isolation

## Implementation Steps

1. **Create BuildCommandExecutor.pm**
   - Create new module file
   - Define class structure
   - Accept options via constructor (verbosity, log directory, etc.)

2. **Extract command execution**
   - Move command execution logic from phase3
   - Handle quiet/normal/verbose/debug modes
   - Implement tee functionality for output

3. **Extract logging logic**
   - Move command log file writing
   - Move result logging
   - Centralize log file path generation

4. **Update phase3_actual_execution()**
   - Use BuildCommandExecutor instead of inline execution
   - Simplify phase3 method
   - Pass necessary context to executor

5. **Add tests**
   - Test command execution with different verbosity levels
   - Test logging behavior
   - Test error handling

## Files to Modify
- `Scripts/BuildExecutionEngine.pm` - Update phase3 to use CommandExecutor
- `Scripts/BuildCommandExecutor.pm` - New file

## Dependencies
- Requires: Refactor 02 (phase3 must be extracted first)

## Acceptance Criteria
- [ ] BuildCommandExecutor.pm created
- [ ] All command execution logic moved from phase3
- [ ] Logging centralized in CommandExecutor
- [ ] Supports all verbosity levels
- [ ] Tests added for command execution
- [ ] No regression in execution behavior
- [ ] Code review completed

## Estimated Effort
1-2 days

## Related Issues
- Depends on: Refactor 02
- Part of Phase 1 refactoring
