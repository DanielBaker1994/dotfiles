// render.mjs — batch renderer for render.lua: ```mermaid fences + $math$ → SVG.
//
//   node render.mjs NODE_DIR < jobs.json > results.json
//
// jobs.json:    { "math":    [ { "id", "tex", "display" } ],
//                 "mermaid": [ { "id", "src", "svgId" } ], "mermaidConfig": {…} }
// results.json: { "<id>": { "svg": "…" } | { "png": "<base64>", "width": css px } | { "error": "…" } }
//
// ONE process (and one headless Chrome) per build renders every diagram and
// formula that render.lua could not find in its cache. The packages live in
// NODE_DIR (installed outside the dotfiles by EXTERNAL_MARKDOWN_NODE_SETUP), so
// they are resolved from there rather than from next to this file.
import { readFileSync, existsSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const NODE_DIR = process.argv[2];
const req = createRequire(join(NODE_DIR, 'package.json'));
const load = (spec) => import(pathToFileURL(req.resolve(spec)).href);

const jobs = JSON.parse(readFileSync(0, 'utf8'));
// render.lua encodes an empty Lua table as {} rather than []
for (const k of ['math', 'mermaid']) if (!Array.isArray(jobs[k])) jobs[k] = [];
const out = {};

// ── math: MathJax TeX → self-contained SVG (paths in currentColor, so a
// formula takes the surrounding text color of whatever template is active) ──
async function renderMath(list) {
  const { mathjax } = await load('mathjax-full/js/mathjax.js');
  const { TeX } = await load('mathjax-full/js/input/tex.js');
  const { SVG } = await load('mathjax-full/js/output/svg.js');
  const { liteAdaptor } = await load('mathjax-full/js/adaptors/liteAdaptor.js');
  const { RegisterHTMLHandler } = await load('mathjax-full/js/handlers/html.js');
  const { AllPackages } = await load('mathjax-full/js/input/tex/AllPackages.js');
  const adaptor = liteAdaptor();
  RegisterHTMLHandler(adaptor);
  const tex = new TeX({
    packages: AllPackages.filter((p) => p !== 'bussproofs'),
    formatError: (_jax, err) => { throw err; },   // report, don't draw red text
  });
  const doc = mathjax.document('', { InputJax: tex, OutputJax: new SVG({ fontCache: 'none' }) });
  for (const j of list) {
    try {
      out[j.id] = { svg: adaptor.innerHTML(doc.convert(j.tex, { display: !!j.display })) };
    } catch (e) {
      out[j.id] = { error: String(e.message || e) };
    }
  }
}

// ── mermaid: one Chrome for all diagrams. The config (render.lua) forces the
// "classic" look + SVG-text labels: weasyprint cannot draw <foreignObject>
// (HTML labels) or the "neo" look's CSS-only borders. Any diagram type that
// still emits <foreignObject> falls back to a 3x PNG so it never renders blank. ──
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

async function renderMermaidAll(list, mermaidConfig) {
  const { default: puppeteer } = await load('puppeteer');
  const { renderMermaid } = await load('@mermaid-js/mermaid-cli');
  const exe = process.env.MDGEN_CHROME || (existsSync(CHROME) ? CHROME : undefined);
  const browser = await puppeteer.launch({ headless: true, executablePath: exe });
  // mermaid logs parse errors to the page console; render.lua shows them itself
  const warn = console.warn;
  console.warn = () => {};
  try {
    for (const j of list) {
      const opts = { backgroundColor: 'transparent', mermaidConfig, svgId: j.svgId, fontEmbed: false,
                     viewport: { width: 1000, height: 800, deviceScaleFactor: 1 } };
      try {
        const { data } = await renderMermaid(browser, j.src, 'svg', opts);
        const svg = new TextDecoder().decode(data);
        if (svg.includes('<foreignObject')) {
          opts.viewport.deviceScaleFactor = 3;
          const png = await renderMermaid(browser, j.src, 'png', opts);
          const buf = Buffer.from(png.data);
          out[j.id] = { png: buf.toString('base64'), width: Math.round(buf.readUInt32BE(16) / 3) };
        } else {
          out[j.id] = { svg };
        }
      } catch (e) {
        out[j.id] = { error: String(e.message || e).split('\n').slice(0, 8).join('\n') };
      }
    }
  } finally {
    console.warn = warn;
    await browser.close();
  }
}

try {
  if (jobs.math.length) await renderMath(jobs.math);
  if (jobs.mermaid.length) await renderMermaidAll(jobs.mermaid, jobs.mermaidConfig || {});
} catch (e) {
  // whole-batch failure (package missing, Chrome won't start): every job reports it
  for (const j of [...jobs.math, ...jobs.mermaid]) {
    out[j.id] ??= { error: String(e.message || e) };
  }
}
process.stdout.write(JSON.stringify(out));
