-- Interactive DiffviewFileHistory filter builder as a floating-window TUI.
-- The main window is an option form: navigate with j/k, Enter to edit or
-- toggle, d to clear a filter, r to run, c to reset, q/Esc to close. The live
-- command is always shown at the top. Editing opens a floating input whose
-- value is validated before it's accepted (invalid input shows a toast and
-- lets you retry). Esc in the input cancels.
local M = {}

-- -------------------------------------------------------------------- state
local state = {
    -- chips = { { key, kind = 'flag'|'path', raw, val } }
    chips = {},
    current_file = false,
}

local main_buf, main_win, input_win = nil, nil, nil
local cursor_row = 1
local FIRST_ROW = 3
local NS = vim.api.nvim_create_namespace('git_history_tui')

local function shell(args)
    vim.fn.system(args)
    return vim.v.shell_error == 0
end

-- ---------------------------------------------------------------- validators
local function nonempty(v)
    return true, v
end

local function parse_range(v)
    if v:find('%s') then
        return false, 'no spaces — e.g. main..HEAD, HEAD~5..'
    end
    if not shell({ 'git', 'rev-list', '--max-count=1', v }) then
        return false, 'refs must exist — e.g. main..HEAD, HEAD~5..'
    end
    return true, v
end

local function parse_pickaxe(v)
    if v:match('^-') then
        return false, 'string cannot start with "-" — e.g. fix_typo'
    end
    return true, v
end

local function parse_regex(v)
    if v:match('^-') then
        return false, 'regex cannot start with "-" — e.g. foo[0-9]'
    end
    if v:find('[^\\]%*%*') or v:find('^%*%*') then
        return false, '"**" is not valid regex — e.g. "bat**no-page" → use "bat.*no-page" '
            .. 'or "bat\\*\\*no-page"'
    end
    if not shell({ 'git', 'log', '-1', '--format=%H', '-G' .. v }) then
        return false, 'not a valid regex — e.g. "foo[0-9]" or "bat.*no-page"'
    end
    return true, v
end

