---
name: Refactor 11 - Extract Artifact Manager
about: Extract artifact collection, archiving, and cleanup from build.pl into BuildArtifacts module
title: '[Refactor] Extract artifact management into BuildArtifacts module'
labels: 'refactor, high-priority, phase-3'
assignees: ''
---

## Goal
Extract artifact collection, archiving, and cleanup logic from `build.pl` into a dedicated `BuildArtifacts` module.

## Current State
- Artifact functions in build.pl (lines ~829-1029)
- Multiple cleanup strategies (simple, hierarchical, bucketed)
- Collection and archiving logic mixed

## Target State
- New `BuildArtifacts.pm` module
- Handles all artifact concerns
- Strategy pattern for retention policies
- Clear API

## Implementation Steps

1. **Create BuildArtifacts.pm**
   - Create new module file
   - Define class structure
   - Set up artifact operations

2. **Extract collection functions**
   - Move `collect_artifacts_for_platform()`
   - Move artifact pattern matching
   - Move file collection logic

3. **Extract archiving functions**
   - Move `archive_artifacts_for_platform()`
   - Move archive creation
   - Move archive naming

4. **Extract cleanup functions**
   - Move `cleanup_old_artifacts_for_platform()`
   - Move retention policy parsing
   - Create strategy classes for retention:
     - `BuildArtifacts::Retention::Simple`
     - `BuildArtifacts::Retention::Hierarchical`
     - `BuildArtifacts::Retention::Bucketed`

5. **Update build.pl**
   - Use BuildArtifacts for artifact operations
   - Simplify main script

6. **Add tests**
   - Test artifact collection
   - Test archiving
   - Test cleanup strategies
   - Test edge cases

## Files to Modify
- `Scripts/build.pl` - Remove artifact code, use BuildArtifacts
- `Scripts/BuildArtifacts.pm` - New file
- `Scripts/BuildArtifacts/Retention/Simple.pm` - New file
- `Scripts/BuildArtifacts/Retention/Hierarchical.pm` - New file
- `Scripts/BuildArtifacts/Retention/Bucketed.pm` - New file

## Dependencies
- None (can be done independently)

## Acceptance Criteria
- [ ] BuildArtifacts.pm created
- [ ] All artifact functions moved
- [ ] Retention strategies implemented
- [ ] Tests added
- [ ] No regression in artifact handling
- [ ] Code review completed

## Estimated Effort
2 days

## Related Issues
- Part of Phase 3 refactoring
- Related to: Refactor 09, 10, 12, 13
