-- Custom telescope pickers: <leader>sf (files), <leader>sg (grep),
-- <leader>sq (files from the quickfix list). Examples with result counts:
-- doc/Markdown_Examples.md, "Telescope search filters".
--
-- Keys inside sf / sg / sq:
--   <C-Space>  freeze the current results and fuzzy-filter them; press
--              again to stack another filter. Ignored on an empty prompt or
--              zero results. The title shows the trail: `Grep Files › a › b`.
--   <C-t>      grep <-> files, scoped to the files in the CURRENT results
--              (after any filters). Back to grep re-runs the original rg
--              pattern over the narrowed files. From an unfiltered sf it
--              greps the whole tree, carrying the prompt.
--   <M-u>      sg only: matching lines <-> files with match counts.
--   <C-y>      copy the selected entry's absolute path.
--   <C-q>      send results to quickfix (then <leader>sq to search in them).
-- Global: <M-p> toggle preview, <C-l> side-by-side/stacked layout,
--   <C-Up>/<C-Down> prompt history, <leader>sR reopen one of the last 10
--   pickers (every <C-t> stage is in there), <leader>s. recent files.
--
-- What the prompt means:
--   live sg prompt   an rg regex. `!word` does NOT exclude here; it's
--                    searched literally.
--   after <C-Space>  fzf syntax over path + line text:
--   and in sf          word    loose match (letters in order)
--                      'word   exact text
--                      !word   exclude lines/paths containing word
--                      ^word / word$   starts / ends with
--   `foo  globs`     (TWO spaces) comma-separated rg -g globs, live in sg
--                    and sf: `foo  !**/test/**` keeps rg out of test dirs.
--
-- So: drop things from grep results -> <C-Space> then !word. Keep rg out of
-- folders from the start -> the two-space !glob.

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
--   3. Type globs inline in the prompt, after TWO spaces (comma-separated;
--      they're forwarded to rg as -g patterns). Raw rg flags are NOT passed
--      through — a "-g" token would itself be treated as a glob:
--      `foo  !**/test/**`   searches "foo", ignoring test dirs
--      `foo  !**/test/**,!*.tmp`
local ignored_globs = {
    '!*.pyi',
    '!.yarn',
    '!.telescope_history',
    '!*.html',
    '!*.pyc',
    '!*.js',
    '!*.png',
    '!.DS_Store',
    '!**/.venv/**',
    '!**/venv/**',
    '!**/env/**',
    '!**/__pycache__/**',
    '!**/.mypy_cache/**',
    '!**/.pytest_cache/**',
    '!**/.ruff_cache/**',
    '!**/.tox/**',
    '!**/*.egg-info/**',
    -- Test patterns (EXAMPLES — uncomment to enable):
    -- '!**/test/**',
    -- '!src/**/*test*',
}

local MIN_GREP_CHARS = 2

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
    -- Don't grep until the pattern has MIN_GREP_CHARS characters: a 1-char
    -- pattern matches nearly every line in the tree and floods the picker.
    if not pieces[1] or #pieces[1] < MIN_GREP_CHARS then
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

-- The glob section of the prompt (everything after the first double space),
-- whitespace-normalised. It's the only part that changes the rg --files
-- command, so it's the cache key for the file list.
local function prompt_globs(prompt)
    local pieces = vim.split(vim.trim(prompt or ''), '  ')
    if #pieces < 2 then
        return ''
    end
    return vim.trim((table.concat(pieces, ' ', 2):gsub('%s+', ' ')))
end

-- Finder for `sf`: runs `rg --files` ONCE per distinct glob section and lets
-- the sorter filter the cached list in memory as you type. (An async_job
-- finder would kill and re-spawn rg, re-listing the whole tree, on every
-- keystroke.) Changing the globs runs rg again for that glob set; going back
-- to a glob set you've already used reuses its list.
local function cached_files_finder(opts, entry_maker)
    local cache = {}
    local current
    return setmetatable({
        close = function()
            for _, f in pairs(cache) do
                f:close()
            end
            cache = {}
        end,
    }, {
        -- picker code reads finder.results (e.g. delete_selection)
        __index = function(_, k)
            if k == 'results' then
                return current and current.results or {}
            end
        end,
        __call = function(_, prompt, process_result, process_complete)
            local key = prompt_globs(prompt)
            if not cache[key] then
                cache[key] = finders.new_oneshot_job(build_files_args(prompt, opts), {
                    entry_maker = entry_maker,
                    cwd = opts.cwd,
                })
            end
            current = cache[key]
            return current(prompt, process_result, process_complete)
        end,
    })
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
-- current prompt text over. Bound to <C-t> so you can flip between the file
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

-- <C-Space> in both pickers: freeze the current results and fuzzy-filter
-- them (stackable). Wraps telescope's refine with two changes:
--   * refuses on an empty prompt or zero results. Freezing an empty grep
--     list leaves a dead picker: rg no longer runs, so typing shows nothing.
--   * keeps the original title and appends each frozen prompt as a trail
--     (`Grep Files (6 files from file list) › vim.notify › 'WARN`) instead of
--     telescope's `Fuzzy over (<last prompt>)`.
-- Returns true if it froze.
local function freeze_results(prompt_bufnr)
    local picker = action_state.get_current_picker(prompt_bufnr)
    local line = vim.trim(action_state.get_current_line(prompt_bufnr))
    if line == '' then
        vim.notify('<C-Space>: type something first, then freeze it', vim.log.levels.INFO)
        return false
    end
    if picker.manager:num_results() == 0 then
        vim.notify('<C-Space>: no results to filter', vim.log.levels.INFO)
        return false
    end
    picker.__freeze_trail = picker.__freeze_trail or {}
    table.insert(picker.__freeze_trail, line)
    require('telescope.actions.generate').refine(prompt_bufnr, {
        prompt_title = picker.prompt_title .. ' › ' .. table.concat(picker.__freeze_trail, ' › '),
        sorter = conf.generic_sorter({}),
    })
    return true
end

-- Make absolute paths under `cwd` relative to it. rg runs in cwd, so the
-- paths still resolve, and fuzzy filename matching then scores against
-- "lua/user/cd.lua" instead of "/Users/<you>/.../lua/user/cd.lua", where
-- every file matches a query like "user". Paths outside cwd stay absolute.
local function relative_to(files, cwd)
    if not cwd or cwd == '' then
        return files
    end
    local prefix = vim.fn.fnamemodify(cwd, ':p')
    if not prefix:match('/$') then
        prefix = prefix .. '/'
    end
    local out = {}
    for i, f in ipairs(files) do
        out[i] = vim.startswith(f, prefix) and f:sub(#prefix + 1) or f
    end
    return out
end

-- Upper bound on files handed to rg as arguments when scoping (keeps the
-- command line well under macOS ARG_MAX).
local MAX_SCOPE_FILES = 4000

-- Unique absolute paths of every entry the picker currently holds: the
-- matching results, after any <C-Space> filters (not just the visible rows;
-- the entry manager keeps all of them).
local function current_result_files(prompt_bufnr)
    local picker = action_state.get_current_picker(prompt_bufnr)
    local seen, files = {}, {}
    for entry in picker.manager:iter() do
        local p = entry.path or entry.filename or entry.value
        if type(p) == 'string' and p ~= '' then
            p = vim.fn.fnamemodify(p, ':p')
            if not seen[p] then
                seen[p] = true
                files[#files + 1] = p
            end
        end
    end
    return files
end

-- <C-t>, scoped: open `fn` over only the files in the current results, with
-- an empty prompt (the old prompt was a grep pattern / filename filter, not
-- something the other view can use). Each hop narrows further, so
-- grep -> files -> grep -> ... keeps shrinking the scope.
-- Returns false (without switching) if there's nothing usable to scope to.
local function switch_scoped(prompt_bufnr, fn, opts, from_kind, default_text)
    local files = current_result_files(prompt_bufnr)
    if #files == 0 then
        return false
    end
    if #files > MAX_SCOPE_FILES then
        vim.notify(('%d files is too many to scope to (max %d); narrow first'):format(#files, MAX_SCOPE_FILES),
            vim.log.levels.WARN)
        return false
    end
    local new_opts = vim.deepcopy(opts)
    new_opts.cwd = new_opts.cwd or vim.uv.cwd()
    new_opts.search_dirs = nil
    new_opts.search_files = relative_to(files, new_opts.cwd)
    new_opts.default_text = default_text
    new_opts.prompt_title = nil
    new_opts.qf = nil
    new_opts.scope_label = ('%d file%s from %s'):format(#files, #files == 1 and '' or 's', from_kind)
    actions.close(prompt_bufnr)
    vim.schedule(function()
        fn(new_opts)
    end)
    return true
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
        base = base .. ' [counts]'
    end
    if opts.scope_label then
        base = base .. ' (' .. opts.scope_label .. ')'
    end
    return base
end

function M.live_multigrep(opts)
    opts = vim.deepcopy(opts or {})
    local file_mode = opts.file_mode == true

    if not opts.search_dirs and not opts.search_files then
        opts.cwd = opts.cwd or vim.uv.cwd()
    end

    -- cwd MUST be passed to the finder: without it rg runs in nvim's cwd while
    -- the entry makers resolve the (relative) results against opts.cwd.
    local finder
    if file_mode then
        finder = finders.new_async_job {
            command_generator = function(prompt)
                return build_rg_args(prompt, opts, true)
            end,
            entry_maker = make_count_entry(opts),
            cwd = opts.cwd,
        }
    else
        finder = finders.new_async_job {
            command_generator = function(prompt)
                return build_rg_args(prompt, opts, false)
            end,
            entry_maker = make_entry.gen_from_vimgrep(opts),
            cwd = opts.cwd,
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
        -- each debounced keystroke kills + re-spawns rg; 120ms keeps typing
        -- from launching a search per character
        debounce = 120,
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

            -- <M-u>: toggle grep lines <-> files-with-match-counts.
            -- (Not <C-u>: that's telescope's preview-scroll-up, the partner
            -- of <C-d>.)
            map('i', '<M-u>', toggle_mode)
            map('n', '<M-u>', toggle_mode)

            -- <C-Space>: freeze the current rg results and fuzzy-filter them
            -- (path + line text) instead of re-running rg per keystroke.
            -- See freeze_results for the empty-prompt guard and title trail.
            map('i', '<C-Space>', freeze_results)
            map('n', '<C-Space>', freeze_results)

            -- <C-t>: flip to the find-files view over ONLY the files in the
            -- current results (after any <C-Space> filters). With no results
            -- yet, flip over the same scope, carrying the prompt.
            local function to_files()
                -- Remember the rg pattern (the first frozen prompt if
                -- <C-Space> was used, else the live prompt) so <C-t> back
                -- from the file view re-runs it instead of opening empty.
                local picker = action_state.get_current_picker(prompt_bufnr)
                local trail = picker.__freeze_trail
                local pattern = (trail and trail[1]) or action_state.get_current_line(prompt_bufnr)
                local carry = vim.deepcopy(opts)
                carry.grep_text = vim.trim(pattern) ~= '' and pattern or opts.grep_text
                if not switch_scoped(prompt_bufnr, M.files, carry, 'grep') then
                    switch_picker(prompt_bufnr, M.files, opts)
                end
            end
            map('i', '<C-t>', to_files)
            map('n', '<C-t>', to_files)

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

    local finder = cached_files_finder(opts, make_entry.gen_from_file(opts))

    pickers.new(opts, {
        debounce = 50,
        prompt_title = picker_title(opts, 'Find Files', 'files'),
        finder = finder,
        previewer = conf.file_previewer(opts),
        sorter = files_sorter,
        attach_mappings = function(prompt_bufnr, map)
            actions.select_default:replace(actions.file_edit)

            -- <C-Space>: freeze the current file list and fuzzy-filter it
            -- again (stackable). Marks the list as narrowed for <C-t>.
            local refined = false
            local function refine(bufnr)
                if freeze_results(bufnr) then
                    refined = true
                end
            end
            map('i', '<C-Space>', refine)
            map('n', '<C-Space>', refine)

            -- <C-t>: flip to the grep view. If the list has been narrowed
            -- (typed filter, <C-Space>, or an already-scoped/QF picker),
            -- grep ONLY the files currently listed; otherwise grep the same
            -- scope as before, carrying the prompt (no point handing rg
            -- every file in the tree as arguments).
            local function to_grep()
                local narrowed = refined or opts.search_files ~= nil
                    or prompt_filename(action_state.get_current_line(prompt_bufnr)) ~= ''
                -- opts.grep_text: the rg pattern from the grep picker we
                -- came from (if any), re-run over the narrowed files.
                if not (narrowed and switch_scoped(prompt_bufnr, M.live_multigrep, opts, 'file list', opts.grep_text)) then
                    switch_picker(prompt_bufnr, M.live_multigrep, opts)
                end
            end
            map('i', '<C-t>', to_grep)
            map('n', '<C-t>', to_grep)
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
    -- glob syntax from `sf` also works here, and <C-t> toggles between the
    -- file and grep views (titles carry a "QF " prefix).
    local merged = vim.deepcopy(opts or {})
    merged.cwd = merged.cwd or vim.uv.cwd()
    merged.search_dirs = nil
    merged.search_files = relative_to(files, merged.cwd)
    merged.qf = true
    M.files(merged)
end

return M
