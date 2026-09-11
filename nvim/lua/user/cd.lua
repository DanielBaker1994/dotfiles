-- <leader>cd — pick a directory to cd into.
--
-- The workspace is resolved from the directory nvim was LAUNCHED from
-- (cwd) — never from the open buffer:
--   1. a configured root/<prefix>-<seg> worktree containing the cwd
--      (e.g. ~/jira/JT-1234 from cwd=~/jira/JT-1234/cpp)
--   2. a configured root dir containing the cwd (e.g. ~/.dotfiles)
--   3. the cwd itself
--
-- Entries: the matched root's configured targets (bash/external.sh
-- NVIM_CD_TARGETS), then zoxide results strictly inside the workspace.
local M = {}

local cd_targets = require('bash_external.cd_targets')

local function resolve_workspace()
    local cwd = vim.fn.resolve(vim.fn.getcwd())
    local config = cd_targets.get()
    if config and config.roots then
        for _, r in ipairs(config.roots) do
            local root = vim.fn.resolve(vim.fn.expand(r.root))
            if vim.fn.isdirectory(root) == 1 then
                if r.prefix and r.prefix ~= '' then
                    local base = root .. '/' .. r.prefix .. '-'
                    if vim.startswith(cwd, base) then
                        local seg = cwd:sub(#base + 1):match('^[^/]+')
                        if seg then
                            local dir = vim.fn.resolve(base .. seg)
                            if vim.fn.isdirectory(dir) == 1 then
                                return dir, r
                            end
                        end
                    end
                end
                if cwd == root or vim.startswith(cwd, root .. '/') then
                    return root, r
                end
            end
        end
    end
    return cwd, nil
end

-- { name = display, dir = absolute }: configured targets first (first-wins
-- on duplicate dirs), then zoxide paths inside the workspace.
local function build_entries()
    local ws, entry = resolve_workspace()
    local entries, seen = {}, {}
    local function add(name, dir)
        if dir and not seen[dir] then
            seen[dir] = true
            table.insert(entries, { name = name, dir = dir })
        end
    end
    -- Workspace root is always offered first, then configured targets, then
    -- zoxide paths strictly inside the workspace.
    add('.', ws)
    if entry and entry.targets then
        for name, sub in pairs(entry.targets) do
            add(name, (sub == '.' or sub == '') and ws or (ws .. '/' .. sub))
        end
    end
    if vim.fn.executable('zoxide') == 1 then
        local res = vim.system({ 'zoxide', 'query', '-l' }, { text = true }):wait()
        if res.code == 0 and res.stdout then
            for line in vim.gsplit(vim.trim(res.stdout), '\n') do
                local dir = vim.fn.resolve(vim.trim(line))
                if dir ~= '' and (dir == ws or vim.startswith(dir, ws .. '/')) then
                    add(dir == ws and '.' or dir:sub(#ws + 2), dir)
                end
            end
        end
    end
    return entries
end

function M.cd(name)
    for _, e in ipairs(build_entries()) do
        if e.name == name then
            if vim.fn.isdirectory(e.dir) == 1 then
                vim.cmd('cd ' .. vim.fn.fnameescape(e.dir))
                vim.notify('cd ' .. e.dir, vim.log.levels.INFO)
            else
                vim.notify('cd: not a directory: ' .. e.dir, vim.log.levels.WARN)
            end
            return
        end
    end
    vim.notify('Unknown cd target: ' .. name, vim.log.levels.WARN)
end

function M.pick()
    local entries = build_entries()
    if #entries == 0 then
        vim.notify('No cd targets found', vim.log.levels.WARN)
        return
    end
    local home = vim.env.HOME
    local items = {}
    for _, e in ipairs(entries) do
        local dir = e.dir
        if home and vim.startswith(dir, home .. '/') then
            dir = '~' .. dir:sub(#home + 1)
        end
        table.insert(items, { dir = e.dir, display = dir })
    end

    local ok, telescope = pcall(require, 'telescope')
    if not ok then
        vim.ui.select(vim.tbl_map(function(i) return i.display end, items),
            { prompt = 'CD target:' }, function(display)
                for _, i in ipairs(items) do
                    if i.display == display then
                        vim.cmd('cd ' .. vim.fn.fnameescape(i.dir))
                        vim.notify('cd ' .. i.dir, vim.log.levels.INFO)
                        return
                    end
                end
            end)
        return
    end

    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local actions = require('telescope.actions')
    local action_state = require('telescope.actions.state')
    local themes = require('telescope.themes')

    local theme = themes.get_dropdown({
        layout_config = {
            width = 0.95,
            height = 0.5,
            anchor = 'W',
            anchor_padding = 1,
        },
        prompt_title = 'CD target',
        results_title = '',
    })
    pickers.new(theme, {
        finder = finders.new_table {
            results = items,
            entry_maker = function(i)
                return { value = i.dir, display = i.display, ordinal = i.display }
            end,
        },
        sorter = conf.generic_sorter(theme),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                local sel = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if sel and sel.value then
                    vim.cmd('cd ' .. vim.fn.fnameescape(sel.value))
                    vim.notify('cd ' .. sel.value, vim.log.levels.INFO)
                end
            end)
            return true
        end,
    }):find()
end

-- Close buffers outside the resolved workspace (only inside a configured root).
function M.clear_other_buffers()
    local ws, entry = resolve_workspace()
    if not entry then
        vim.notify('Not inside a configured workspace root', vim.log.levels.WARN)
        return
    end
    local cur = vim.api.nvim_get_current_buf()
    local closed = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= cur and vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted
            and vim.bo[b].buftype == '' then
            local name = vim.api.nvim_buf_get_name(b)
            if name ~= '' and not name:match('^%a+://') then
                local abs = vim.fn.fnamemodify(name, ':p')
                if not (abs == ws or vim.startswith(abs, ws .. '/')) then
                    if pcall(vim.api.nvim_buf_delete, b, { force = true }) then
                        closed = closed + 1
                    end
                end
            end
        end
    end
    vim.notify('Closed ' .. closed .. ' buffer(s) outside workspace', vim.log.levels.INFO)
end

return M