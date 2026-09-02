local pickers = require "telescope.pickers"
local finders = require "telescope.finders"
local make_entry = require "telescope.make_entry"
local conf = require "telescope.config".values
local actions = require "telescope.actions"
local action_state = require "telescope.actions.state"
local sorters = require "telescope.sorters"

local M = {}

-- <C-y> in any picker built here: copy the selected entry's ABSOLUTE path to
-- the system clipboard and close. Handles file entries (.path/.value),
-- vimgrep entries (.filename), and the count entries from make_count_entry
-- (.path/.filename).
local function copy_selected_path(prompt_bufnr)
    local entry = action_state.get_selected_entry()
    if not entry then
        return
    end
    local path = entry.filename or entry.path or entry.value
    if type(path) ~= 'string' or path == '' then
        vim.notify('Nothing to copy', vim.log.levels.WARN)
        return
    end
    path = vim.fn.fnamemodify(path, ':p')
    vim.fn.setreg('+', path)
    actions.close(prompt_bufnr)
    vim.notify('Copied: ' .. path)
end

-- Global -g ignores applied to EVERY rg invocation from this module
-- (see build_rg_args below: they're appended to all searches).
--
-- How to ignore test dirs/files — pick whichever fits:
--
--   1. UNCOMMENT a glob below. These are ALWAYS applied. Verified patterns:
--        '!**/test/**'      ignore a DIRECTORY named "test" at any depth
--        '!/test/**'        ignore ONLY the top-level "test" dir (relative to search root)
--        '!*test*'          ignore ANY file/dir whose basename contains "test"
--                           (files AND dirs; heaviest, also drops tests/, test_utils.cpp...)
--        '!src/**/*test*'   ignore test-named FILES inside src/ only
--                           (keeps dirs named test, other dirs, etc.)
--        '!**/*_test*'      ignore files ending in _test at any depth
--
--   2. Per-project .rgignore file instead (zero code here). rg reads it
--      automatically, same syntax as .gitignore, e.g.:
--          **/test/**        # any "test" dir
--          **/*_test*        # files ending in _test
--      Pros: project-local, no nvim changes; Cons: only where the file exists.
--
--   3. Type it inline in the prompt (build_rg_args passes extra args to rg):
--      `foo -g !**/test/**`  searches "foo", ignoring test dirs.
local ignored_globs = {
    '!.pyi',
    '!.yarn',
    '!.telescope_history',
    '!.html',
    '!.pyc',
    '!.js',
    '!.png',
    '!.DS_Store',
    -- Test patterns (EXAMPLES — uncomment to enable):
    -- '!**/test/**',
    -- '!src/**/*test*',
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

    vim.list_extend(args, tail)

    local search_paths = opts.search_files or opts.search_dirs
    if search_paths then
        for _, path in ipairs(type(search_paths) == 'table' and search_paths or { search_paths }) do
            table.insert(args, path)
        end
    end

    return args
end

-- Filename search for `sf`. Same two-space syntax as `sg`:
--   foo                fuzzy-search "foo" in file names
--   foo  **/test/**    only files under a "test" dir
--   foo  !**/test/**   all "foo" files EXCEPT under "test" dirs
--   foo  !**/test/**,!*.tmp
-- Tokens after the double space are comma-separated rg globs (`!` = exclude).
-- The file list comes from `rg --files`, so .gitignore/.rgignore apply too.
local function build_files_args(prompt, opts)
    prompt = vim.trim(prompt or '')
    local pieces = vim.split(prompt, '  ')

    local args = { 'rg', '--files', '--hidden', '--follow', '-g', '!.git' }

    for _, glob in ipairs(ignored_globs) do
        table.insert(args, '-g')
        table.insert(args, glob)
    end

    local rest = (#pieces > 1) and table.concat(pieces, ' ', 2) or nil
    if rest and rest ~= '' then
        rest = string.gsub(rest, '%s+', ' ')
        for _, glob in ipairs(vim.split(rest, ' ')) do
            add_glob_args(args, glob)
        end
    end

    local search_paths = opts.search_files or opts.search_dirs
    if search_paths then
        for _, path in ipairs(type(search_paths) == 'table' and search_paths or { search_paths }) do
            table.insert(args, path)
        end
    end

    return args
end

-- Score against ONLY the filename part of the prompt, so a `  globs` suffix
-- never pollutes fuzzy matching.
local function prompt_filename(prompt)
    return (vim.split(prompt or '', '  ')[1] or ''):gsub('%s+$', '')
end

-- Score with telescope's fzf-native (C) matcher while keeping the two-space
-- glob-suffix stripping. Falls back to the pure-Lua fzy sorter if the fzf
-- extension isn't available.
local fzf_ok, fzf_make = pcall(function()
    return require('telescope').extensions.fzf.native_fzf_sorter
end)
local files_sorter = sorters.Sorter:new {
    discard = true,
    init = function(self)
        self._fzf = fzf_ok and fzf_make() or sorters.get_fzy_sorter()
        if self._fzf and self._fzf._init then
            self._fzf:_init()
        end
    end,
    destroy = function(self)
        if self._fzf and self._fzf._destroy then
            self._fzf:_destroy()
        end
        self._fzf = nil
    end,
    scoring_function = function(self, prompt, line)
        return self._fzf:scoring_function(prompt_filename(prompt), line)
    end,
    highlighter = function(self, prompt, display)
        return self._fzf:highlighter(prompt_filename(prompt), display)
    end,
}

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

-- Switch the open picker to another one over the same opts, carrying the
-- current prompt text over. Bound to <C-u> so you can flip between the file
-- view (M.files) and the grep view (M.live_multigrep) on the same set of
-- files. The two-space glob syntax parses identically in both, so the prompt
-- carries across cleanly.
local function switch_picker(bufnr, fn, opts)
    local line = action_state.get_current_line(bufnr)
    local new_opts = vim.deepcopy(opts)
    new_opts.default_text = line
    actions.close(bufnr)
    vim.schedule(function()
        fn(new_opts)
    end)
end

-- Prompt border title. A `QF ` prefix marks pickers opened from the quickfix;
-- ` [counts]` marks the files-with-match-counts view. opts.prompt_title, when
-- set (custom titles elsewhere), is used verbatim.
local function picker_title(opts, kind, mode)
    if opts.prompt_title then
        return opts.prompt_title
    end
    local base = opts.qf and ('QF ' .. kind) or kind
    if mode == 'counts' then
        return base .. ' [counts]'
    end
    return base
end

function M.live_multigrep(opts)
    opts = vim.deepcopy(opts or {})
    local file_mode = opts.file_mode == true

    if not opts.search_dirs and not opts.search_files then
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
        debounce = 50,
        prompt_title = picker_title(opts, 'Grep Files', file_mode and 'counts' or 'lines'),
        finder = finder,
        previewer = file_mode and conf.file_previewer(opts) or conf.grep_previewer(opts),
        sorter = file_mode and sorters.Sorter:new {
            scoring_function = function(_, _, _, entry)
                return 1 / entry.count
            end,
        } or sorters.empty(),
        default_text = opts.default_text,
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(actions.file_edit)

            -- <C-u>: toggle grep lines <-> files-with-match-counts.
            map('i', '<C-u>', toggle_mode)
            map('n', '<C-u>', toggle_mode)

            -- <C-t>: flip to the find-files view over the same scope.
            map('i', '<C-t>', function()
                switch_picker(prompt_bufnr, M.files, opts)
            end)
            map('n', '<C-t>', function()
                switch_picker(prompt_bufnr, M.files, opts)
            end)

            map('i', '<C-v>', actions.select_vertical)
            map('n', '<C-v>', actions.select_vertical)

            -- <C-y>: copy selected entry's absolute path to clipboard.
            map('i', '<C-y>', copy_selected_path)
            map('n', '<C-y>', copy_selected_path)

            if actions.select_tab_drop then
                map('n', '<CR>', actions.select_tab_drop)
            end

            return true
        end,
    }):find()
end

-- `sf`: find files by NAME with rg (so ignores apply) + fuzzy filename
-- matching + optional double-space glob section (see build_files_args).
function M.files(opts)
    opts = vim.deepcopy(opts or {})
    opts.cwd = opts.cwd or vim.uv.cwd()

    local finder = finders.new_async_job {
        command_generator = function(prompt)
            return build_files_args(prompt, opts)
        end,
        entry_maker = make_entry.gen_from_file(opts),
    }

    pickers.new(opts, {
        debounce = 50,
        prompt_title = picker_title(opts, 'Find Files', 'files'),
        finder = finder,
        previewer = conf.file_previewer(opts),
        sorter = files_sorter,
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(actions.file_edit)
            -- <C-t>: flip to the grep view over the same files.
            map('i', '<C-t>', function()
                switch_picker(prompt_bufnr, M.live_multigrep, opts)
            end)
            map('n', '<C-t>', function()
                switch_picker(prompt_bufnr, M.live_multigrep, opts)
            end)
            map('i', '<C-v>', actions.select_vertical)
            map('n', '<C-v>', actions.select_vertical)
            -- <C-y>: copy selected entry's absolute path to clipboard.
            map('i', '<C-y>', copy_selected_path)
            map('n', '<C-y>', copy_selected_path)
            return true
        end,
    }):find()
end

function M.live_multigrep_qf(opts)
    local qf = vim.fn.getqflist()
    if #qf == 0 then
        vim.notify('Quickfix list is empty', vim.log.levels.WARN)
        return
    end

    local seen = {}
    local files = {}
    for _, entry in ipairs(qf) do
        local filename = entry.bufnr > 0 and vim.api.nvim_buf_get_name(entry.bufnr) or ''
        if filename ~= '' then
            filename = vim.fn.fnamemodify(filename, ':p')
        end
        if filename ~= '' and vim.fn.filereadable(filename) == 1 and not seen[filename] then
            seen[filename] = true
            table.insert(files, filename)
        end
    end

    if #files == 0 then
        vim.notify('No valid file paths in quickfix', vim.log.levels.WARN)
        return
    end

    -- Show the unique quickfix files as a normal file picker (one entry per
    -- file, standard content preview), fuzzy-filterable by name. The two-space
    -- glob syntax from `sf` also works here, and <C-g>/<C-f> toggle between
    -- the file and grep views (titles carry a "QF " prefix).
    local merged = vim.deepcopy(opts or {})
    merged.search_dirs = nil
    merged.search_files = files
    merged.qf = true
    M.files(merged)
end

return M
