---
name: Refactor 15 - Consolidate Artifact Retention
about: Refactor artifact retention using strategy pattern (if not done in Refactor 11)
title: '[Refactor] Consolidate artifact retention strategies using Strategy pattern'
labels: 'refactor, medium-priority, phase-5'
assignees: ''
---

## Goal
Consolidate the three artifact retention strategies (simple, hierarchical, bucketed) into a clean strategy pattern implementation.

## Current State
- Three separate cleanup functions
- `cleanup_simple_retention()`
- `cleanup_hierarchical_retention()`
- `cleanup_bucketed_retention()`
- Similar code patterns

## Target State
- Strategy pattern implementation
- Base `BuildArtifacts::Retention` class
- Concrete strategy classes
- Clean, extensible design

## Implementation Steps

1. **Create base retention class**
   - `BuildArtifacts::Retention::Base`
   - Define interface
   - Common functionality

2. **Create strategy classes**
   - `BuildArtifacts::Retention::Simple`
   - `BuildArtifacts::Retention::Hierarchical`
   - `BuildArtifacts::Retention::Bucketed`
   - Each implements cleanup interface

3. **Create retention factory**
   - `BuildArtifacts::Retention::Factory`
   - Selects strategy based on config
   - Returns appropriate instance

4. **Update BuildArtifacts**
   - Use factory to get strategy
   - Call strategy cleanup method
   - Remove old cleanup functions

5. **Add tests**
   - Test each strategy
   - Test factory selection
   - Test edge cases

## Files to Modify
- `Scripts/BuildArtifacts.pm` - Use strategy pattern
- `Scripts/BuildArtifacts/Retention/Base.pm` - New file
- `Scripts/BuildArtifacts/Retention/Simple.pm` - New or update
- `Scripts/BuildArtifacts/Retention/Hierarchical.pm` - New or update
- `Scripts/BuildArtifacts/Retention/Bucketed.pm` - New or update
- `Scripts/BuildArtifacts/Retention/Factory.pm` - New file

## Dependencies
- Requires: Refactor 11 (BuildArtifacts must exist)
- May be done as part of Refactor 11

## Acceptance Criteria
- [ ] Strategy pattern implemented
- [ ] Base class created
- [ ] All strategies implemented
- [ ] Factory created
- [ ] Tests added
- [ ] No regression in retention behavior
- [ ] Code review completed

## Estimated Effort
1-2 days

## Related Issues
- Part of Phase 5 refactoring
- May be combined with: Refactor 11
