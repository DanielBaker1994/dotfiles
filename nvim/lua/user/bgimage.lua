-- Full-editor background photo behind the text, using the kitty graphics
-- protocol directly (no image.nvim: it re-encodes, re-sends the whole PNG and
-- auto-clears on BufLeave/TabEnter). The terminal reads the file itself (t=f),
-- so only a tiny escape is written. z=-1 draws above cell backgrounds, under
-- text. Opacity is baked into a small cropped copy (blended onto the bg colour)
-- because the protocol has none.
-- Photo: "Toshogu Shrine, Nikko - ToshoguShrine7875.jpg", Wikimedia Commons, CC0.
local M = {}

local cfg = {
    src = vim.fn.expand('~/.dotfiles/nvim/images/nikko-toshogu.jpg'),
    opacity = 0.05, -- 0.1 subtle .. 0.5 bold
    bg = '#1a1b26',
    max_px = 1600,  -- baked width cap; the terminal scales it to the window
}
local enabled, timer, last = false, nil, nil
local ESC = '\27'

local function write(seq)
    if vim.env.TMUX then -- tmux passthrough wrapper
        seq = ESC .. 'Ptmux;' .. seq:gsub(ESC, ESC .. ESC) .. ESC .. '\\'
    end
    -- stderr is the pane's terminal; /dev/tty can't be opened under herdr
    pcall(vim.api.nvim_chan_send, vim.v.stderr, seq)
end

local function kitty(ctrl, payload)
    return ESC .. '_G' .. ctrl .. ';' .. (payload or '') .. ESC .. '\\'
end

local function clear() write(kitty('a=d,d=I,i=7331,q=2')) end

local function place(path)
    local cols, rows = vim.o.columns, vim.o.lines
    -- save cursor, home, transmit+display by file path, restore cursor
    write(ESC .. '7' .. ESC .. '[1;1H'
        .. kitty(('a=T,f=100,t=f,i=7331,p=1,z=-1,c=%d,r=%d,C=1,q=2'):format(cols, rows), vim.base64.encode(path))
        .. ESC .. '8')
    last = path
end

local function render()
    if not enabled then return end
    local cols, rows = vim.o.columns, vim.o.lines
    local ok, term = pcall(function() return require('image.utils.term').get_size() end)
    local cw = (ok and term and term.cell_width > 0) and term.cell_width or 8
    local ch = (ok and term and term.cell_height > 0) and term.cell_height or 16
    local w, h = cols * cw, rows * ch
    local s = math.min(1, cfg.max_px / w)
    w, h = math.floor(w * s), math.floor(h * s)
    local out = ('%s/bgimage_%dx%d_%d.png'):format(vim.fn.stdpath('cache'), cols, rows, cfg.opacity * 100)
    if vim.uv.fs_stat(out) then return place(out) end
    vim.system({ 'magick', cfg.src, '-resize', ('%dx%d^'):format(w, h), '-gravity', 'center',
            '-extent', ('%dx%d'):format(w, h), '-fill', cfg.bg, '-colorize', tostring(100 - cfg.opacity * 100),
            '-define', 'png:compression-level=3', out }, {},
        vim.schedule_wrap(function(r)
            if r.code == 0 then
                if enabled and vim.o.columns == cols and vim.o.lines == rows then place(out) end
            else
                vim.notify('bgimage: magick failed: ' .. (r.stderr or ''), vim.log.levels.WARN)
            end
        end))
end

local function debounced(ms)
    if not enabled then return end
    if timer then timer:stop() else timer = vim.uv.new_timer() end
    timer:start(ms or 120, 0, vim.schedule_wrap(render))
end

function M.toggle()
    enabled = not enabled
    if enabled then render() else clear() end
end

function M.setup(opts)
    cfg = vim.tbl_extend('force', cfg, opts or {})
    enabled = true
    local g = vim.api.nvim_create_augroup('bgimage', { clear = true })
    vim.api.nvim_create_user_command('BgImage', M.toggle, { desc = 'Toggle background photo' })
    vim.api.nvim_create_autocmd({ 'VimResized', 'FocusGained', 'VimResume', 'ColorScheme' },
        { group = g, callback = function() debounced() end })
    vim.api.nvim_create_autocmd('VimLeavePre', { group = g, callback = clear })
    -- (re)draw once the UI is attached; again shortly after in case the first
    -- draw raced the terminal/multiplexer setup
    vim.api.nvim_create_autocmd('UIEnter', {
        group = g,
        once = true,
        callback = function()
            debounced(30); vim.defer_fn(function() if enabled and last then place(last) end end, 600)
        end
    })
end

return M
