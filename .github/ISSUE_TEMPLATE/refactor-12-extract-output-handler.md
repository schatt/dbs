---
name: Refactor 12 - Extract Output Handler
about: Extract output formatting and summary printing from build.pl into BuildOutput module
title: '[Refactor] Extract output handling into BuildOutput module'
labels: 'refactor, high-priority, phase-3'
assignees: ''
---

## Goal
Extract output formatting, summary printing, and execution order display from `build.pl` into a dedicated `BuildOutput` module.

## Current State
- Output functions in build.pl
- `print_build_summary()` (line ~2851)
- Execution order printing (line ~2958)
- Tree printing (uses BuildUtils, but orchestrated in build.pl)

## Target State
- New `BuildOutput.pm` module
- Handles all output concerns
- Clear API for different output types
- Separated from main script

## Implementation Steps

1. **Create BuildOutput.pm**
   - Create new module file
   - Define class structure
   - Set up output methods

2. **Extract summary printing**
   - Move `print_build_summary()`
   - Move summary statistics
   - Move status counting

3. **Extract execution order display**
   - Move execution order printing logic
   - Move filtering logic (empty dependency groups)
   - Move formatting

4. **Extract tree display orchestration**
   - Move tree printing calls
   - Coordinate with BuildUtils::Display
   - Handle display options

5. **Update build.pl**
   - Use BuildOutput for all output
   - Simplify main script

6. **Add tests**
   - Test summary output
   - Test execution order display
   - Test formatting
   - Test edge cases

## Files to Modify
- `Scripts/build.pl` - Remove output code, use BuildOutput
- `Scripts/BuildOutput.pm` - New file

## Dependencies
- May benefit from: Refactor 06 (Display module)

## Acceptance Criteria
- [ ] BuildOutput.pm created
- [ ] All output functions moved
- [ ] Summary printing extracted
- [ ] Execution order display extracted
- [ ] Tests added
- [ ] No regression in output behavior
- [ ] Code review completed

## Estimated Effort
1-2 days

## Related Issues
- Part of Phase 3 refactoring
- Related to: Refactor 09, 10, 11, 13
