---
name: Refactor 17 - Extract Constants
about: Extract magic numbers and strings into constants
title: '[Refactor] Extract magic numbers and strings into BuildConstants'
labels: 'refactor, lower-priority, phase-6'
assignees: ''
---

## Goal
Extract magic numbers, strings, and configuration values into a `BuildConstants` module for better maintainability.

## Current State
- Magic numbers scattered throughout code
- Status strings hardcoded
- Configuration values inline
- Difficult to change defaults

## Target State
- `BuildConstants.pm` module
- All constants defined in one place
- Easy to modify
- Well documented

## Implementation Steps

1. **Create BuildConstants.pm**
   - Create new module file
   - Define constant structure
   - Document each constant

2. **Identify constants**
   - Find magic numbers (e.g., `MAX_ITERATIONS_MULTIPLIER => 2`)
   - Find status strings (`'pending'`, `'ready'`, `'done'`, etc.)
   - Find configuration defaults
   - Find threshold values

3. **Extract constants**
   - Move to BuildConstants
   - Use constants throughout code
   - Update references

4. **Add documentation**
   - Document each constant
   - Explain purpose
   - Note usage

5. **Add tests**
   - Test constant values
   - Test constant usage

## Files to Modify
- All files with magic numbers/strings
- `Scripts/BuildConstants.pm` - New file

## Dependencies
- None (can be done independently)

## Acceptance Criteria
- [ ] BuildConstants.pm created
- [ ] All magic numbers extracted
- [ ] All status strings extracted
- [ ] Constants documented
- [ ] Tests added
- [ ] No regression in behavior
- [ ] Code review completed

## Estimated Effort
1 day

## Related Issues
- Part of Phase 6 refactoring
- Related to: Refactor 16, 18