local days_in_month = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function is_date(yyyymmdd)
    local y, m, d = yyyymmdd:match('^(%d%d%d%d)(%d%d)(%d%d)$')
    if not y then
        return false
    end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if m < 1 or m > 12 then
        return false
    end
    local leap = (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
    local dim = days_in_month[m]
    if m == 2 and leap then
        dim = 29
    end
    return d >= 1 and d <= dim
end

local function norm_date(yyyymmdd)
    return yyyymmdd:sub(1, 4) .. '-' .. yyyymmdd:sub(5, 6) .. '-' .. yyyymmdd:sub(7, 8)
end

-- "YYYYMMDD<Tab>YYYYMMDD" (or space-separated). Leading whitespace means the
-- first token is the end date (until-only). Either side may be omitted.
local function parse_dates(v)
    local tokens = {}
    for t in v:gmatch('%S+') do
        tokens[#tokens + 1] = t
    end
    if #tokens == 0 then
        return false, 'need at least one date'
    end
    if #tokens > 2 then
        return false, 'two dates only — YYYYMMDD [tab] YYYYMMDD'
    end
    for _, t in ipairs(tokens) do
        if not is_date(t) then
            return false, t .. ' is not a valid YYYYMMDD date'
        end
    end
    local until_only = v:match('^%s') ~= nil
    local start, stop
    if until_only then
        start, stop = nil, tokens[1]
    else
        start, stop = tokens[1], tokens[2]
    end
    return true, {
        since = start and norm_date(start) or nil,
        stop = stop and norm_date(stop) or nil,
    }
end

local filters = {
    { key = 'range',   name = 'Range',                     hint = 'main..HEAD, HEAD~5..',         parse = parse_range },
    { key = 'grep',    name = 'Message contains',          hint = 'fix',                          parse = nonempty },
    { key = 'author',  name = 'Author',                    hint = 'daniel',                       parse = nonempty },
    { key = 'dates',   name = 'Date range',                hint = 'YYYYMMDD [tab] YYYYMMDD',      parse = parse_dates },
    { key = 'pickaxe', name = 'Content exact string (-S)', hint = 'literal e.g. bat**no-page',   parse = parse_pickaxe },
    { key = 'regex',   name = 'Content regex (-G)',        hint = 'e.g. bat.*no-page',            parse = parse_regex },
    { key = 'path',    name = 'Files touched',             hint = '*telescope*',                  parse = nonempty, pathspec = true },
    { current_file = true, name = 'Limit to current file' },
}

-- ------------------------------------------------------------------ helpers
local flags = {
    range = '--range=', grep = '--grep=', author = '--author=',
    pickaxe = '-S', regex = '-G',
}

local function chip_by_key(key)
    for _, c in ipairs(state.chips) do
        if c.key == key then
            return c
        end
    end
end

local function remove_chips(keys)
    for i = #state.chips, 1, -1 do
        for _, k in ipairs(keys) do
            if state.chips[i].key == k then
                table.remove(state.chips, i)
                break
            end
        end
    end
end

local function upsert(key, raw, val)
    remove_chips { key }
    table.insert(state.chips, { key = key, kind = 'flag', raw = raw, val = val })
end

local function command_str()
    local parts = { 'DiffviewFileHistory' }
    if state.current_file then
        table.insert(parts, vim.fn.fnameescape(vim.fn.expand('%:p')))
    end
    local paths = {}
    for _, c in ipairs(state.chips) do
        if c.kind == 'flag' then
            table.insert(parts, vim.fn.fnameescape(c.raw))
        else
            table.insert(paths, c.raw)
        end
    end
    if #paths > 0 then
        table.insert(parts, '--')
        for _, p in ipairs(paths) do
            table.insert(parts, vim.fn.fnameescape(p))
        end
    end
    return table.concat(parts, ' ')
end

local function value_display(f)
    if f.key == 'dates' then
        local s = chip_by_key('since')
        local u = chip_by_key('until')
        if not s and not u then
            return ''
        end
        return (s and s.val or '') .. (s and u and ' ~ ' or '') .. (u and u.val or '')
    end
    if f.pathspec then
        local vals = {}
        for _, c in ipairs(state.chips) do
            if c.kind == 'path' then
                vals[#vals + 1] = c.val
            end
        end
        return table.concat(vals, ', ')
    end
    local c = chip_by_key(f.key)
    return c and c.val or ''
end

local function default_for(f)
    if f.key == 'dates' then
        local parts = {}
        local s = chip_by_key('since')
        local u = chip_by_key('until')
        if s then
            parts[#parts + 1] = s.raw:gsub('^--since=', ''):gsub('%-', '')
        end
        if u then
            parts[#parts + 1] = u.raw:gsub('^--until=', ''):gsub('%-', '')
        end
        return table.concat(parts, '\t')
    end
    local c = f.pathspec and nil or chip_by_key(f.key)
    return c and c.raw:sub(#flags[f.key] + 1) or ''
end

local function apply(f, payload)
    if f.key == 'dates' then
        remove_chips { 'since', 'until' }
        if payload.since then
            upsert('since', '--since=' .. payload.since, payload.since)
        end
        if payload.stop then
            upsert('until', '--until=' .. payload.stop, payload.stop)
        end
    elseif f.pathspec then
        table.insert(state.chips, { key = 'path', kind = 'path', raw = payload, val = payload })
    else
        upsert(f.key, flags[f.key] .. payload, payload)
    end
end

-- --------------------------------------------------------------------- TUI
local function layout_lines()
    local lines = {}
    lines[1] = '  ' .. command_str()
    lines[2] = '  ' .. string.rep('─', 60)
    for i, f in ipairs(filters) do
        if f.current_file then
            lines[#lines + 1] = string.format('  %d. %s %s', i,
                state.current_file and '[x]' or '[ ]', f.name)
        else
            lines[#lines + 1] = string.format('  %d. %-26s %s', i, f.name, value_display(f))
        end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  j/k move · Enter edit/toggle · d clear · r run · c reset · q quit'
    return lines
end

local function render()
    if not (main_buf and main_win and vim.api.nvim_win_is_valid(main_win)) then
        return
    end
    local lines = layout_lines()
    vim.api.nvim_buf_set_lines(main_buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(main_buf, NS, 0, -1)
    vim.api.nvim_buf_add_highlight(main_buf, NS, 'Title', 0, 0, -1)
    vim.api.nvim_buf_add_highlight(main_buf, NS, 'Comment', 1, 0, -1)
    vim.api.nvim_buf_add_highlight(main_buf, NS, 'Comment', #lines - 1, 0, -1)
    cursor_row = math.max(FIRST_ROW, math.min(cursor_row, FIRST_ROW + #filters - 1))
    vim.api.nvim_win_set_cursor(main_win, { cursor_row, 0 })
end

local function move(delta)
    cursor_row = math.max(FIRST_ROW, math.min(cursor_row + delta, FIRST_ROW + #filters - 1))
    vim.api.nvim_win_set_cursor(main_win, { cursor_row, 0 })
end

local function filter_at_cursor()
    local i = cursor_row - FIRST_ROW + 1
    return filters[i]
end

local function close_input()
    if input_win and vim.api.nvim_win_is_valid(input_win) then
        vim.api.nvim_win_close(input_win, true)
    end
    input_win = nil
    if main_win and vim.api.nvim_win_is_valid(main_win) then
        vim.api.nvim_set_current_win(main_win)
        vim.cmd('stopinsert')
    end
end

-- Split 'A..B' / 'A...B' / 'A' into (left, right).
local function parse_range_sides(value)
    local left, right = value:match('^(.-)%.%.%.(.*)$')
    if left then
        return left, right or ''
    end
    left, right = value:match('^(.-)%.%.(.*)$')
    if left then
        return left, right or ''
    end
    return value, ''
end

-- Generic single-row editor for the simple filters.
local function edit_input(f)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false

    local width = 56
    local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        row = math.floor(vim.o.lines / 2) - 1,
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = 1,
        style = 'minimal',
        border = 'rounded',
        title = ' ' .. f.name .. ' (' .. f.hint .. ') ',
        noautocmd = true,
    })
    input_win = win

    local default = default_for(f)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { default })
    vim.api.nvim_win_set_cursor(win, { 1, #default })

    local function submit()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
        local value = vim.trim(lines[1] or '')
        if value == '' then
            close_input()
            return
        end
        local ok, payload = f.parse(value)
        if ok then
            apply(f, payload)
            close_input()
            render()
        else
            vim.notify('Invalid ' .. f.name .. ': ' .. payload, vim.log.levels.ERROR)
        end
    end

    vim.keymap.set('i', '<CR>', submit, { buffer = buf })
    vim.keymap.set('i', '<Esc>', close_input, { buffer = buf })
    vim.keymap.set('i', '<C-c>', close_input, { buffer = buf })

    -- If the input is closed some other way (e.g. <C-w>q), make sure focus
    -- returns to the main window in Normal mode — otherwise j/k keep typing.
    vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(win),
        once = true,
        callback = function()
            input_win = nil
            if main_win and vim.api.nvim_win_is_valid(main_win) then
                vim.api.nvim_set_current_win(main_win)
                vim.cmd('stopinsert')
            end
        end,
    })

    vim.cmd('startinsert')
end

-- Range editor: two side-by-side cells — the "from" ref on the left, the "to"
-- ref on the right — joined by a '..' label. Enter moves left -> right, and
-- submits from the right cell. Esc cancels.
local function edit_range(f)
    local left, right = parse_range_sides(default_for(f))
    local closed = false
    local cells = {}

    local function cell_value(buf)
        local l = vim.api.nvim_buf_get_lines(buf, 0, 1, false)
        return vim.trim(l[1] or '')
    end

    local function finish(value)
        if closed then
            return
        end
        closed = true
        for _, w in ipairs(cells) do
            if vim.api.nvim_win_is_valid(w) then
                pcall(vim.api.nvim_win_close, w, true)
            end
        end
        input_win = nil
        if main_win and vim.api.nvim_win_is_valid(main_win) then
            vim.api.nvim_set_current_win(main_win)
            vim.cmd('stopinsert')
        end
        if value then
            local ok, payload = f.parse(value)
            if ok then
                apply(f, payload)
                render()
            else
                vim.notify('Invalid Range: ' .. payload, vim.log.levels.ERROR)
            end
        end
    end

    local function open_cell(col, title, initial)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].bufhidden = 'wipe'
        vim.bo[buf].buftype = 'nofile'
        vim.bo[buf].swapfile = false
        local win = vim.api.nvim_open_win(buf, true, {
            relative = 'editor',
            row = math.floor(vim.o.lines / 2) - 1,
            col = col,
            width = 24,
            height = 1,
            style = 'minimal',
            border = 'rounded',
            title = ' ' .. title .. ' ',
            noautocmd = true,
        })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { initial })
        vim.api.nvim_win_set_cursor(win, { 1, #initial })
        table.insert(cells, win)
        vim.api.nvim_create_autocmd('WinClosed', {
            pattern = tostring(win),
            once = true,
            callback = function()
                finish(nil)
            end,
        })
        return buf, win
    end

    local center = math.floor(vim.o.columns / 2)

    -- '..' label between the two cells
    local lbl = vim.api.nvim_create_buf(false, true)
    vim.bo[lbl].buftype = 'nofile'
    vim.api.nvim_buf_set_lines(lbl, 0, -1, false, { ' .. ' })
    local lbl_win = vim.api.nvim_open_win(lbl, false, {
        relative = 'editor',
        row = math.floor(vim.o.lines / 2) - 1,
        col = center - 3,
        width = 6,
        height = 1,
        style = 'minimal',
        border = 'none',
        noautocmd = true,
    })
    table.insert(cells, lbl_win)

    local left_buf, left_win = open_cell(center - 30, 'from', left)
    local right_buf, right_win = open_cell(center + 3, 'to', right)

    local function submit_left()
        left = cell_value(left_buf)
        if vim.api.nvim_win_is_valid(right_win) then
            vim.api.nvim_set_current_win(right_win)
        end
        vim.cmd('startinsert')
    end

    local function submit_right()
        right = cell_value(right_buf)
        local value
        if left ~= '' and right ~= '' then
            value = left .. '..' .. right
        elseif left ~= '' then
            value = left
        elseif right ~= '' then
            value = right
        end
        if not value then
            finish(nil)
            return
        end
        local ok, payload = f.parse(value)
        if not ok then
            vim.notify('Invalid Range: ' .. payload, vim.log.levels.ERROR)
            return
        end
        finish(value)
    end

    local function cancel()
        finish(nil)
    end

    vim.keymap.set('i', '<CR>', submit_left, { buffer = left_buf })
    vim.keymap.set('i', '<Tab>', submit_left, { buffer = left_buf })
    vim.keymap.set('i', '<Esc>', cancel, { buffer = left_buf })
    vim.keymap.set('i', '<C-c>', cancel, { buffer = left_buf })
    vim.keymap.set('i', '<CR>', submit_right, { buffer = right_buf })
    vim.keymap.set('i', '<Esc>', cancel, { buffer = right_buf })
    vim.keymap.set('i', '<C-c>', cancel, { buffer = right_buf })

    vim.api.nvim_set_current_win(left_win)
    vim.cmd('startinsert')
end

-- Author: fuzzy-pick from git authors (collected once when the filter opens).
local function edit_author()
    local authors, seen = {}, {}
    local raw = vim.fn.system({ 'git', 'log', '--format=%an <%ae>', '--all' })
    for line in (raw or ''):gmatch('[^\n]+') do
        if not seen[line] then
            seen[line] = true
            table.insert(authors, line)
        end
    end
    if #authors == 0 then
        vim.notify('No git authors found', vim.log.levels.WARN)
        return
    end
    table.sort(authors)

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local conf = require('telescope.config').values

    pickers.new({}, {
        prompt_title = ' Author ',
        finder = finders.new_table { results = authors },
        sorter = type(conf.generic_sorter) == 'function' and conf.generic_sorter()
            or require('telescope.sorters').get_fzy_sorter(),
        attach_mappings = function(prompt_bufnr, _)
            actions.select_default:replace(function()
                local entry = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if entry and entry.value and entry.value ~= '' then
                    local name = entry.value:gsub('%s*<.*$', '')
                    upsert('author', '--author=' .. name, name)
                    render()
                end
            end)
            return true
        end,
    }):find()
end

local function edit_filter(f)
    if f.key == 'range' then
        edit_range(f)
    elseif f.key == 'author' then
        edit_author()
    else
        edit_input(f)
    end
end

local function activate()
    local f = filter_at_cursor()
    if not f then
        return
    end
    if f.current_file then
        state.current_file = not state.current_file
        render()
    else
        edit_filter(f)
    end
end

local function clear_current()
    local f = filter_at_cursor()
    if not f then
        return
    end
    if f.current_file then
        state.current_file = false
    elseif f.key == 'dates' then
        remove_chips { 'since', 'until' }
    elseif f.pathspec then
        remove_chips { 'path' }
    else
        remove_chips { f.key }
    end
    render()
end

local function clear_all()
    state.chips = {}
    state.current_file = false
    render()
end

local function close_tui()
    close_input()
    if main_win and vim.api.nvim_win_is_valid(main_win) then
        vim.api.nvim_win_close(main_win, true)
    end
    main_win, main_buf = nil, nil
end

local function run()
    local cmd = command_str()
    close_tui()
    vim.notify('Running: ' .. cmd, vim.log.levels.INFO)
    vim.cmd(cmd)
end

local function open_tui()
    local lines_count = 4 + #filters + 1
    local height = math.min(lines_count, vim.o.lines - 4)
    local width = math.min(84, vim.o.columns - 4)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false

    local win = vim.api.nvim_open_win(buf, true, {
        relative = 'editor',
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        width = width,
        height = height,
        style = 'minimal',
        border = 'rounded',
        title = ' git history ',
        noautocmd = true,
    })
    main_buf, main_win = buf, win
    cursor_row = FIRST_ROW

    vim.wo[win].cursorline = true
    vim.wo[win].cursorlineopt = 'line'
    vim.wo[win].number = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].wrap = false

    local opts = { buffer = buf }
    vim.keymap.set('n', 'j', function() move(1) end, opts)
    vim.keymap.set('n', 'k', function() move(-1) end, opts)
    vim.keymap.set('n', '<Down>', function() move(1) end, opts)
    vim.keymap.set('n', '<Up>', function() move(-1) end, opts)
    vim.keymap.set('n', '<CR>', activate, opts)
    vim.keymap.set('n', 'd', clear_current, opts)
    vim.keymap.set('n', 'r', run, opts)
    vim.keymap.set('n', 'c', clear_all, opts)
    vim.keymap.set('n', 'q', close_tui, opts)
    vim.keymap.set('n', '<Esc>', close_tui, opts)

    render()

    vim.api.nvim_create_autocmd('WinClosed', {
        pattern = tostring(win),
        once = true,
        callback = function()
            close_input()
            main_win, main_buf = nil, nil
        end,
    })
end

function M.open()
    open_tui()
end

return M