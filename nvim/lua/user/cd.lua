local M = {}

-- NVIM_CD_TARGETS is defined in bash and prefetched/cached by the
-- bash_external module (see lua/bash_external/cd_targets.lua).
local cd_targets = require('bash_external.cd_targets')

local function get_config()
    return cd_targets.get()
end

-- Workspace root resolution, in priority order:
--   1. A configured root/<prefix>-* worktree that contains the anchor path
--      (cwd, then the current buffer's dir) — structural root/<prefix>-<seg>
--      match first, directory-scan fallback second
--   2. A configured root dir itself that contains the anchor (single-repo roots
--      like ~/.dotfiles, where the prefix matches no subdir)
--   3. The nearest git root (vim.fs.root, from the buffer)
--   4. The current working directory itself
-- Returns ws (absolute) and the matched root entry {root,prefix,targets} (or nil).
local function resolve_workspace()
    local c = get_config()
    local cwd = vim.fn.resolve(vim.fn.getcwd())
    local anchors = { cwd }
    local buf_dir = vim.fn.fnamemodify(vim.fn.expand('%:p'), ':h')
    if buf_dir ~= '' and buf_dir ~= cwd then
        table.insert(anchors, buf_dir)
    end
    if c and c.roots then
        for _, anchor in ipairs(anchors) do
            for _, r in ipairs(c.roots) do
                local root = vim.fn.resolve(vim.fn.expand(r.root))
                if vim.fn.isdirectory(root) == 1 then
                    if r.prefix and r.prefix ~= '' then
                        -- Structural match first: the anchor is inside
                        -- root/<prefix>-<worktree> (even in a subfolder like
                        -- .../JT-123/cpp), so the workspace root is
                        -- root/<prefix>-<first-segment>. This does not depend on
                        -- listing the root dir, which can silently miss worktrees
                        -- and then wrongly scope zoxide results to the subfolder.
                        local base = root .. '/' .. r.prefix .. '-'
                        if vim.startswith(anchor, base) then
                            local seg = anchor:sub(#base + 1):match('^[^/]+')
                            if seg then
                                local dir = vim.fn.resolve(base .. seg)
                                if vim.fn.isdirectory(dir) == 1 then
                                    return dir, r
                                end
                            end
                        end
                        local prefix_match = '^' .. vim.pesc(r.prefix) .. '-'
                        local ok, iter = pcall(vim.fs.dir, root)
                        if ok then
                            for name in iter do
                                if name:match(prefix_match) then
                                    local dir = vim.fn.resolve(root .. '/' .. name)
                                    if anchor == dir or vim.startswith(anchor, dir .. '/') then
                                        return dir, r
                                    end
                                end
                            end
                        end
                    end
                    if anchor == root or vim.startswith(anchor, root .. '/') then
                        return root, r
                    end
                end
            end
        end
    end
    local git_root = vim.fs.root(0, '.git')
    if git_root then
        return vim.fn.resolve(git_root), nil
    end
    return cwd, nil
end

local function get_workspace_root()
    return resolve_workspace()
end

-- Strict workspace boundary for ClearOtherBuffers: returns the matched
-- configured root entry's workspace (nil when not inside a configured root).
local function current_workspace()
    local c = get_config()
    if not c or not c.roots then
        return nil
    end
    return resolve_workspace()
end

-- Query zoxide once and return only paths strictly inside the workspace root.
-- Relative display names are the path minus the workspace prefix.
local function get_scoped_zoxide_paths(ws)
    if vim.fn.executable('zoxide') == 0 then
        return {}
    end
    local res = vim.system({ 'zoxide', 'query', '-l' }, { text = true }):wait()
    if res.code ~= 0 or not res.stdout then
        return {}
    end
    local paths = {}
    local seen = {}
    for line in vim.gsplit(vim.trim(res.stdout), '\n') do
        line = vim.fn.resolve(vim.trim(line))
        if line ~= '' and (line == ws or vim.startswith(line, ws .. '/')) then
            local rel = line == ws and '.' or line:sub(#ws + 2)
            if not seen[rel] then
                seen[rel] = true
                table.insert(paths, { dir = line, rel = rel })
            end
        end
    end
    return paths
end

-- Absolute dir for the active buffer (Oil-aware, falls back to file dir).
local function buffer_dir()
    local ok_oil, oil = pcall(require, 'oil')
    if ok_oil then
        local d = oil.get_current_dir(0)
        if d and d ~= '' then
            return d
        end
    end
    local d = vim.fn.expand('%:p:h')
    if d ~= '' then
        return d
    end
    return nil
end

-- Build the ordered list of picker entries.
-- Each entry: { name = display, dir = absolute path }
local function build_entries()
    local ws, entry = resolve_workspace()
    local entries = {}
    local seen = {}
    local function add(name, dir, exists_check)
        if not dir then
            return
        end
        if exists_check and vim.fn.isdirectory(dir) == 0 then
            return
        end
        if not seen[dir] then
            seen[dir] = true
            table.insert(entries, { name = name, dir = dir })
        end
    end

    if entry and entry.targets then
        for k, sub in pairs(entry.targets) do
            local dir = (sub == '.' or sub == '') and ws or (ws .. '/' .. sub)
            add(k, dir, true)
        end
    end
    add('buffer', buffer_dir(), true)

    for _, p in ipairs(get_scoped_zoxide_paths(ws)) do
        add(p.rel, p.dir, true)
    end

    return entries
end

-- Complete list of selectable names (aliases + relative zoxide subpaths).
function M.names()
    local names = {}
    for _, e in ipairs(build_entries()) do
        table.insert(names, e.name)
    end
    return names
end

function M.cd(name)
    if name == 'buffer' then
        local dir = buffer_dir()
        if dir and vim.fn.isdirectory(dir) == 1 then
            vim.cmd('cd ' .. vim.fn.fnameescape(dir))
            vim.notify('cd ' .. dir, vim.log.levels.INFO)
        else
            vim.notify('cd: not a valid directory: ' .. tostring(dir), vim.log.levels.WARN)
        end
        return
    end

    for _, e in ipairs(build_entries()) do
        if e.name == name then
            if vim.fn.isdirectory(e.dir) == 0 then
                vim.notify('cd: not a directory: ' .. e.dir, vim.log.levels.WARN)
                return
            end
            vim.cmd('cd ' .. vim.fn.fnameescape(e.dir))
            vim.notify('cd ' .. e.dir, vim.log.levels.INFO)
            return
        end
    end
    vim.notify('Unknown cd target: ' .. name, vim.log.levels.WARN)
end

-- Resolve a displayed (tilde) path back to absolute and cd into it.
local function cd_to(dir)
    local home = vim.env.HOME
    if home and vim.startswith(dir, '~/') then
        dir = home .. dir:sub(2)
    elseif dir == '~' then
        dir = home
    end
    if vim.fn.isdirectory(dir) == 1 then
        vim.cmd('cd ' .. vim.fn.fnameescape(dir))
        vim.notify('cd ' .. dir, vim.log.levels.INFO)
    end
end

function M.pick()
    local entries = build_entries()
    if #entries == 0 then
        vim.notify('No cd targets defined', vim.log.levels.WARN)
        return
    end
    -- Buffer is the first/default option.
    table.sort(entries, function(a, b)
        if a.name == 'buffer' then
            return true
        end
        if b.name == 'buffer' then
            return false
        end
        return false
    end)

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
        -- Fallback: plain vim.ui.select (no wide dropdown available).
        local names = {}
        for _, it in ipairs(items) do
            table.insert(names, it.display)
        end
        vim.ui.select(names, { prompt = 'CD target:' }, function(item)
            if item then
                for _, it in ipairs(items) do
                    if it.display == item then
                        cd_to(it.dir)
                        break
                    end
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
            entry_maker = function(item)
                return { value = item.dir, display = item.display, ordinal = item.display }
            end,
        },
        sorter = conf.generic_sorter(theme),
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                actions.close(prompt_bufnr)
                if selection and selection.value then
                    cd_to(selection.value)
                end
            end)
            return true
        end,
    }):find()
end

function M.clear_other_buffers()
    local ws, entry = current_workspace()
    if not ws or not entry then
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