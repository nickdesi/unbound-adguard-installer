---
description: Toolkit for interacting with and testing local web applications using Playwright. High-detail workflow.
---

# Web Application Testing Workflow

To test local web applications, write native Python Playwright scripts.

**Helper Scripts Available**:

- `.agent/scripts/webapp-testing/with_server.py` - Manages server lifecycle.

**Always run scripts with `--help` first** to see usage.

## 1. Decision Tree: Choosing Your Approach

```
User task → Is it static HTML?
    ├─ Yes → Read HTML file directly to identify selectors
    │         ├─ Success → Write Playwright script using selectors
    │         └─ Fails/Incomplete → Treat as dynamic (below)
    │
    └─ No (dynamic webapp) → Is the server already running?
        ├─ No → Run: python .agent/scripts/webapp-testing/with_server.py --help
        │        Then use the helper + write simplified Playwright script
        │
        └─ Yes → Reconnaissance-then-action:
            1. Navigate and wait for networkidle
            2. Take screenshot or inspect DOM
            3. Identify selectors from rendered state
            4. Execute actions with discovered selectors
```

## 2. Using with_server.py

**Single server:**

```bash
python .agent/scripts/webapp-testing/with_server.py --server "npm run dev" --port 5173 -- python your_automation.py
```

**Multiple servers (e.g., backend + frontend):**

```bash
```bash
python .agent/scripts/webapp-testing/with_server.py \
  --server "cd backend && python server.py" --port 3000 \
  --server "cd frontend && npm run dev" --port 5173 \
  -- python your_automation.py
```

```

**Automation Script Template**:

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True) # Always launch chromium in headless mode
    page = browser.new_page()
    page.goto('http://localhost:5173') # Server already running and ready
    page.wait_for_load_state('networkidle') # CRITICAL: Wait for JS to execute
    # ... your automation logic
    browser.close()
```

## 3. Reconnaissance-Then-Action Pattern

1. **Inspect rendered DOM**:

   ```python
   page.screenshot(path='/tmp/inspect.png', full_page=True)
   content = page.content()
   page.locator('button').all()
   ```

2. **Identify selectors** from inspection results.
3. **Execute actions** using discovered selectors.

## 4. Best Practices

- **Use bundled scripts as black boxes**.
- Use `sync_playwright()` for synchronous scripts.
- Always close the browser when done.
- Use descriptive selectors: `text=`, `role=`, CSS selectors, or IDs.
- Add appropriate waits: `page.wait_for_selector()` or `page.wait_for_timeout()`.

## 5. Troubleshooting

- **"Browser not found"**: If Playwright can't find Chromium, run `playwright install chromium` inside the python environment.
- **Timeouts**: If `wait_for_selector` fails, try increasing the timeout `page.wait_for_selector('...', timeout=10000)` or check if the element is inside a Shadow DOM.
- **Headless mode**: If debugging is hard, set `headless=False` to see the browser actions live.
