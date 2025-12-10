local pickers = require "telescope.pickers"
local finders = require "telescope.finders"
local make_entry = require "telescope.make_entry"
local conf = require "telescope.config".values
local actions = require "telescope.actions"
local action_state = require "telescope.actions.state"

local M = {}

local ignored_globs = {
    '!.pyi',
    '!.yarn',
    '!.telescope_history',
    '!.html',
    '!.pyc',
    '!.js',
    '!.png',
}

local function add_glob_args(args, value)
    for _, glob in ipairs(vim.split(value or '', ',')) do
        glob = vim.trim(glob)
        if glob ~= '' then
            table.insert(args, '-g')
            table.insert(args, glob)
        end
    end
end

local function build_rg_args(prompt, opts, file_mode)
    prompt = vim.trim(prompt or '')
    if prompt == '' then
        return nil
    end

    local pieces = vim.split(prompt, '  ')
    if not pieces[1] or pieces[1] == '' then
        return nil
    end

    local args = { 'rg', '-e', pieces[1] }

    local rest = (#pieces > 1) and table.concat(pieces, ' ', 2) or nil
    if rest and rest ~= '' then
        rest = string.gsub(rest, '%s+', ' ')
        for _, glob in ipairs(vim.split(rest, ' ')) do
            add_glob_args(args, glob)
        end
    end

    for _, glob in ipairs(ignored_globs) do
        table.insert(args, '-g')
        table.insert(args, glob)
    end

    if opts.search_dirs and #opts.search_dirs > 0 then
        for _, d in ipairs(type(opts.search_dirs) == 'table' and opts.search_dirs or { opts.search_dirs }) do
            table.insert(args, d)
        end
    end

    local tail
    if file_mode then
        tail = {
            '--color=never',
            '--no-heading',
            '--with-filename',
            '--count-matches',
            '--smart-case',
            '--follow',
        }
    else
        tail = {
            '--color=never',
            '--no-heading',
            '--with-filename',
            '--line-number',
            '--column',
            '--smart-case',
            '--follow',
        }
    end

    ---@diagnostic disable-next-line: deprecated
    return vim.tbl_flatten { args, tail }
end

local function make_count_entry(opts)
    return function(line)
        if not line or line == '' then
            return nil
        end

        local path, count = line:match('^(.*):(%d+)$')
        if not path or not count then
            return nil
        end

        if not vim.startswith(path, '/') and opts.cwd then
            path = opts.cwd .. '/' .. path
        end

        local display_path = vim.fn.fnamemodify(path, ':~:.')

        return {
            valid = true,
            value = line,
            ordinal = display_path,
            display = string.format('%s (%s)', display_path, count),
            path = path,
            filename = path,
            count = tonumber(count),
        }
    end
end

function M.live_multigrep(opts)
    opts = vim.deepcopy(opts or {})
    local file_mode = opts.file_mode == true

    if not opts.search_dirs then
        opts.cwd = opts.cwd or vim.uv.cwd()
    end

    local finder
    if file_mode then
        finder = finders.new_async_job {
            command_generator = function(prompt)
                return build_rg_args(prompt, opts, true)
            end,
            entry_maker = make_count_entry(opts),
        }
    else
        finder = finders.new_async_job {
            command_generator = function(prompt)
                return build_rg_args(prompt, opts, false)
            end,
            entry_maker = make_entry.gen_from_vimgrep(opts),
        }
    end

    local function toggle_mode(prompt_bufnr)
        local line = action_state.get_current_line(prompt_bufnr)
        local new_opts = vim.deepcopy(opts)
        new_opts.file_mode = not file_mode
        new_opts.default_text = line

        actions.close(prompt_bufnr)
        vim.schedule(function()
            M.live_multigrep(new_opts)
        end)
    end

    pickers.new(opts, {
        debounce = 100,
        prompt_title = file_mode and ((opts.prompt_title or 'Grep') .. ' [files]') or opts.prompt_title,
        finder = finder,
        previewer = file_mode and conf.file_previewer(opts) or conf.grep_previewer(opts),
        sorter = require("telescope.sorters").empty(),
        default_text = opts.default_text,
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(actions.file_edit)

            map('i', '<C-u>', toggle_mode)
            map('n', '<C-u>', toggle_mode)

            map('i', '<C-v>', actions.select_vertical)
            map('n', '<C-v>', actions.select_vertical)

            map('i', '<C-t>', actions.select_tab)
            map('n', '<C-t>', actions.select_tab)

            if actions.select_tab_drop then
                map('n', '<CR>', actions.select_tab_drop)
            end

            return true
        end,
    }):find()
end

return M
