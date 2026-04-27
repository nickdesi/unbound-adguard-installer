---
description: Master workflow to help users find the right tool.
---

# Master Router Workflow

**Use this when**: You don't know which workflow to use or need general help.

## 1. Diagnostics

**Agent**: Ask the user: "What is your primary goal right now?"

* Building something new?
* fixing a bug?
* Improving code quality?
* Testing?

## 2. Routing

Based on the answer, start the corresponding workflow:

| User Goal | Workflow to Run |
| :--- | :--- |
| "Design a UI", "Make a website" | `frontend-design` |
| "Test my app", "Check localhost" | `webapp-testing` |
| "Create an MCP server", "Connect data" | `mcp-builder` |
| "Build a React widget/artifact" | `web-artifacts-builder` |
| "Check for security", "Audit code" | `security-audit` |
| "Clean up code", "Refactor" | `code-refactor` |
| "Debug an issue", "Fix an error", "Find root cause" | `debugging-workflow` |
| "Plan complex task", "Multi-agent work" | `parallel-orchestrator` |
| "Check environment", "Verify setup" | `setup-check` |
| "Release version", "Publish app", "Bump version" | `release-manager` |
| "Check speed", "Optimize bundle", "Audit performance" | `performance-audit` |

## 3. Fallback

If none match, use the standard `brainstorming` workflow or just proceed with standard agent capabilities.
