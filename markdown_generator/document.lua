---@diagnostic disable: undefined-global
-- document.lua — pandoc Lua filter: document-level conveniences. Runs BEFORE
-- render.lua in EXTERNAL_BUILD_AND_OPEN_PDF (bash/external.sh).
--
-- Front matter (all optional) — the same switches as the marker line, but in
-- the YAML block AI tools already write:
--
--   ---
--   title: Q3 Platform Review      # becomes the `# Title` if the body has none
--   subtitle: Prepared for …       # (else author · date) → the subtitle line
--   theme: tokyo-night             # = <div class="doc tokyo-night"> (any CSS palette)
--   footer: Confidential           # PDF footer, left (implies the doc template)
--   clean: true                    # copy-friendly PDF: no icon-font glyphs
--   toc: true                      # contents after the title (or a depth: 2, 3)
--   numbered: true                 # 1 / 1.1 / 1.1.1 heading numbers (TOC too)
--   paper: a4                      # any CSS page size: letter, a4, "a4 landscape"
--   ---
--
-- Markdown niceties:
--   ```lang          every code block gets a small "icon + language" label
--   - [ ] / - [x]    task lists drawn as boxes (weasyprint can't draw checkboxes)
--   ::: risk         fenced-div callouts (= <div class="callout risk">), and
--   ::: warning      alerts (= > [!WARNING]); {title="…"} renames either
--   ```csv / ```tsv  → a real table (first row = header)
--   ```svg           → the SVG itself, inline
--   \newpage, \pagebreak, <!-- pagebreak -->, ::: pagebreak  → page break
--   tables whose first column is all numbers lose the bold "row label" column

local ALERTS = { note = 'Note', tip = 'Tip', important = 'Important', warning = 'Warning', caution = 'Caution' }
local CALLOUTS = { decision = 1, risk = 1, breaking = 1, deprecated = 1, action = 1, example = 1,
                   question = 1, rollback = 1, perf = 1, summary = 1, tldr = 1 }
-- fences another filter (render.lua) or this one turns into something else
local RENDERED = { mermaid = 1, dot = 1, graphviz = 1, d2 = 1, csv = 1, tsv = 1, svg = 1 }
local NO_LABEL = { text = 1, txt = 1, plain = 1, plaintext = 1, none = 1, output = 1 }
local ALIAS = { js = 'javascript', ts = 'typescript', py = 'python', yml = 'yaml', rb = 'ruby',
                rs = 'rust', cs = 'csharp', ['c++'] = 'cpp', kt = 'kotlin', md = 'markdown',
                ps1 = 'powershell', docker = 'dockerfile', make = 'makefile', tf = 'hcl',
                terraform = 'hcl', golang = 'go', jsonc = 'json', patch = 'diff', tex = 'latex',
                terminal = 'console', shellsession = 'console' }
-- Nerd Font glyphs, the same ones nvim-web-devicons (render-markdown) shows
local ICON = {
  bash = '\u{e795}', c = '\u{e61e}', cmake = '\u{e794}', console = '\u{e795}', cpp = '\u{e61d}',
  csharp = '\u{f031b}', css = '\u{e6b8}', dart = '\u{e798}', diff = '\u{e728}',
  dockerfile = '\u{f0868}', elixir = '\u{e62d}', go = '\u{e627}', graphql = '\u{f20e}',
  haskell = '\u{e61f}', hcl = '\u{e69a}', html = '\u{e736}', ini = '\u{e615}', java = '\u{e738}',
  javascript = '\u{e60c}', json = '\u{e60b}', jsx = '\u{e625}', kotlin = '\u{e634}',
  latex = '\u{e69b}', log = '\u{f0331}', lua = '\u{e620}', makefile = '\u{e779}',
  markdown = '\u{f48a}', nix = '\u{f313}', perl = '\u{e769}', php = '\u{e608}',
  powershell = '\u{f0a0a}', python = '\u{e606}', r = '\u{f07d4}', ruby = '\u{e791}', rust = '\u{e68b}',
  scala = '\u{e737}', sh = '\u{e795}', shell = '\u{e795}', sql = '\u{e706}', swift = '\u{e755}',
  toml = '\u{e6b2}', tsx = '\u{e7ba}', typescript = '\u{e628}', vim = '\u{e62b}', xml = '\u{f05c0}',
  yaml = '\u{e8eb}', zig = '\u{e6a9}', zsh = '\u{e795}',
}

local stringify = pandoc.utils.stringify

local function has_class(el, cls)
  for _, c in ipairs(el.classes) do if c == cls then return true end end
  return false
end

