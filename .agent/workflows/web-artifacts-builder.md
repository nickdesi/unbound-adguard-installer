---
description: Build elaborate, multi-component React/Tailwind/Shadcn artifacts. High-detail workflow.
---

# Web Artifacts Builder Workflow

To build powerful frontend artifacts (e.g. for Antigravity), follow these steps:

1. Initialize the frontend repo using `.agent/scripts/web-artifacts-builder/init-artifact.sh`.
2. Develop your artifact by editing the generated code.
3. Bundle all code into a single HTML file using `.agent/scripts/web-artifacts-builder/bundle-artifact.sh`.
4. Display artifact to user.

**Stack**: React 18 + TypeScript + Vite + Parcel (bundling) + Tailwind CSS + shadcn/ui.

## 1. Quick Start

### Step 1: Initialize Project

Run the initialization script:

```bash
bash .agent/scripts/web-artifacts-builder/init-artifact.sh <project-name>
cd <project-name>
```

This creates a fully configured project with:

- React + TypeScript (via Vite)
- Tailwind CSS 3.4.1 with shadcn/ui theming
- Path aliases (`@/`)
- 40+ shadcn/ui components pre-installed

### Step 2: Develop Your Artifact

Edit the files in the generated project. Avoid "AI slop" aesthetics (inter font, purple gradients, etc.).

### Step 3: Bundle to Single HTML File

To bundle the React app into a single HTML artifact:

```bash
bash .agent/scripts/web-artifacts-builder/bundle-artifact.sh
```

This creates `bundle.html` - a self-contained artifact with all JavaScript, CSS, and dependencies inlined. This file can be directly shared with the user.

### Step 4: Share Artifact

Share the bundled HTML file (`bundle.html`) with the user.

## 2. Reference

- [shadcn/ui components](https://ui.shadcn.com/docs/components)
