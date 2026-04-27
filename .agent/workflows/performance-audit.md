---
description: Audit app performance, bundle size, and optimization opportunities.
---

# Performance Audit Workflow

Use this workflow to ensure the application remains fast and lightweight, specifically for mobile users.

## 1. Bundle Analysis

Check the size of the production build.

1. Run the build:

    ```bash
    npm run build
    ```

2. **Analyze Output**: Look for "Large chunks" warnings from Vite.
    * *Goal*: Main JS bundle should be < 500kB (gzipped).
    * *Action*: If too large, consider code-splitting lazy routes (already implemented for Admin/Import).

## 2. Asset Check

Verify that static assets are optimized.

1. **Images**: existing images in `public/` or `src/assets/` should be WebP or compressed PNG/JPG.
2. **Fonts**: Ensure `woff2` format is used (most efficient).

## 3. PWA & Lighthouse (Manual Step)

Since the agent cannot run a browser audit directly:

1. Open the app in Chrome: `http://localhost:3001`
2. Open DevTools (F12) -> **Lighthouse** tab.
3. Select "Mobile" device.
4. Run "Analyze page load".

**Targets**:

* performance > 90
* Accessibility > 90
* Best Practices > 90
* SEO > 90
* PWA Badge: Active

## 4. React Render Audit

Check for unnecessary re-renders in key components (`MatchTicker`, `GameList`).

* *Technique*: Look for `console.log` left in render loops (we just cleaned these up!).
* *Code Review*: Ensure complex calculations use `useMemo` and event handlers use `useCallback` (already largely applied).
