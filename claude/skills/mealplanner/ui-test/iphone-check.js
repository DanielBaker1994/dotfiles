// Mobile UI check for the Home Kitchen web app on an emulated iPhone 13 mini (375x629 CSS px, DPR 3, touch),
// in WebKit (Safari's engine: closest to a real iPhone) and Chromium (= Chrome DevTools device mode).
// Usage: bash run.sh iphone-check.js <out-dir> [route ...]   (run.sh passes the base URL and /out)      e.g. routes: '#/products' '#/meals'
// Per route it saves a screenshot and prints: horizontal overflow, elements wider than the screen, page errors.
const { chromium, webkit, devices } = require('/t/node_modules/playwright');
const [base, out = '.', ...routes] = process.argv.slice(2);
if (!base) { console.error('usage: node iphone-check.js <base-url> <out-dir> [route ...]'); process.exit(2); }
const ROUTES = routes.length ? routes : ['#/meals', '#/recipes', '#/shopping', '#/settings', '#/products'];
(async () => {
  const engines = [['webkit', webkit], ['chromium', chromium]].filter(([n]) => !process.env.ENGINE || process.env.ENGINE === n);
  for (const [name, bt] of engines) {
    const b = await bt.launch();
    const ctx = await b.newContext({ ...devices['iPhone 13 Mini'] });
    const p = await ctx.newPage();
    let errs = [];
    p.on('pageerror', (e) => errs.push(e.message));
    // failed responses are reported by URL below; skip the browser's generic "Failed to load resource" lines
    p.on('console', (m) => m.type() === 'error' && !m.text().startsWith('Failed to load resource') && errs.push(m.text()));
    p.on('response', (r) => r.status() >= 400 && errs.push(`HTTP ${r.status()} ${new URL(r.url()).pathname}${new URL(r.url()).search.slice(0, 60)}`));
    p.on('requestfailed', (r) => !/ERR_ABORTED|cancelled/i.test(r.failure()?.errorText || '') && errs.push(`FAILED ${r.url().slice(0, 100)} ${r.failure()?.errorText}`));
    for (const r of ROUTES) {
      errs = [];
      await p.goto(new URL(r, base).href, { waitUntil: 'load' });
      await p.locator('#view > *').first().waitFor({ timeout: 15000 }).catch(() => {}); await p.waitForTimeout(1200);
      const file = `${out}/${name}-${r.replace(/[^a-z0-9]+/gi, '_')}.png`;
      await p.screenshot({ path: file, fullPage: true });
      await p.screenshot({ path: file.replace(/\.png$/, '-screen.png') }); // what the phone shows first
      const res = await p.evaluate(() => {
        const W = document.documentElement.clientWidth;
        const wide = [...document.querySelectorAll('body *')].filter((e) => {
          const b = e.getBoundingClientRect(); return b.width && (b.right > W + 1 || b.left < -1) && getComputedStyle(e).position !== 'fixed';
        }).slice(0, 8).map((e) => `${e.tagName.toLowerCase()}.${[...e.classList].join('.')} r=${Math.round(e.getBoundingClientRect().right)}`);
        return { hOverflow: document.documentElement.scrollWidth - W, wide };
      });
      const uniq = [...new Set(errs)];
      console.log(`${name} ${r} -> ${file}`, JSON.stringify(res), uniq.length ? `\n   ${errs.length} errors, e.g.:\n   ${uniq.slice(0, 4).join('\n   ')}` : '');
    }
    await b.close();
  }
})();
