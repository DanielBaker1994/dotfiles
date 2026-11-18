-- prose.lua — kitchen-sink's ◐ document-style picker, ported to nvim.
--
--   <leader>mds / :ProseStyle [name]   pick a document style (tokyo-night,
--                                      paper, …): edits the
--                                      `<div class="doc NAME">` marker on line 1.
--   <leader>mdo                        build + open the document (core.lua).
--
-- Markdown buffers get a clickable winbar: `≡ Prose` (= <leader>mdo) and
-- `◐ style` (= <leader>mds). Set vim.g.prose_winbar = false to turn it off.
local M = {}

local CSS = vim.fn.fnamemodify(vim.fn.resolve(vim.fn.stdpath('config')) .. '/../markdown_generator', ':p')
  .. 'friendly_document_styling.css'

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
end

function M.pick_style()
  local buf = vim.api.nvim_get_current_buf()
  local names = M.styles()
  if #names == 0 then
    vim.notify('no document styles found in ' .. CSS, vim.log.levels.WARN)
    return
  end
  local cur = M.current_style(buf)
  vim.ui.select(vim.list_extend({ '(none)' }, names), {
    prompt = 'Document style',
    format_item = function(n)
      local on = (n == '(none)' and not cur) or n == cur
      return (on and '● ' or '  ') .. n
    end,
  }, function(choice)
    if choice then M.set_style(buf, choice ~= '(none)' and choice or nil) end
  end)
end

-- ── clickable winbar: ≡ Prose | ◐ style ───────────────────────────────────
function _G.ProseWinbarOpen() require('user.db_functions').markdown_open() end
function _G.ProseWinbarStyle() M.pick_style() end

function M.winbar()
  local function seg(fn, label)
    return ('%%@%s@%%#Comment# %s %%*%%X'):format(fn, label)
  end
  return '%=' .. seg('v:lua.ProseWinbarOpen', '≡ Prose')
    .. seg('v:lua.ProseWinbarStyle', '◐ ' .. (M.current_style(0) or 'style')) .. ' '
end

function M.setup()
  vim.api.nvim_create_user_command('ProseStyle', function(o)
    local buf = vim.api.nvim_get_current_buf()
    if o.args ~= '' then M.set_style(buf, o.args ~= 'none' and o.args or nil) else M.pick_style() end
  end, { nargs = '?', desc = 'set the document style marker',
         complete = function() return vim.list_extend({ 'none' }, M.styles()) end })

  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('user_prose', { clear = true }),
    pattern = 'markdown',
    callback = function(ev)
      vim.keymap.set('n', '<leader>mds', M.pick_style, { buffer = ev.buf, desc = 'Markdown: document style' })
      if vim.g.prose_winbar ~= false then
        vim.wo[0][0].winbar = "%{%v:lua.require'user.prose'.winbar()%}"
      end
    end,
  })
end

return M
