-- prose.lua — kitchen-sink's "Prose" reading view and ◐ document-style picker,
-- ported to nvim.
--
--   :Prose        / <leader>mp   toggle the live reading view: the buffer is
--                                rendered with pandoc + the markdown_generator
--                                CSS/filters and opened in the browser; while
--                                on, every edit re-renders and the page reloads
--                                itself, landing on the block under the cursor.
--   :ProseStyle   / <leader>ms   pick a document style (tokyo-night, paper, …):
--                                edits the `<div class="doc NAME">` marker on
--                                line 1 (the same marker the notes app wrote).
--   <leader>me                   export: PDF (+PNG) beside the file, opened in
--                                Preview (after/plugin/core.lua).
--
-- Markdown buffers also get a clickable winbar (≡ Prose | </> nvim | ◐ style);
-- set vim.g.prose_winbar = false before setup() to turn it off.
local M = {}

local gen = vim.fn.resolve(vim.fn.stdpath('config')) .. '/../markdown_generator'
gen = vim.fn.fnamemodify(gen, ':p'):gsub('/$', '')
local CSS = gen .. '/friendly_document_styling.css'
local cache = vim.fn.stdpath('cache') .. '/prose'

local live = {}      -- bufnr -> { html, stamp, n, timer }
local opened = {}    -- html paths already handed to the browser

-- ── document style marker (pylib/doc_templates.py) ────────────────────────
local function parse_marker(line)
  local t = vim.trim(line or '')
  if not (t:sub(1, 4) == '<div' and t:sub(-6) == '</div>') then return nil end
  local cls = t:match('class="([^"]*)"')
  if not cls then return nil end
  local words = vim.split(cls, ' ', { plain = true })
  if words[1] ~= 'doc' then return nil end
  return { template = words[2] or '', foot = t:match('data-foot="([^"]*)"') or '' }
end

local function marker(template, foot)
  return ('<div class="doc %s"%s></div>'):format(template, foot ~= '' and (' data-foot="%s"'):format(foot) or '')
end

function M.current_style(buf)
  local m = parse_marker(vim.api.nvim_buf_get_lines(buf or 0, 0, 1, false)[1])
  return m and m.template or nil
end

-- the style names the CSS defines (`:root:has(.NAME) { … --p-bg …}`)
function M.styles()
  local f = io.open(CSS, 'r')
  if not f then return {} end
  local css = f:read('*a')
  f:close()
  local out, seen = {}, {}
  for name, block in css:gmatch(':root:has%(%.([%w_-]+)%)%s*(%b{})') do
    if name ~= 'doc' and not seen[name] and block:find('--p-bg', 1, true) then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

-- set (template = name) or remove (template = nil) the marker on line 1
function M.set_style(buf, template)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 2, false)
  local old = parse_marker(lines[1])
  if not old and not template then return end
  if not old then
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { marker(template, ''), '' })
  elseif not template then
    local blank_after = lines[2] and vim.trim(lines[2]) == ''
    vim.api.nvim_buf_set_lines(buf, 0, blank_after and 2 or 1, false, {})
  else
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { marker(template, old.foot) })
  end
  if live[buf] then M.render(buf) end
end

function M.pick_style()
  local buf = vim.api.nvim_get_current_buf()
  local names = M.styles()
  if #names == 0 then
    vim.notify('no document styles found in ' .. CSS, vim.log.levels.WARN)
    return
  end
  local cur = M.current_style(buf)
  local items = vim.list_extend({ '(none)' }, names)
  vim.ui.select(items, {
    prompt = 'Document style',
    format_item = function(n)
      local on = (n == '(none)' and not cur) or n == cur
      return (on and '● ' or '  ') .. n
    end,
  }, function(choice)
    if not choice then return end
    M.set_style(buf, choice ~= '(none)' and choice or nil)
  end)
end