local function truthy(v)
  if v == nil then return false end
  if type(v) == 'boolean' then return v end
  local s = stringify(v):lower()
  return s ~= '' and s ~= 'false' and s ~= 'no' and s ~= '0'
end

local function attr_escape(s)
  return (s:gsub('&', '&amp;'):gsub('"', '&quot;'):gsub('<', '&lt;'))
end

local PAGEBREAK = pandoc.RawBlock('html', '<div class="pagebreak"></div>')

-- ── tables: no bold "label" column when the first column is all numbers ────
local function label_table(tbl)
  local rows, numeric = 0, true
  for _, body in ipairs(tbl.bodies) do
    for _, row in ipairs(body.body) do
      local cell = row.cells[1]
      local s = cell and stringify(cell.contents) or ''
      rows = rows + 1
      if s ~= '' and not s:match('^[%s%d%.,%%%$%-+~<>=]+$') then numeric = false end
    end
  end
  if rows > 0 and numeric then tbl.classes:insert('no-label') end
  return tbl
end

-- ── code blocks: label, csv/tsv tables, inline svg ─────────────────────────
local function code_block(el)
  local raw = el.classes[1]
  if not raw then return nil end
  local lang = raw:lower()
  if lang == 'csv' or lang == 'tsv' then
    local ok, parsed = pcall(pandoc.read, el.text, lang)
    if ok and parsed.blocks[1] and parsed.blocks[1].t == 'Table' then
      return label_table(parsed.blocks[1])
    end
    pandoc.log.warn(lang .. ' block could not be parsed as a table; left as code')
    return nil
  end
  if lang == 'svg' then
    return pandoc.RawBlock('html', '<figure class="diagram svg">' .. el.text .. '</figure>')
  end
  if RENDERED[lang] or NO_LABEL[lang] then return nil end
  local name = ALIAS[lang] or lang
  return pandoc.Div({ el }, pandoc.Attr('', { 'code' },
    { ['data-lang'] = name, ['data-icon'] = ICON[name] and (ICON[name] .. '  ') or '' }))
end

