---
description: Verify your environment is ready for Antigravity.
---

# Setup Check Workflow

Use this workflow to verify that your environment has all the necessary tools (Node.js, Python, Git) to run the other workflows.

## 1. Run the Check Script

**Action**: Run the environment checker.

```bash
bash .agent/scripts/check-env.sh
```

## 2. Interpret Results

- **✅ Green**: System is ready.
- **❌ Red**: Missing critical dependency. Install it.
- **⚠️ Yellow**: Missing optional dependency (e.g., Playwright).

## 3. Troubleshooting

- **Node.js**: Install via [nodejs.org](https://nodejs.org/).
- **Python**: Install via [python.org](https://www.python.org/).
