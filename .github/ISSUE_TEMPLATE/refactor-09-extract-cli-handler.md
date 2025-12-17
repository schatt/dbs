---
name: Refactor 09 - Extract CLI Handler
about: Extract CLI parsing and argument handling from build.pl into BuildCLI module
title: '[Refactor] Extract CLI parsing into BuildCLI module'
labels: 'refactor, high-priority, phase-3'
assignees: ''
---

## Goal
Extract command-line interface parsing, validation, and help text from `build.pl` into a dedicated `BuildCLI` module.

## Current State
- CLI parsing in build.pl (lines ~240-404)
- GetOptions call with many options
- Help text embedded in script
- Argument validation mixed with parsing

## Target State
- New `BuildCLI.pm` module
- Encapsulates all CLI concerns
- Returns structured options hash
- Clear separation from main script

## Implementation Steps

1. **Create BuildCLI.pm**
   - Create new module file
   - Define class structure
   - Set up option definitions

2. **Extract option definitions**
   - Move GetOptions configuration
   - Define option metadata
   - Create option validation

3. **Extract help text**
   - Move help text to BuildCLI
   - Format as method
   - Add version info method

4. **Extract argument validation**
   - Move mutual exclusivity checks
   - Move implied flag logic
   - Move unused argument warnings

5. **Update build.pl**
   - Use BuildCLI to parse arguments
   - Get options hash
   - Simplify main script

6. **Add tests**
   - Test option parsing
   - Test validation
   - Test help output

## Files to Modify
- `Scripts/build.pl` - Remove CLI code, use BuildCLI
- `Scripts/BuildCLI.pm` - New file

## Dependencies
- None (can be done independently)

## Acceptance Criteria
- [ ] BuildCLI.pm created
- [ ] All CLI parsing moved
- [ ] Help text extracted
- [ ] Validation logic extracted
- [ ] Tests added
- [ ] No regression in CLI behavior
- [ ] Code review completed

## Estimated Effort
1 day

## Related Issues
- Part of Phase 3 refactoring
- Related to: Refactor 10, 11, 12, 13