-- ── task lists: ☐ / ☒ (pandoc's gfm reader) → drawn boxes ──────────────────
local function task_marker(item)
  local first = item[1]
  if not first or (first.t ~= 'Plain' and first.t ~= 'Para') then return nil end
  local s = first.content[1]
  if s and s.t == 'Str' and (s.text == '☐' or s.text == '☒') then return first, s.text == '☒' end
  return nil
end

local function bullet_list(el)
  for _, item in ipairs(el.content) do
    if not task_marker(item) then return nil end
  end
  for _, item in ipairs(el.content) do
    local first, done = task_marker(item)
    if not first then return nil end
    first.content:remove(1)
    if first.content[1] and first.content[1].t == 'Space' then first.content:remove(1) end
    first.content:insert(1, pandoc.RawInline('html',
      '<span class="task-box' .. (done and ' done' or '') .. '" aria-hidden="true"></span>'))
  end
  return pandoc.Div({ el }, pandoc.Attr('', { 'task-list' }))
end

-- ── fenced divs: callouts, alerts, page breaks ─────────────────────────────
local function div(el)
  if has_class(el, 'pagebreak') and #el.content == 0 then return PAGEBREAK end
  local title = el.attributes.title
  for _, c in ipairs(el.classes) do
    if ALERTS[c] then
      local f = el.content[1]
      if not (f and f.t == 'Div' and has_class(f, 'title')) then   -- not already gfm's
        el.content:insert(1, pandoc.Div({ pandoc.Para({ pandoc.Str(title or ALERTS[c]) }) },
          pandoc.Attr('', { 'title' })))
        el.attributes.title = nil
      end
      return el
    end
    if CALLOUTS[c] then
      if not has_class(el, 'callout') then el.classes:insert(1, 'callout') end
      if title then el.attributes['data-title'] = title; el.attributes.title = nil end
      return el
    end
  end
  return nil
end

local function para(el)
  if #el.content == 1 and el.content[1].t == 'Str' then
    local t = el.content[1].text
    if t == '\\newpage' or t == '\\pagebreak' then return PAGEBREAK end
  end
end

local function raw_block(el)
  if el.format == 'html' and el.text:match('^%s*<!%-%-%s*page%-?break%s*%-%->%s*$') then return PAGEBREAK end
end

-- ── document level: title, numbering, TOC, theme marker, paper ─────────────
local function is_marker(b)
  return b.t == 'RawBlock' and b.format == 'html' and b.text:match('<div%s+class="doc[%s"]') ~= nil
end

-- index of the first block that is real content (skips marker / style lines)
local function first_content(blocks)
  for i, b in ipairs(blocks) do
    if not (b.t == 'RawBlock' and b.format == 'html') then return i end
  end
  return nil
end

local function number_headings(blocks, from)
  local top = math.huge
  for i = from, #blocks do
    if blocks[i].t == 'Header' then top = math.min(top, blocks[i].level) end
  end
  if top == math.huge then return end
  local n = { 0, 0, 0 }
  for i = from, #blocks do
    local h = blocks[i]
    local depth = h.t == 'Header' and (h.level - top + 1) or 0
    if depth >= 1 and depth <= 3 and not has_class(h, 'unnumbered') then
      n[depth] = n[depth] + 1
      for d = depth + 1, 3 do n[d] = 0 end
      local label = table.concat({ table.unpack(n, 1, depth) }, '.')
      h.content:insert(1, pandoc.Space())
      h.content:insert(1, pandoc.Span({ pandoc.Str(label) }, pandoc.Attr('', { 'secnum' })))
    end
  end
end

function Pandoc(doc)
  local meta, blocks = doc.meta, doc.blocks

  -- the body's own `# Title` vs front matter `title:` (never both: pandoc would
  -- print its title block AND the heading)
  local fc = first_content(blocks)
  local has_h1 = fc and blocks[fc].t == 'Header' and blocks[fc].level == 1
  if meta.title then
    if not meta.pagetitle then meta.pagetitle = stringify(meta.title) end
    if not has_h1 then
      local sub = meta.subtitle and stringify(meta.subtitle)
      if not sub then
        local bits = {}
        if meta.author then bits[#bits + 1] = stringify(meta.author) end
        if meta.date then bits[#bits + 1] = stringify(meta.date) end
        sub = #bits > 0 and table.concat(bits, ' · ') or nil
      end
      local at = fc or (#blocks + 1)
      if sub then blocks:insert(at, pandoc.Para({ pandoc.Str(sub) })) end
      blocks:insert(at, pandoc.Header(1, meta.title))
      fc, has_h1 = at, true
    end
    meta.title, meta.subtitle = nil, nil
  elseif has_h1 and not meta.pagetitle then
    meta.pagetitle = stringify(blocks[fc].content)
  end
  if not meta.lang then meta.lang = 'en' end

  -- where the body starts: after the title and its subtitle paragraph
  local body_at = fc or 1
  if has_h1 then
    body_at = fc + 1
    if blocks[body_at] and blocks[body_at].t == 'Para' then body_at = body_at + 1 end
  end

  if truthy(meta.numbered) then number_headings(blocks, has_h1 and fc + 1 or 1) end

  if truthy(meta.toc) then
    local depth = tonumber(stringify(meta.toc)) or 3
    local rest = pandoc.Blocks({})
    for i = (has_h1 and fc + 1 or 1), #blocks do rest:insert(blocks[i]) end
    local list = pandoc.structure.table_of_contents(rest, { toc_depth = depth + (has_h1 and 1 or 0) })
    if list and #list.content > 0 then
      blocks:insert(body_at, pandoc.RawBlock('html', '</nav>'))
      blocks:insert(body_at, list)
      blocks:insert(body_at, pandoc.RawBlock('html',
        '<nav id="TOC" role="doc-toc"><p class="toc-title">Contents</p>'))
    end
  end
  meta.toc = nil   -- else pandoc's template prints its own (empty) <nav id="TOC">

  -- front matter theme / footer / clean → the same marker line the CSS reads
  local has_marker = false
  for _, b in ipairs(blocks) do if is_marker(b) then has_marker = true break end end
  if not has_marker and (meta.theme or meta.footer or truthy(meta.clean)) then
    local cls = 'doc'
    if meta.theme then cls = cls .. ' ' .. stringify(meta.theme) end
    if truthy(meta.clean) then cls = cls .. ' clean' end
    local foot = meta.footer and (' data-foot="' .. attr_escape(stringify(meta.footer)) .. '"') or ''
    blocks:insert(1, pandoc.RawBlock('html', '<div class="' .. cls .. '"' .. foot .. '></div>'))
  end

  if meta.paper then
    local size = stringify(meta.paper)
    if size:match('^[%w%s%.]+$') then
      blocks:insert(1, pandoc.RawBlock('html',
        '<style>@page { size: ' .. size .. ' } @page doc { size: ' .. size .. ' }</style>'))
    else
      pandoc.log.warn('paper: "' .. size .. '" ignored (use e.g. letter, a4, "a4 landscape")')
    end
  end

  doc.meta, doc.blocks = meta, blocks
  return doc
end

-- block transforms first, then the document pass (title / TOC see the result)
return {
  { CodeBlock = code_block, BulletList = bullet_list, Div = div, Para = para,
    RawBlock = raw_block, Table = label_table },
  { Pandoc = Pandoc },
}
