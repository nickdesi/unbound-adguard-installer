---
description: Systematically audit code for vulnerabilities.
---

# Security Audit Workflow

Use this workflow to identify and fix potential security vulnerabilities in the codebase.

## 1. Static Analysis (SAST)

**Action**: Run a static analysis tool on the codebase.

* **Python**: `pip install bandit && bandit -r .`
* **JavaScript/TypeScript**: `npm audit` or `npx eslint . --plugin security` (if configured)

## 2. Secrets Detection

**Action**: Check for committed secrets (API keys, tokens, passwords).

* **Manual**: Search for "key", "token", "password", "secret" in the codebase.
* **Tool**: `git grep -E "api_key|token|password|secret"`

## 3. Dependency Check

**Action**: specific check for vulnerable dependencies.

* **Python**: `pip list --outdated` (manual check against CVEs) or use `pip-audit`.
* **Node**: `npm audit`

## 4. Remediation

For each finding:

1. **Verify**: Confirm it is not a false positive.
2. **Fix**: Update dependency, rotate key, or patch code.
3. **Verify Fix**: Re-run the tool to confirm the issue is gone.
