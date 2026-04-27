---
description: Automate the release process (build, version bump, changelog, git tag).
---

# Release Manager Workflow

Use this workflow to ship a new version of the application cleanly and ensuring consistency across all files.

## 1. Pre-Flight Checks

1. **Git Status**: ensure working directory is clean.

    ```bash
    git status
    ```

2. **Branch**: ensure you are on `main` (or the correct release branch).

    ```bash
    git branch --show-current
    ```

## 2. Validation Build

Run a fresh build to ensure nothing is broken before tagging.

```bash
npm run build
```

* If this fails -> **STOP**. Fix the build first.

## 3. Version Bump Strategy

Determine the new version number (e.g., from `1.8.0` to `1.9.0`).

### 3.1. Update Version in Files

You MUST update the version string in **ALL** of the following locations:

1. **`package.json`**: Update the `"version"` field.
   * Run `npm install` afterwards to sync `package-lock.json`.
2. **`README.md`**: Update the Badge URL (e.g., `v1.8.0-GitHub` -> `v1.9.0-GitHub`).
3. **`components/Footer.tsx`**:
   * Update `APP_VERSION` constant.
   * Add new entry to `CHANGELOG` array array if applicable (although rarely displayed, keep it synced).
4. **`CHANGELOG.md`**: Add the new version header and date.

### 3.2. Verification

Run this command to ensure no "old version" strings remain (replace `1.8.0` with old version):

```bash
# Verify no leftover old version strings in tracked files
grep -r "1.8.0" . --exclude-dir=node_modules --exclude-dir=.git --exclude=package-lock.json
```

## 4. Changelog Update

1. Open `CHANGELOG.md`.
2. Add a new header: `## [X.Y.Z] - YYYY-MM-DD`.
3. Ensure all changes are categorized correctly (Added, Modified, Fixed).

## 5. Git Release

```bash
# Stage all version files
git add package.json package-lock.json README.md components/Footer.tsx CHANGELOG.md

# Commit
git commit -m "chore(release): v<NEW_VERSION>"

# Tag
git tag -a v<NEW_VERSION> -m "Release v<NEW_VERSION>"
```

## 6. Publish

```bash
git push origin main --follow-tags
```

> **Note**: This triggers the deployment pipeline.