-- ── rendering ─────────────────────────────────────────────────────────────
-- pandoc's gfm+sourcepos wraps inline runs in spans and splits task-list
-- items; this filter (kitchen-sink's sourcepos-fix.lua) undoes both.
local SOURCEPOS_FIX = [[
function Span(el)
  if el.attributes.wrapper == "1" and #el.content > 0 then
    for _, x in ipairs(el.content) do
      if x.t ~= "RawInline" then return nil end
    end
    return el.content
  end
end

local box = { ["☐"] = true, ["☒"] = true }
function BulletList(el)
  for i, item in ipairs(el.content) do
    local a, b = item[1], item[2]
    if a and b and a.t == "Plain" and #a.content == 1 and a.content[1].t == "Str"
        and box[a.content[1].text] and b.t == "Div" and b.content[1]
        and (b.content[1].t == "Plain" or b.content[1].t == "Para") then
      local first = b.content[1]
      local inl = pandoc.List({ a.content[1], pandoc.Space() })
      inl:extend(first.content)
      first.content = inl
      local blocks = pandoc.List({ first })
      for j = 2, #b.content do blocks:insert(b.content[j]) end
      for j = 3, #item do blocks:insert(item[j]) end
      el.content[i] = blocks
    end
  end
  return el
end
]]

local function write(path, text)
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end

local function file_url(p)
  return 'file://' .. p:gsub('[^%w/%._~-]', function(c) return ('%%%02X'):format(c:byte()) end)
end

-- Header spliced into every render: <base> so relative images resolve beside
-- the note, and a poller that reloads when the stamp file changes (a <script>
-- tag may load file:// from file://; fetch/XHR may not), then lands on the
-- source line nvim's cursor was on.
local function head_html(dir, stamp, line)
  return ([[
<base href="%s/">
<style>[data-prose-here]{scroll-margin-top:12px}</style>
<script>
(function () {
  var STAMP = %q, LINE = %d, seen = null;
  function land() {
    var best = null, bl = -1;
    document.querySelectorAll('[data-pos]').forEach(function (e) {
      var m = /(\d+):\d+-\d+:\d+$/.exec(e.getAttribute('data-pos') || '');
      var l = m ? +m[1] : NaN;
      if (!isNaN(l) && l <= LINE && l >= bl) { bl = l; best = e; }
    });
    if (best) window.scrollTo(0, best.getBoundingClientRect().top + window.scrollY - 12);
  }
  window.addEventListener('load', land);
  window.__proseTick = function (n) {
    if (seen === null) { seen = n; return; }
    if (n !== seen) location.reload();
  };
  function poll() {
    var s = document.createElement('script');
    s.src = STAMP + '?' + Date.now();
    s.onload = s.onerror = function () { s.remove(); };
    document.head.appendChild(s);
  }
  setInterval(poll, 600);
  poll();
})();
</script>
]]):format(file_url(dir), file_url(stamp), line)
end

function M.render(buf, open_after)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if vim.fn.executable('pandoc') == 0 then
    vim.notify('prose: pandoc is not installed', vim.log.levels.ERROR)
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  local dir = name ~= '' and vim.fn.fnamemodify(name, ':p:h') or vim.fn.getcwd()
  local stem = name ~= '' and vim.fn.fnamemodify(name, ':t:r') or 'scratch'
  vim.fn.mkdir(cache, 'p')
  local id = stem:gsub('[^%w_-]', '_') .. '-' .. vim.fn.sha256(name ~= '' and name or tostring(buf)):sub(1, 8)
  local html, stamp = cache .. '/' .. id .. '.html', cache .. '/' .. id .. '.stamp.js'
  local head = cache .. '/' .. id .. '.head.html'
  local fix = cache .. '/sourcepos-fix.lua'
  write(fix, SOURCEPOS_FIX)

  local line = 1
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do line = vim.api.nvim_win_get_cursor(w)[1] break end
  write(head, head_html(dir, stamp, line))

  local resources = dir .. ':' .. gen
  if vim.env.ASSET_PICTURES_DIRECTORY_GLOBAL then resources = resources .. ':' .. vim.env.ASSET_PICTURES_DIRECTORY_GLOBAL end
  local cmd = { 'pandoc', '-s', '-f', 'gfm+sourcepos', '-t', 'html5',
    '--syntax-highlighting=tango', '-V', 'lang=en',
    '--metadata', 'pagetitle=' .. stem,
    '--resource-path=' .. resources,
    '--lua-filter=' .. fix }
  if vim.fn.filereadable(gen .. '/diagrams.lua') == 1 then cmd[#cmd + 1] = '--lua-filter=' .. gen .. '/diagrams.lua' end
  cmd[#cmd + 1] = '--include-in-header=' .. head
  for _, h in ipairs({ CSS, gen .. '/copy_button.css' }) do
    if vim.fn.filereadable(h) == 1 then cmd[#cmd + 1] = '--include-in-header=' .. h end
  end
  if vim.fn.filereadable(gen .. '/copy_button.js') == 1 then
    cmd[#cmd + 1] = '--include-after-body=' .. gen .. '/copy_button.js'
  end
  vim.list_extend(cmd, { '-o', html, '-' })

  -- render what's in the buffer, saved or not
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') .. '\n'
  vim.system(cmd, { stdin = text, cwd = dir, text = true }, vim.schedule_wrap(function(r)
    if r.code ~= 0 then
      vim.notify('prose: pandoc failed: ' .. vim.trim(r.stderr or ''), vim.log.levels.ERROR)
      return
    end
    local st = live[buf]
    local n = st and (st.n + 1) or 1
    if st then st.n = n end
    write(stamp, ('window.__proseTick && window.__proseTick(%d);'):format(vim.uv.hrtime() % 1e12 + n))
    if open_after or not opened[html] then
      opened[html] = true
      vim.ui.open(html)
    end
  end))
  return html
end

local function stop(buf)
  local st = live[buf]
  if not st then return end
  if st.timer then st.timer:stop(); st.timer:close() end
  pcall(vim.api.nvim_del_augroup_by_name, 'prose_live_' .. buf)
  live[buf] = nil
end

function M.is_live(buf)
  return live[(buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf] ~= nil
end

function M.toggle(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  if live[buf] then
    stop(buf)
    vim.notify('Prose: live view off')
    vim.cmd('redrawstatus!')
    return
  end
  local st = { n = 0, timer = vim.uv.new_timer() }
  live[buf] = st
  local g = vim.api.nvim_create_augroup('prose_live_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'BufWritePost' }, {
    group = g, buffer = buf,
    callback = function()
      st.timer:stop()
      st.timer:start(350, 0, vim.schedule_wrap(function()
        if live[buf] and vim.api.nvim_buf_is_valid(buf) then M.render(buf) end
      end))
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufWipeout', 'BufDelete' }, {
    group = g, buffer = buf, callback = function() stop(buf) end,
  })
  M.render(buf, true)
  vim.cmd('redrawstatus!')
end

-- ── clickable winbar: ≡ Prose | </> nvim | ◐ style ────────────────────────
function _G.ProseWinbarProse() if not M.is_live() then M.toggle() end end
function _G.ProseWinbarNvim() if M.is_live() then M.toggle() end end
function _G.ProseWinbarStyle() M.pick_style() end

function M.winbar()
  local on = M.is_live()
  local style = M.current_style(0) or 'none'
  local function seg(fn, label, active)
    return ('%%@%s@%%#%s# %s %%*%%X'):format(fn, active and 'PmenuSel' or 'Comment', label)
  end
  return '%=' .. seg('v:lua.ProseWinbarProse', '≡ Prose', on)
    .. seg('v:lua.ProseWinbarNvim', '</> nvim', not on)
    .. '  ' .. seg('v:lua.ProseWinbarStyle', '◐ ' .. style, false) .. ' '
end

function M.setup()
  vim.api.nvim_create_user_command('Prose', function() M.toggle() end, { desc = 'toggle the live markdown reading view' })
  vim.api.nvim_create_user_command('ProseOnce', function() M.render(0, true) end, { desc = 'render the markdown reading view once' })
  vim.api.nvim_create_user_command('ProseStyle', function(o)
    if o.args ~= '' then M.set_style(0, o.args ~= 'none' and o.args or nil) else M.pick_style() end
  end, { nargs = '?', desc = 'set the document style marker',
         complete = function() return vim.list_extend({ 'none' }, M.styles()) end })

  local g = vim.api.nvim_create_augroup('user_prose', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = g, pattern = 'markdown',
    callback = function(ev)
      vim.keymap.set('n', '<leader>mp', M.toggle, { buffer = ev.buf, desc = 'Prose: toggle live reading view' })
      vim.keymap.set('n', '<leader>ms', M.pick_style, { buffer = ev.buf, desc = 'Prose: pick document style' })
      if vim.g.prose_winbar ~= false then
        vim.wo[0][0].winbar = "%{%v:lua.require'user.prose'.winbar()%}"
      end
    end,
  })
end

return M
