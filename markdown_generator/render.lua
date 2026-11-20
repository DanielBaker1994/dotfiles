---@diagnostic disable: undefined-global
-- render.lua — pandoc Lua filter: things an external tool turns into SVG.
--
--   ```dot / ```graphviz   Graphviz  (brew install graphviz)
--   ```d2                  D2        (brew install d2)
--   ```mermaid             Mermaid   (node helper, see below)
--   $inline$ / $$display$$ TeX math  (node helper, MathJax → SVG)
--
-- Used by EXTERNAL_BUILD_AND_OPEN_PDF (bash/external.sh), after document.lua.
-- The author (or an AI) writes only structure; colors come from the document's
-- style (front matter `theme:` or the <div class="doc NAME"> marker): the
-- `:root:has(.NAME)` palette in friendly_document_styling.css, read at run time,
-- so there is no second copy of the colors. No style = the stylesheet's plain
-- `:root` palette, so diagrams always match the page.
--
-- Mermaid + math run in ONE node process per build (render.mjs) over every
-- block that is not already cached. Its packages live outside the dotfiles in
-- $MDGEN_NODE_DIR (default ~/.local/share/markdown_generator), installed on
-- first use by EXTERNAL_MARKDOWN_NODE_SETUP. Without them, math falls back to
-- pandoc's plain rendering and mermaid shows an error box saying how to install.
--
-- A bad diagram renders as a red error box with the tool's message (line
-- numbers included) and a pandoc warning, never as a silent blank. Results are
-- cached by content in ~/.cache/markdown_generator, so editing text elsewhere
-- never re-runs the tools. MDGEN_CSS overrides the stylesheet path.

local HOME = os.getenv('HOME') or ''
local HERE = (PANDOC_SCRIPT_FILE or ''):match('^(.*)/') or (HOME .. '/.dotfiles/markdown_generator')
local CSS = os.getenv('MDGEN_CSS') or (HERE .. '/friendly_document_styling.css')
local CACHE = HOME .. '/.cache/markdown_generator'
local NODE_DIR = os.getenv('MDGEN_NODE_DIR')
  or ((os.getenv('XDG_DATA_HOME') or (HOME .. '/.local/share')) .. '/markdown_generator')
local TOOLDIRS = { '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin' }
local VERSION = 'v8'   -- bump to drop cached renders when this file's output changes

local function exists(path)
  local f = io.open(path, 'r')
  if f then f:close() return true end
  return false
end

local function tool(name)
  for _, d in ipairs(TOOLDIRS) do
    if exists(d .. '/' .. name) then return d .. '/' .. name end
  end
  return name
