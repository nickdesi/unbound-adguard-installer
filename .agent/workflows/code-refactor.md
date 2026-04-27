---
description: Clean up technical debt without breaking functionality.
---

# Code Refactor Workflow

Use this workflow to improve code quality, readability, and maintainability.

## 1. Identify the Smell

**Target**: What specific file or function needs refactoring?
**Reason**: Why? (Too long, high complexity, duplicated logic, unclear naming).

## 2. Create Safety Net (Tests)

**CRITICAL**: Do NOT refactor without tests.

1. Run existing tests: `npm test` or `pytest`.
2. If no tests exist for the target, **create a characterization test** that captures the current behavior.
3. Verify the test passes.

## 3. Refactor

**Steps**:

1. Make small, incremental changes.
2. Run tests after EACH change.
3. **Refactoring Moves**:
    - Extract Method
    - Rename Variable/Method (for clarity)
    - Remove Dead Code
    - Simplify Conditionals

## 4. Verify

1. Run all tests.
2. Manual Spot Check: Ensure the application behavior is unchanged.
