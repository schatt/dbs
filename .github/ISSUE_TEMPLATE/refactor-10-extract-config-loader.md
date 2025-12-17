---
name: Refactor 10 - Extract Config Loader
about: Extract configuration loading and validation from build.pl into BuildConfig module
title: '[Refactor] Extract config loading into BuildConfig module'
labels: 'refactor, high-priority, phase-3'
assignees: ''
---

## Goal
Extract configuration file loading, parsing, validation, and normalization from `build.pl` into a dedicated `BuildConfig` module.

## Current State
- Config loading in `load_config()` function (line ~414)
- Config validation in `validate_config()` (line ~1138)
- Path normalization mixed with loading
- YAML parsing inline

## Target State
- New `BuildConfig.pm` module
- Handles all config concerns
- Clear API: `load()`, `validate()`, `normalize()`
- Testable in isolation

## Implementation Steps

1. **Create BuildConfig.pm**
   - Create new module file
   - Define class structure
   - Set up YAML loading

2. **Extract load_config()**
   - Move function to BuildConfig::load()
   - Handle YAML parsing
   - Handle path normalization
   - Return config hash

3. **Extract validate_config()**
   - Move function to BuildConfig::validate()
   - Keep validation logic
   - Return validation results

4. **Extract config normalization**
   - Move path normalization
   - Move artifact directory processing
   - Move notification normalization

5. **Update build.pl**
   - Use BuildConfig to load config
   - Use BuildConfig to validate
   - Simplify main script

6. **Add tests**
   - Test config loading
   - Test validation
   - Test normalization
   - Test error cases

## Files to Modify
- `Scripts/build.pl` - Remove config code, use BuildConfig
- `Scripts/BuildConfig.pm` - New file

## Dependencies
- None (can be done independently)

## Acceptance Criteria
- [ ] BuildConfig.pm created
- [ ] All config loading moved
- [ ] Validation extracted
- [ ] Normalization extracted
- [ ] Tests added
- [ ] No regression in config handling
- [ ] Code review completed

## Estimated Effort
1-2 days

## Related Issues
- Part of Phase 3 refactoring
- Related to: Refactor 09, 11, 12, 13