end

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function read(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function write(path, s)
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(s)
  f:close()
  return true
end

local function esc(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end

-- ── palette from the stylesheet ────────────────────────────────────────────
local function vars(body)
  local p = {}
  for k, v in body:gmatch('%-%-p%-([%w%-]+):%s*([^;]+);') do p[k] = v:gsub('%s+$', '') end
  return p.bg and p or nil
end

local function palette(name)
  local css = name and read(CSS)
  if not css then return nil end
  local body = css:match(':root:has%(%.' .. name:gsub('%-', '%%-') .. '%)%s*(%b{})')
  return body and vars(body)
end

-- the stylesheet's plain `:root { --p-bg: … }` (a document with no style)
local function base_palette()
  local css = read(CSS)
  if not css then return nil end
  for body in css:gmatch(':root%s*(%b{})') do
    local p = vars(body)
    if p then return p end
  end
  return nil
end

-- the marker: <div class="doc NAME clean" ...></div> (document.lua also writes
-- one from front matter `theme:`)
local function detect(doc)
  for _, b in ipairs(doc.blocks) do
    if b.t == 'RawBlock' and b.format == 'html' then
      local cls = b.text:match('<div%s+class="doc%s+([^"]*)"')
      if cls then
        for w in cls:gmatch('%S+') do
          local p = w ~= 'clean' and palette(w)
          if p then return p end
        end
        break
      end
    end
  end
  return base_palette()
end

local function palette_key(p)
  local keys = {}
  for k in pairs(p or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. p[k] end
  return table.concat(parts, ';')
end

-- ── cache + running tools ──────────────────────────────────────────────────
local function run(cmd)
  local p = io.popen(cmd .. ' 2>&1')
  local out = p:read('*a')
  local ok = p:close()
  return ok, out
end

local function cache_path(key)
  return CACHE .. '/' .. pandoc.sha1(VERSION .. '\0' .. key) .. '.svg'
end

local function cache_get(key)
  local hit = read(cache_path(key))
  return (hit and #hit > 0) and hit or nil
end

local function cache_put(key, s)
  os.execute('mkdir -p ' .. q(CACHE))
  write(cache_path(key), s)
end

local function cached(key, build)
  local hit = cache_get(key)
  if hit then return true, hit end
  local ok, svg = build()
  if ok then cache_put(key, svg) end
  return ok, svg
end

local function tmp(ext)
  return os.tmpname() .. ext
end

local function clean(svg)
  svg = svg:gsub('^%s*<%?xml.-%?>%s*', '')
  svg = svg:gsub('<!DOCTYPE.->%s*', '')
  svg = svg:gsub('<!%-%-.-%-%->%s*', '')
  return svg
end

-- ── Graphviz ───────────────────────────────────────────────────────────────
-- defaults go in FIRST so the author's own attributes still win
local function dot_defaults(c)
  return table.concat({
    'graph [bgcolor="transparent" fontname="Helvetica" fontsize=12 fontcolor="' .. c.dim .. '"',
    'pad=0.2 nodesep=0.45 ranksep=0.55 color="' .. c.rule .. '"];',
    'node [shape=box style="rounded,filled" fontname="Helvetica" fontsize=12 margin="0.22,0.12"',
    'fillcolor="' .. c.s0 .. '" color="' .. c.accent .. '" fontcolor="' .. c.text .. '" penwidth=1.2];',
    'edge [color="' .. c.dim .. '" fontcolor="' .. c.dim .. '" fontname="Helvetica" fontsize=10',
    'arrowsize=0.8 penwidth=1.1];',
  }, ' ')
end

local function render_dot(src, p)
  local full, n = src:gsub('^(.-{)', '%1 ' .. dot_defaults(p):gsub('%%', '%%%%'), 1)
  if n == 0 then return false, 'no graph body: start with  digraph G { ... }' end
  return cached('dot\0' .. full, function()
    local inp = tmp('.dot')
    write(inp, full)
    local ok, out = run(tool('dot') .. ' -Tsvg ' .. q(inp))
    os.remove(inp)
    if not ok then return false, out end
    return true, clean(out)
  end)
end

-- ── D2 ─────────────────────────────────────────────────────────────────────
local function d2_config(c)
  local a2 = c.accent2 or c.accent
  local o = {
    N1 = c.text, N2 = c.text, N3 = c.dim, N4 = c.dim, N5 = c.rule, N6 = c.s1 or c.s0, N7 = c.bg,
    B1 = c.accent, B2 = c.accent, B3 = c.accent, B4 = c.s1 or c.s0, B5 = c.s0, B6 = c.s0,
    AA2 = a2, AA4 = c.s0, AA5 = c.s0, AB4 = c.s0, AB5 = c.s0,
  }
  local keys = { 'N1', 'N2', 'N3', 'N4', 'N5', 'N6', 'N7', 'B1', 'B2', 'B3', 'B4', 'B5', 'B6', 'AA2', 'AA4', 'AA5', 'AB4', 'AB5' }
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. ': "' .. o[k] .. '"' end
  -- ONE line, so the author's own line numbers are the author's line numbers + 1
  return 'vars: { d2-config: { layout-engine: elk; pad: 12; theme-overrides: { '
    .. table.concat(parts, '; ') .. ' } } }\n'
end

-- weasyprint mishandles D2's <mask> (the knockout that cuts an edge behind its
-- label): it paints a white page with a black block. Drop the masks and lay a
-- page-colored patch behind each label instead.
local function unmask(svg, bg)
  local rects = {}
  for m in svg:gmatch('<mask.-</mask>') do
    for x, y, w, h in m:gmatch('<rect x="([%-%d%.]+)" y="([%-%d%.]+)" width="([%d%.]+)" height="([%d%.]+)" fill="black">') do
      rects[#rects + 1] = { tonumber(x), tonumber(y), tonumber(w), tonumber(h) }
    end
  end
  svg = svg:gsub('<mask.-</mask>%s*', '')
  -- filled shapes, so a label inside a container gets the CONTAINER's color
  local shapes = {}
  for x, y, w, h, fill in svg:gmatch('<rect x="([%-%d%.]+)" y="([%-%d%.]+)" width="([%d%.]+)" height="([%d%.]+)"[^>]-fill="(#%x+)"[^>]-class=" [^"]-fill%-') do
    shapes[#shapes + 1] = { tonumber(x), tonumber(y), tonumber(w), tonumber(h), fill }
  end
  local function behind(cx, cy)
    local best, area = bg, math.huge
    for _, sh in ipairs(shapes) do
      if cx >= sh[1] and cx <= sh[1] + sh[3] and cy >= sh[2] and cy <= sh[2] + sh[4] and sh[3] * sh[4] < area then
        best, area = sh[5], sh[3] * sh[4]
      end
    end
    return best
  end
  svg = svg:gsub('(<path [^>]-)%s+mask="url%(#[^)]*%)"([^>]-/>)', function(a, b)
    local extra = ''
    if bg then
      local d = a:match(' d="([^"]*)"') or ''
      local xs, ys, i = {}, {}, 0
      for n in d:gmatch('%-?[%d%.]+') do
        i = i + 1
        if i % 2 == 1 then xs[#xs + 1] = tonumber(n) else ys[#ys + 1] = tonumber(n) end
      end
      if #xs > 0 and #ys > 0 then
        local x0, x1, y0, y1 = math.min(table.unpack(xs)), math.max(table.unpack(xs)),
                               math.min(table.unpack(ys)), math.max(table.unpack(ys))
        for _, r in ipairs(rects) do
          local cx, cy = r[1] + r[3] / 2, r[2] + r[4] / 2
          if cx >= x0 - 2 and cx <= x1 + 2 and cy >= y0 - 2 and cy <= y1 + 2 then
            extra = extra .. ('<rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>'):format(r[1] - 2, r[2] - 1, r[3] + 4, r[4] + 2, behind(cx, cy))
          end
        end
      end
    end
    return a .. b .. extra
  end)
  return svg
end

local function render_d2(src, p)
  local full = (src:find('d2%-config', 1, false) and '' or d2_config(p)) .. src
  return cached('d2\0' .. full, function()
    local inp, outp = tmp('.d2'), tmp('.svg')
    write(inp, full)
    local ok, out = run(tool('d2') .. ' ' .. q(inp) .. ' ' .. q(outp))
    local svg = ok and read(outp) or nil
    os.remove(inp); os.remove(outp)
    if not ok or not svg then return false, out end
    svg = clean(svg)
    -- D2 paints a page-colored background rectangle first: drop it (the page has its own)
    svg = svg:gsub('<rect[^>]-class=" fill%-N7"[^>]-/>', '', 1)
    return true, unmask(svg, p.bg)
  end)
end

-- weasyprint draws D2's SVG (nested <svg>, class-based CSS, embedded fonts) wrong
-- when it is inlined in the page, but right as an image: embed it as a vector
-- data URI instead (Graphviz's and Mermaid's SVG stay inline: real text)
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1, c2, c3, c4 = (n >> 18) & 63, (n >> 12) & 63, (n >> 6) & 63, n & 63
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or '=') .. (c and B64:sub(c4 + 1, c4 + 1) or '=')
  end
  return table.concat(out)
end

local function as_image(svg)
  local w = svg:match('viewBox="[%-%d%.]+ [%-%d%.]+ ([%d%.]+) [%d%.]+"')
  return '<img alt="diagram" src="data:image/svg+xml;base64,' .. base64(svg) .. '"'
    .. (w and (' style="width:' .. math.floor(tonumber(w) * 0.8) .. 'px;max-width:100%"') or '') .. '>'
end

local function tidy_error(kind, msg)
  msg = msg:gsub('^err: failed to compile [^\n]-: ', '')
  msg = msg:gsub('/[%w_/%.%-]*lua_[%w]+%.%w+', 'diagram')
  if kind == 'd2' then
    msg = msg:gsub('diagram:(%d+):', function(n) return 'diagram:' .. math.max(1, tonumber(n) - 1) .. ':' end)
    msg = msg:gsub('diagram:(%d+)%-(%d+)', function(a, b) return 'diagram:' .. math.max(1, tonumber(a) - 1) .. '-' .. math.max(1, tonumber(b) - 1) end)
  end
  return msg
end

-- ── Mermaid ────────────────────────────────────────────────────────────────
local function is_dark(hex)
  local r, g, b = (hex or ''):match('^#(%x%x)(%x%x)(%x%x)$')
  if not r then return false end
  return (0.2126 * tonumber(r, 16) + 0.7152 * tonumber(g, 16) + 0.0722 * tonumber(b, 16)) < 128
end

-- "classic" look + SVG-text labels are what weasyprint can draw; every color
-- maps onto the page palette. A diagram's own `---\nconfig: …\n---` still wins.
local function mermaid_config(p)
  local a2 = p.accent2 or p.accent
  -- pie slices / mindmap branches / git lanes: spread across hues, not 3 blues
  local series = { p.accent, p.warning or a2, p.success or a2, p.danger or a2, p.info or p.accent,
                   a2, p.dim, p.rule }
  local tv = {
    darkMode = is_dark(p.bg), background = p.bg, fontSize = '14px',
    fontFamily = '"Helvetica Neue", Helvetica, Arial, sans-serif',
    primaryColor = p.s0, primaryBorderColor = p.accent, primaryTextColor = p.text,
    secondaryColor = p.s1, secondaryBorderColor = a2, secondaryTextColor = p.text,
    tertiaryColor = p.well, tertiaryBorderColor = p.rule, tertiaryTextColor = p.text,
    mainBkg = p.s0, nodeBorder = p.accent, nodeTextColor = p.text, textColor = p.text,
    lineColor = p.dim, titleColor = p.text, edgeLabelBackground = p.bg,
    clusterBkg = p.well, clusterBorder = p.rule,
    noteBkgColor = p.s1, noteTextColor = p.text, noteBorderColor = p.rule,
    actorBkg = p.s0, actorBorder = p.accent, actorTextColor = p.text, actorLineColor = p.dim,
    signalColor = p.dim, signalTextColor = p.text, labelBoxBkgColor = p.s0,
    labelBoxBorderColor = p.rule, labelTextColor = p.text, loopTextColor = p.text,
    activationBkgColor = p.s1, activationBorderColor = p.accent, sequenceNumberColor = p.bg,
    pieStrokeColor = p.bg, pieOuterStrokeColor = p.rule, pieSectionTextColor = p.bg,
    pieTitleTextColor = p.text, pieLegendTextColor = p.text,
    sectionBkgColor = p.well, altSectionBkgColor = p.bg, sectionBkgColor2 = p.s0, gridColor = p.rule,
    taskBkgColor = p.s1, taskBorderColor = p.accent, taskTextColor = p.text,
    taskTextOutsideColor = p.text, taskTextLightColor = p.text, taskTextDarkColor = p.text,
    activeTaskBkgColor = p.s0, activeTaskBorderColor = a2, doneTaskBkgColor = p.well,
    doneTaskBorderColor = p.dim, critBkgColor = p.s1, critBorderColor = p.danger or a2,
    todayLineColor = p.danger or a2,
    relationColor = p.dim, relationLabelColor = p.text, relationLabelBackground = p.bg,
    attributeBackgroundColorOdd = p.s0, attributeBackgroundColorEven = p.bg,
  }
  for i, c in ipairs(series) do
    tv['pie' .. i] = c
    tv['cScale' .. (i - 1)] = c
    tv['cScaleLabel' .. (i - 1)] = p.bg
    tv['git' .. (i - 1)] = c
  end
  -- useMaxWidth=false: natural size (CSS max-width:100% still shrinks big
  -- ones) instead of every diagram, even a 3-slice pie, stretched to full width
  local cfg = {
    theme = 'base', look = 'classic', htmlLabels = false, securityLevel = 'strict',
    themeVariables = tv,
  }
  for _, d in ipairs({ 'flowchart', 'sequence', 'gantt', 'class', 'state', 'er', 'pie', 'journey',
                       'timeline', 'mindmap', 'gitGraph', 'quadrantChart', 'xyChart', 'requirement',
                       'block', 'sankey', 'packet', 'architecture', 'kanban', 'radar' }) do
    cfg[d] = { useMaxWidth = false }
  end
  cfg.flowchart.htmlLabels = false
  cfg.sequence.mirrorActors = false
  cfg.pie.useWidth = 520
  return cfg
end

-- ── the node batch (mermaid + math) ────────────────────────────────────────
local node_ok = nil
local function have_node()
  if node_ok == nil then
    node_ok = exists(NODE_DIR .. '/node_modules/@mermaid-js/mermaid-cli/package.json')
      and exists(NODE_DIR .. '/node_modules/mathjax-full/package.json')
  end
  return node_ok
end
local SETUP_HINT = 'node helpers missing: run EXTERNAL_MARKDOWN_NODE_SETUP (installs into ' .. NODE_DIR .. ')'

local function run_batch(jobs)
  local inp, outp = tmp('.json'), tmp('.json')
  write(inp, pandoc.json.encode(jobs))
  local ok, log = run(q(tool('node')) .. ' ' .. q(HERE .. '/render.mjs') .. ' ' .. q(NODE_DIR)
    .. ' < ' .. q(inp) .. ' > ' .. q(outp))
  local raw = read(outp)
  os.remove(inp); os.remove(outp)
  local decoded = raw and raw ~= '' and pandoc.json.decode(raw, false)
  if not ok or type(decoded) ~= 'table' then
    return nil, 'render.mjs failed: ' .. (log ~= '' and log or 'no output')
  end
  return decoded
end

local function error_block(kind, msg)
  local lines = {}
  for l in msg:gmatch('[^\n]+') do
    if not l:match('^%s*%-*%^%s*$') and #lines < 3 then lines[#lines + 1] = (l:gsub('^%s+', '')) end
  end
  pandoc.log.warn(kind .. ' diagram failed: ' .. table.concat(lines, ' | '))
  return pandoc.RawBlock('html',
    '<pre class="diagram-error"><strong>' .. kind .. ' diagram failed</strong>\n' .. esc(msg) .. '</pre>')
end

local function figure(kind, inner)
  return pandoc.RawBlock('html', '<figure class="diagram ' .. kind .. '">' .. inner .. '</figure>')
end

-- MathJax draws in currentColor, which weasyprint does not carry into inline
-- SVG (dark templates got black formulas): bake in the palette's text color
-- here, after the cache, so cached formulas stay palette-free
local function math_html(el, svg, color)
  local mode = el.mathtype == 'DisplayMath' and 'display' or 'inline'
  svg = svg:gsub('currentColor', color)
  return pandoc.RawInline('html',
    '<span class="math ' .. mode .. '" title="' .. esc(el.text) .. '">' .. svg .. '</span>')
end

-- mermaid's pie is a fixed 450px tall (useMaxWidth/useWidth don't change it):
-- shrink it to sit like the other diagrams
local function mermaid_svg(svg)
  if not svg:find('aria%-roledescription="pie"') then return svg end
  local function scale(v) return string.format('%.1f', tonumber(v) * 0.65) end
  return (svg:gsub('^(<svg[^>]-)width="([%d%.]+)"', function(a, w) return a .. 'width="' .. scale(w) .. '"' end, 1)
             :gsub('^(<svg[^>]-)height="([%d%.]+)"', function(a, h) return a .. 'height="' .. scale(h) .. '"' end, 1))
end

local function math_key(el) return 'math\0' .. el.mathtype .. '\0' .. el.text end

function Pandoc(doc)
  local p = detect(doc) or {
    bg = '#ffffff', text = '#1d1d1f', dim = '#6e6e73', accent = '#2b6cb0', accent2 = '#8250df',
    well = '#f5f5f7', s0 = '#f0f0f3', s1 = '#e4e6ea', rule = '#c8ccd2' }
  local mcfg = mermaid_config(p)
  local mkey = 'mermaid\0' .. palette_key(p) .. '\0'

  -- pass 1: everything the node helper must render (not in the cache yet)
  local jobs, results, seen = { math = {}, mermaid = {}, mermaidConfig = mcfg }, {}, {}
  doc:walk({
    CodeBlock = function(el)
      if el.classes[1] == 'mermaid' then
        local key = mkey .. el.text
        if not seen[key] and not cache_get(key) then
          seen[key] = true
          jobs.mermaid[#jobs.mermaid + 1] = { id = key, src = el.text,
                                              svgId = 'mmd-' .. pandoc.sha1(key):sub(1, 10) }
        end
      end
    end,
    Math = function(el)
      local key = math_key(el)
      if not seen[key] and not cache_get(key) then
        seen[key] = true
        jobs.math[#jobs.math + 1] = { id = key, tex = el.text, display = el.mathtype == 'DisplayMath' }
      end
    end,
  })
  local batch_err = nil
  if #jobs.math + #jobs.mermaid > 0 then
    if not have_node() then
      batch_err = SETUP_HINT
      if #jobs.math > 0 then pandoc.log.warn('math left as plain text: ' .. SETUP_HINT) end
    else
      local res, err = run_batch(jobs)
      batch_err = err
      for id, r in pairs(res or {}) do
        results[id] = r
        if r.svg then cache_put(id, clean(r.svg)) end
      end
    end
  end

  -- pass 2: swap every block / formula for its rendering
  return doc:walk({
    CodeBlock = function(el)
      local lang = el.classes[1]
      if lang == 'dot' or lang == 'graphviz' then
        local ok, out = render_dot(el.text, p)
        if not ok then return error_block('dot', tidy_error('dot', out)) end
        return figure('dot', out)
      elseif lang == 'd2' then
        local ok, out = render_d2(el.text, p)
        if not ok then return error_block('d2', tidy_error('d2', out)) end
        return figure('d2', as_image(out))
      elseif lang == 'mermaid' then
        local key = mkey .. el.text
        local hit = cache_get(key)
        if hit then return figure('mermaid', mermaid_svg(hit)) end
        local r = results[key]
        if r and r.png then
          return figure('mermaid', '<img alt="diagram" src="data:image/png;base64,' .. r.png .. '"'
            .. (r.width and (' style="width:' .. r.width .. 'px;max-width:100%"') or '') .. '>')
        end
        local msg = (r and r.error) or batch_err or 'no output'
        msg = msg:gsub('\n[^\n]*%(https?://[^\n]*', '')   -- drop JS stack frames
        return error_block('mermaid', msg)
      end
    end,
    Math = function(el)
      local key = math_key(el)
      local hit = cache_get(key)
      if hit then return math_html(el, hit, p.text) end
      local r = results[key]
      if r and r.error then
        pandoc.log.warn('math failed: ' .. r.error .. ' in: ' .. el.text)
        return pandoc.RawInline('html', '<span class="math-error" title="' .. esc(r.error) .. '">'
          .. esc(el.text) .. '</span>')
      end
      return nil   -- helpers missing: pandoc's own plain rendering
    end,
  })
end
