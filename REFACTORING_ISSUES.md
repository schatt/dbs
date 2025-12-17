# Refactoring Issues Summary

This document lists all GitHub issues for the refactoring plan. Each issue can be created from the templates in `.github/ISSUE_TEMPLATE/`.

## Phase 1: Execution Engine Extraction (High Priority)

### Issue #1: Extract Execution Engine
**Template**: `refactor-01-extract-execution-engine.md`
**Priority**: High
**Effort**: 2-3 days
**Dependencies**: None
**Blocks**: #2, #3

Extract the main execution loop into a dedicated `BuildExecutionEngine` class.

### Issue #2: Extract Phase Methods
**Template**: `refactor-02-extract-phase-methods.md`
**Priority**: High
**Effort**: 1-2 days
**Dependencies**: #1
**Blocks**: #3

Extract the three phase methods (phase1, phase2, phase3) into BuildExecutionEngine.

### Issue #3: Extract Command Executor
**Template**: `refactor-03-extract-command-executor.md`
**Priority**: High
**Effort**: 1-2 days
**Dependencies**: #2
**Blocks**: None

Extract command execution logic into a dedicated `BuildCommandExecutor` class.

## Phase 2: BuildUtils Modularization (High Priority)

### Issue #4: Split BuildUtils - Node Creation
**Template**: `refactor-04-split-buildutils-node.md`
**Priority**: High
**Effort**: 1 day
**Dependencies**: None
**Blocks**: None

Extract node creation and registration logic into `BuildUtils::NodeCreation`.

### Issue #5: Split BuildUtils - Graph Building
**Template**: `refactor-05-split-buildutils-graph.md`
**Priority**: High
**Effort**: 1 day
**Dependencies**: None
**Blocks**: None

Extract graph construction logic into `BuildUtils::GraphBuilding`.

### Issue #6: Split BuildUtils - Display
**Template**: `refactor-06-split-buildutils-display.md`
**Priority**: High
**Effort**: 1 day
**Dependencies**: None
**Blocks**: None

Extract display and formatting functions into `BuildUtils::Display`.

### Issue #7: Split BuildUtils - Queue Management
**Template**: `refactor-07-split-buildutils-queue.md`
**Priority**: High
**Effort**: 1 day
**Dependencies**: None
**Blocks**: None

Extract queue management functions into `BuildUtils::QueueManagement`.

### Issue #8: Split BuildUtils - Config Processing
**Template**: `refactor-08-split-buildutils-config.md`
**Priority**: High
**Effort**: 1 day
**Dependencies**: None
**Blocks**: None

Extract config processing functions into `BuildUtils::ConfigProcessing`.

## Phase 3: build.pl Decomposition (High Priority)

### Issue #9: Extract CLI Handler
**Template**: `refactor-09-extract-cli-handler.md`
**Priority**: High
**Effort**: 1 day
**Dependencies**: None
**Blocks**: #13

Extract CLI parsing into `BuildCLI` module.

### Issue #10: Extract Config Loader
**Template**: `refactor-10-extract-config-loader.md`
**Priority**: High
**Effort**: 1-2 days
**Dependencies**: None
**Blocks**: #13

Extract config loading into `BuildConfig` module.

### Issue #11: Extract Artifact Manager
**Template**: `refactor-11-extract-artifact-manager.md`
**Priority**: High
**Effort**: 2 days
**Dependencies**: None
**Blocks**: #13, #15

Extract artifact management into `BuildArtifacts` module.

### Issue #12: Extract Output Handler
**Template**: `refactor-12-extract-output-handler.md`
**Priority**: High
**Effort**: 1-2 days
**Dependencies**: None (benefits from #6)
**Blocks**: #13

Extract output handling into `BuildOutput` module.

### Issue #13: Refactor Main Script
**Template**: `refactor-13-refactor-main-script.md`
**Priority**: High
**Effort**: 2 days
**Dependencies**: #9, #10, #11, #12
**Blocks**: None

Simplify build.pl to be a thin orchestration layer.

## Phase 4: Global State Reduction (Medium Priority)

### Issue #14: Encapsulate Global State
**Template**: `refactor-14-encapsulate-global-state.md`
**Priority**: Medium
**Effort**: 2 days
**Dependencies**: #1, #2, #3
**Blocks**: None

Replace global variables with `BuildContext` class.

## Phase 5: Artifact Management Consolidation (Medium Priority)

### Issue #15: Consolidate Artifact Retention
**Template**: `refactor-15-consolidate-artifact-retention.md`
**Priority**: Medium
**Effort**: 1-2 days
**Dependencies**: #11
**Blocks**: None

Refactor artifact retention using strategy pattern (may be done as part of #11).

## Phase 6: Code Quality Improvements (Lower Priority)

### Issue #16: Improve Error Handling
**Template**: `refactor-16-improve-error-handling.md`
**Priority**: Lower
**Effort**: 2 days
**Dependencies**: None
**Blocks**: None

Replace die statements with exception classes.

### Issue #17: Extract Constants
**Template**: `refactor-17-extract-constants.md`
**Priority**: Lower
**Effort**: 1 day
**Dependencies**: None
**Blocks**: None

Extract magic numbers and strings into `BuildConstants`.

### Issue #18: Reduce Code Duplication
**Template**: `refactor-18-reduce-code-duplication.md`
**Priority**: Lower
**Effort**: 1-2 days
**Dependencies**: None
**Blocks**: None

Identify and eliminate code duplication.

## Issue Creation

To create these issues on GitHub, you can:

1. **Manual**: Copy the content from each template file in `.github/ISSUE_TEMPLATE/` and create issues manually
2. **GitHub CLI**: Use `gh issue create` with the template files
3. **Script**: Use the provided `create_refactoring_issues.sh` script

## Execution Order

### Recommended Sequence

**Week 1**: Phase 1
- #1 → #2 → #3

**Week 2**: Phase 2 (can be done in parallel)
- #4, #5, #6, #7, #8 (all independent)

**Week 3-4**: Phase 3
- #9, #10, #11, #12 (can be done in parallel)
- #13 (requires #9, #10, #11, #12)

**Week 5**: Phase 4
- #14 (requires #1, #2, #3)

**Week 6**: Phase 5
- #15 (requires #11)

**Week 7**: Phase 6 (can be done in parallel)
- #16, #17, #18 (all independent)

## Notes

- Issues in the same phase can often be worked on in parallel
- Each issue should be completed and tested before moving to dependent issues
- Maintain backward compatibility throughout
- Add tests for each refactoring
