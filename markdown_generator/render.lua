-- diagrams.lua — pandoc Lua filter: ```dot / ```d2 fences → inline SVG.
--
-- Shared by the kitchen-sink app (reading view + Export PDF, `[notes] pdf-filter`)
-- and EXTERNAL_BUILD_AND_OPEN_PDF (bash/external.sh), so a diagram looks the
-- same everywhere. The author (or an AI) writes only structure; colors come
-- from the document's style marker: <div class="doc tokyo-night"></div> picks
-- the `:root:has(.tokyo-night)` palette in friendly_document_styling.css
-- (read at run time — no second copy of the colors). No marker = neutral grays.
--
--   ```dot            Graphviz  (brew install graphviz)
--   ```graphviz       same
--   ```d2             D2        (brew install d2)
--
-- A bad diagram renders as a red error box with the tool's message (line
-- numbers included), never as a silent blank. Results are cached by content
-- in ~/.cache/kitchen-sink/diagrams, so editing text elsewhere never re-runs
-- the tools. WS_DOC_CSS overrides the stylesheet path.

local HOME = os.getenv('HOME') or ''
local CSS = os.getenv('WS_DOC_CSS') or (HOME .. '/.dotfiles/markdown_generator/friendly_document_styling.css')
local CACHE = HOME .. '/.cache/kitchen-sink/diagrams'
local TOOLDIRS = { '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin' }
local VERSION = 'v6'   -- bump to drop cached renders when this file's output changes

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

-- ── palette from the stylesheet ────────────────────────────────────────────
local template = nil

local function palette(name)
  if not name then return nil end
  local css = read(CSS)
  if not css then return nil end
  local body = css:match(':root:has%(%.' .. name:gsub('%-', '%%-') .. '%)%s*(%b{})')
  if not body then return nil end
  local p = {}
  for k, v in body:gmatch('%-%-p%-([%w%-]+):%s*([^;]+);') do p[k] = v:gsub('%s+$', '') end
  return p.bg and p or nil
end

-- the palette of the app's theme layer (`:root { --p-bg: …}` in the header file the
-- app passes as -M ws-header=PATH): colors a document that has no style marker
local base = nil

local function header_palette(path)
  local css = path and read(path)
  if not css then return nil end
  for body in css:gmatch(':root%s*(%b{})') do
    if body:find('%-%-p%-bg') then
      local p = {}
      for k, v in body:gmatch('%-%-p%-([%w%-]+):%s*([^;]+);') do p[k] = v:gsub('%s+$', '') end
      return p
    end
  end
  return nil
end

-- the marker line: <div class="doc NAME clean" ...></div> (any RawBlock)
local function detect(doc)
  if doc.meta['ws-header'] then base = header_palette(pandoc.utils.stringify(doc.meta['ws-header'])) end
  for _, b in ipairs(doc.blocks) do
    if b.t == 'RawBlock' and b.format == 'html' then
      local cls = b.text:match('<div%s+class="doc%s+([^"]*)"')
      if cls then
        for w in cls:gmatch('%S+') do
          if w ~= 'clean' and palette(w) then template = w break end
        end
        break
      end
    end
  end
  return nil
end

-- ── running the tools ──────────────────────────────────────────────────────
local function run(cmd)
  local p = io.popen(cmd .. ' 2>&1')
  local out = p:read('*a')
  local ok = p:close()
  return ok, out
end

local function cached(key, build)
  os.execute('mkdir -p ' .. q(CACHE))
  local path = CACHE .. '/' .. pandoc.sha1(VERSION .. '\0' .. key) .. '.svg'
  local hit = read(path)
  if hit and #hit > 0 then return true, hit end
  local ok, svg = build()
  if ok then write(path, svg) end
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
local function dot_defaults(p)
  local c = p or { bg = '#ffffff', text = '#1d1d1f', dim = '#6e6e73', accent = '#2b6cb0',
                   well = '#f5f5f7', s0 = '#f0f0f3', rule = '#c8ccd2' }
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
local function d2_config(p)
  local c = p or { bg = '#ffffff', text = '#1d1d1f', dim = '#6e6e73', accent = '#2b6cb0',
                   accent2 = '#8250df', well = '#f5f5f7', s0 = '#f0f0f3', s1 = '#e4e6ea', rule = '#c8ccd2' }
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
-- label): it paints a white page with a black block. Drop the masks and, when the
-- document has a palette, lay a page-colored patch behind each label instead.
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
    return true, unmask(svg, p and p.bg)
  end)
end

-- weasyprint draws D2's SVG (nested <svg>, class-based CSS, embedded fonts) wrong
-- when it is inlined in the page, but right as an image: embed it as a vector
-- data URI instead (Graphviz's plain SVG stays inline: its text is real text)
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

local function esc(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

local function render(el)
  local lang = el.classes[1]
  local kind = (lang == 'dot' or lang == 'graphviz') and 'dot' or (lang == 'd2' and 'd2' or nil)
  if not kind then return nil end
  local p = palette(template) or base
  local ok, out
  if kind == 'dot' then ok, out = render_dot(el.text, p) else ok, out = render_d2(el.text, p) end
  if not ok then
    return pandoc.RawBlock('html',
      '<pre class="diagram-error"><strong>' .. kind .. ' diagram failed</strong>\n' .. esc(tidy_error(kind, out)) .. '</pre>')
  end
  if kind == 'd2' then out = as_image(out) end
  return pandoc.RawBlock('html', '<figure class="diagram ' .. kind .. '">' .. out .. '</figure>')
end

return { { Pandoc = detect }, { CodeBlock = render } }
