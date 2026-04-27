---
description: Deploy a multi-agent team to solve complex tasks automatically in one session.
---

# Parallel Orchestrator Workflow

This workflow turns your Antigravity agent into an **Autonomous Project Manager**. It breaks down complex requests (like "Refactor the entire auth module") into atomic sub-tasks and executes them securely using specialized personas, without requiring you to open multiple conversations.

## 🟢 Phase 1: The Conductor (Planning)

**Prompt:**
> "Act as **The Conductor**. Analyze the following request: `[INSERT COMPLEX TASK]`.
>
> 1. Break it down into 3-5 independent sub-tasks.
> 2. Assign a specialized **Persona** (e.g., 'Security Expert', 'UI Designer', 'DBA') to each sub-task.
> 3. Output a **Execution Plan** in JSON format."

## 🟡 Phase 2: The Virtuosos (Execution)

**Prompt:**
> "Execute the plan. For each sub-task:
>
> 1. **Switch Persona** explicitly (e.g., '🤖 **Role: Security Expert**').
> 2. Perform the task (edit files, run commands).
> 3. Verify the output.
> 4. **Auto-proceed** to the next sub-task immediately."

*Note: The agent will run these steps in sequence. If the output is too long, simply say "Continue" to let it finish.*

## 🔵 Phase 3: The Critic (Merger & Review)

**Prompt:**
> "Act as **The Lead Critic**.
>
> 1. Review all work done by the personas.
> 2. Check for consistency and integration issues.
> 3. Fix any conflicts.
> 4. Present the **Final Report**."

## 🧩 Example Scenario: "Modernize Login Page"

1. **Conductor**: "I see 3 tasks: 1. Update UI (Designer), 2. Add Rate Limiting (SecOps), 3. Update Tests (QA)."
2. **Designer**: Updates `Login.tsx`.
3. **SecOps**: Updates `auth.ts` (middleware).
4. **QA**: Updates `login.test.ts`.
5. **Critic**: "All checks passed. Commit pushed."

## ⚠️ Requirements

- **No manual context switching**: Everything happens here.
- **Context Window**: ideal for tasks touching < 20 files.
