// Settings › Products › "On my lists": open the first product's pop-up on an iPhone 13 mini and measure its layout.
// Regression check for ad720fb (picture vanished, facts clipped). Usage (via run.sh): popup-check.js
const { chromium, webkit, devices } = require('/t/node_modules/playwright');
const [base, out] = process.argv.slice(2);
(async () => {
  let bad = 0;
  for (const [name, bt] of [['webkit', webkit], ['chromium', chromium]]) {
    const b = await bt.launch();
    const p = await (await b.newContext({ ...devices['iPhone 13 Mini'] })).newPage();
    const errs = []; p.on('pageerror', (e) => errs.push(e.message));
    await p.goto(new URL('#/products', base).href, { waitUntil: 'load' });
    await p.getByRole('tab', { name: 'On my lists' }).tap();
    await p.waitForTimeout(800);
    await p.getByRole('combobox').tap();
    await p.getByRole('option').first().waitFor();
    await p.getByRole('option').first().tap();
    await p.locator('dialog.product-pop .pic.pop img').waitFor();
    await p.waitForTimeout(800);
    await p.screenshot({ path: `${out}/${name}-popup.png` });
    const m = await p.evaluate(() => {
      const r = (s) => document.querySelector(s)?.getBoundingClientRect();
      const img = r('.pic.pop img'), box = r('.product-pop-img'), info = r('.product-pop-info'), body = document.querySelector('.product-pop-body');
      return { imgH: Math.round(img.height), boxH: Math.round(box.height), infoTop: Math.round(info.top), boxBottom: Math.round(box.bottom),
        scrolls: body.scrollHeight > body.clientHeight && getComputedStyle(body).overflowY === 'auto' };
    });
    await p.locator('.product-pop-body').evaluate((e) => { e.scrollTop = e.scrollHeight; });
    await p.waitForTimeout(300);
    await p.screenshot({ path: `${out}/${name}-popup-scrolled.png` });
    const ok = m.imgH > 100 && m.imgH <= m.boxH && m.infoTop >= m.boxBottom - 1 && m.scrolls && !errs.length;
    if (!ok) bad++;
    console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`, JSON.stringify(m), errs.join(' | '));
    await b.close();
  }
  process.exit(bad ? 1 : 0);
})();
