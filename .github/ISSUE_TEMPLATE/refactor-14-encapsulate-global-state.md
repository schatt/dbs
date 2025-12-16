---
name: Refactor 14 - Encapsulate Global State
about: Replace global variables with BuildContext class
title: '[Refactor] Encapsulate global state into BuildContext class'
labels: 'refactor, medium-priority, phase-4'
assignees: ''
---

## Goal
Replace global variables (`$REGISTRY`, `$STATUS_MANAGER`, queue arrays, etc.) with a `BuildContext` class that encapsulates all execution state.

## Current State
- Many global variables in build.pl
- `$REGISTRY`, `$STATUS_MANAGER`, `@READY_QUEUE_NODES`, etc.
- State passed implicitly via globals
- Difficult to test with multiple contexts

## Target State
- New `BuildContext.pm` class
- Encapsulates all execution state
- Passed explicitly to functions/methods
- Supports multiple concurrent contexts

## Implementation Steps

1. **Create BuildContext.pm**
   - Create new module file
   - Define class structure
   - Add accessors for all state

2. **Identify all global state**
   - List all global variables
   - Categorize by purpose
   - Plan encapsulation

3. **Move state to BuildContext**
   - Add registry to context
   - Add status manager to context
   - Add queue arrays to context
   - Add other global state

4. **Update modules to accept context**
   - Update BuildExecutionEngine to accept context
   - Update BuildCommandExecutor to accept context
   - Update other modules as needed

5. **Update build.pl**
   - Create BuildContext instance
   - Pass context to modules
   - Remove global variable declarations

6. **Add tests**
   - Test context creation
   - Test context isolation
   - Test concurrent contexts

## Files to Modify
- `Scripts/build.pl` - Use BuildContext, remove globals
- `Scripts/BuildContext.pm` - New file
- `Scripts/BuildExecutionEngine.pm` - Accept context
- `Scripts/BuildCommandExecutor.pm` - Accept context
- Other modules as needed

## Dependencies
- Requires: Refactor 01, 02, 03 (execution engine must exist)
- Benefits from: All Phase 1-3 refactorings

## Acceptance Criteria
- [ ] BuildContext.pm created
- [ ] All global state encapsulated
- [ ] Context passed explicitly
- [ ] No global variable usage
- [ ] Tests added
- [ ] No regression in behavior
- [ ] Code review completed

## Estimated Effort
2 days

## Related Issues
- Part of Phase 4 refactoring
- Depends on: Refactor 01, 02, 03
