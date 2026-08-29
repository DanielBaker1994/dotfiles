-- Keymaps
vim.opt.formatoptions:remove({ 'r', 'o' }) -- stopped the new comment line if on a comment


vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = 'Go to previous [D]iagnostic message' })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = 'Go to next [D]iagnostic message' })
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Show diagnostic [E]rror messages' })
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })
vim.opt.fillchars = {
    horiz = '━',
    horizup = '┻',
    horizdown = '┳',
    vert = '┃',
    vertleft = '┫',
    vertright = '┣',
    verthoriz =
    '╋',
}

vim.keymap.set('x', 'K', ":m '<-2<CR>gv=gv", { noremap = true, silent = true })
vim.keymap.set('x', 'J', ":m '>+1<CR>gv=gv", { noremap = true, silent = true })

vim.api.nvim_set_keymap('n', '<C-[>', '<C-o>', { noremap = true, silent = true })
vim.api.nvim_set_keymap('n', '<C-]>', '<C-i>', { noremap = true, silent = true })
vim.keymap.set('i', 'jk', '<ESC>', { noremap = true, silent = true })
vim.keymap.set('i', 'kj', '<ESC>', { noremap = true, silent = true })

vim.keymap.set('v', '<', '<gv^', { noremap = true, silent = true })
vim.keymap.set('v', '>', '>gv^', { noremap = true, silent = true })
vim.keymap.set('n', '<C-d>', "<C-d>zz")
vim.keymap.set('n', '<C-u>', "<C-u>zz")


-- Standalone: clear all notifications (noice popups + nvim-notify queue).
-- Call it any time with  :lua UserClearNotifications()
-- It also runs at the start of <leader><leader> (see below) — without
-- replacing that mapping's real job (the buffers picker).
function UserClearNotifications()
    -- dismiss every visible noice window (notify popups, routed messages)
    local ok_noice, noice = pcall(require, 'noice')
    if ok_noice and noice.cmd then
        pcall(noice.cmd, 'dismiss')
    end
    -- safety net: clear nvim-notify's own queue, incl. pending ones
    local ok_notify, notify = pcall(require, 'notify')
    if ok_notify and type(notify.dismiss) == 'function' then
        pcall(notify.dismiss, { pending = true, silent = true })
    end
end

-- Double-Esc dismisses all notifications (same function <leader><leader> runs
-- first). With a longer <Esc> mapping in play, a single Esc waits up to
-- 'timeoutlen' before clearing the search highlight — see vim.o.timeoutlen.
vim.keymap.set('n', '<Esc><Esc>', UserClearNotifications, { desc = 'Clear all notifications' })

local telescope_builtin = require('telescope.builtin')
local user_telescope = require('user.telescope')
vim.keymap.set('n', '<leader>sh', telescope_builtin.help_tags, { desc = '[S]earch [H]elp' })
vim.keymap.set('n', '<leader>sk', telescope_builtin.keymaps, { desc = '[S]earch [K]eymaps' })
vim.keymap.set('n', '<leader>sf', user_telescope.files, { desc = '[S]earch [F]iles <space><space>**globs' })
vim.keymap.set('n', '<leader>ss', telescope_builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
vim.keymap.set('n', '<leader>sr', telescope_builtin.resume, { desc = '[S]esume Telescope' })
vim.keymap.set('n', '<leader>sw', telescope_builtin.grep_string, { desc = '[S]earch current [W]ord' })

vim.keymap.set("n", "<leader>sg", user_telescope.live_multigrep, { desc = 'Live multigrep <space><space>**filetype' })
vim.keymap.set('n', '<leader>+', function() _G.UserTermToggle() end, { desc = 'Toggle terminal' })
vim.keymap.set("n", "<leader>sq", user_telescope.live_multigrep_qf, { desc = 'Live multigrep scoped to quickfix files' })
vim.keymap.set('n', '<leader>sd', telescope_builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
vim.keymap.set('n', '<leader><leader>', function()
    UserClearNotifications() -- clear notifications first, then the usual picker
    telescope_builtin.buffers()
end, { desc = '[ ] Find existing buffers (clears notifications first)' })


local db = require('user.db_functions')
vim.keymap.set('n', '<leader>sp', db.search_parent_from_buffer, { desc = 'Grep Parent from buffer path' })
vim.keymap.set('n', '<leader>mdo', db.markdown_open, { desc = 'Convert markdown to PDF (pandoc) and open' })

-- Git history via diffview.nvim — commit list panel with diffs.
-- <leader>gs is the interactive filter builder (no flags to memorize); inside
-- the panel g! also opens diffview's own options panel to tweak filters.
vim.keymap.set('n', '<leader>gf', '<cmd>DiffviewFileHistory %<CR>', { desc = '[G]it history: current [F]ile' })
vim.keymap.set('n', '<leader>gl', '<cmd>DiffviewFileHistory<CR>', { desc = '[G]it [L]og: all commits' })
vim.keymap.set('n', '<leader>gs', require('user.git_history').open,
    { desc = '[G]it hi[S]tory: build filters interactively' })

local gitsigns = require('gitsigns')
vim.keymap.set('n', '<leader>gb', gitsigns.blame_line, { desc = '[G]it [B]lame line' })
vim.keymap.set('n', '<leader>gh', gitsigns.preview_hunk, { desc = '[G]it preview [H]unk' })
vim.keymap.set('n', '[h', gitsigns.prev_hunk, { desc = 'Previous git [H]unk' })
vim.keymap.set('n', ']h', gitsigns.next_hunk, { desc = 'Next git [H]unk' })

vim.keymap.set('n', '[t', function() require('todo-comments').jump_prev() end, { desc = 'Previous TODO' })
vim.keymap.set('n', ']t', function() require('todo-comments').jump_next() end, { desc = 'Next TODO' })
vim.keymap.set('n', '<leader>st', '<cmd>TodoTelescope<CR>', { desc = '[S]earch [T]odo comments' })

-- Full config reload without restarting nvim.
-- 1. forget cached user.* modules so require() re-reads them from disk
-- 2. re-source init.lua
-- 3. re-source after/plugin/*.lua  (a plain ':source $MYVIMRC' does NOT do this)
-- Note: option/keymap/autocmd/user-module changes pick up immediately. Changes
-- inside an already-loaded plugin's config = function() do NOT re-run; those
-- still need a real restart.
vim.keymap.set('n', '<leader>rl', function()
    for name in pairs(package.loaded) do
        if name:match('^user%.') then
            package.loaded[name] = nil
        end
    end

    local ok_init = pcall(vim.cmd, 'source $MYVIMRC')

    local ok_after = true
    for _, path in ipairs(vim.api.nvim_get_runtime_file('after/plugin/*.lua', true)) do
        if not pcall(vim.cmd, 'source ' .. vim.fn.fnameescape(path)) then
            ok_after = false
        end
    end

    if ok_init and ok_after then
        vim.notify('nvim config reloaded', vim.log.levels.INFO)
    else
        vim.notify('reload finished WITH errors — check :messages', vim.log.levels.ERROR)
    end
end, { desc = '[R]e[L]oad nvim config' })





local external_paths = require('bash_external.external_paths')

local function with_external_paths(callback)
    external_paths.on_load(function(paths)
        callback(vim.deepcopy(paths))
    end)
end

vim.keymap.set('n', '<leader>mlo', function()
    vim.cmd [[Noice all]]
end, { desc = '[M]essage [L]og [O]pen (all messages Noice)' })

vim.keymap.set('n', '<leader>mda', function()
    vim.cmd [[Noice dismiss]]
end, { desc = '[M]essage [D]ismiss [A]ll (clear all popup Noice messages)' })



vim.keymap.set('n', '<leader>sdg', function()
    with_external_paths(function(search_dirs)
        -- Plugin source is the useful Lua portion of stdpath('data'); excluding
        -- Mason avoids recursively searching hundreds of MB of installed tools.
        table.insert(search_dirs, vim.fs.joinpath(vim.fn.stdpath('data'), 'lazy'))
        user_telescope.live_multigrep({
            prompt_title = 'Dotfile + Lua Grep',
            search_dirs = search_dirs,
            file_ignore_patterns = { '.git/' },
        })
    end)
end, { desc = '[S]earch [D]otfile [G]rep' })

vim.keymap.set('n', '<leader>sdf', function()
    with_external_paths(function(search_dirs)
        telescope_builtin.find_files({
            search_dirs = search_dirs,
            hidden = true,
            prompt_title = 'Dotfile Picker',
            file_ignore_patterns = { '.git/' },
        })
    end)
end, { desc = '[S]earch [D]otfiles [F]iles' })

vim.keymap.set('n', '<leader>ct', function()
    vim.cmd('LspClangdSwitchSourceHeader')
end, { desc = 'Clangd: switch source/header' })

vim.keymap.set('n', 'ss', function()
    require("flash").jump()
end, { desc = 'Jump list teleport (flash)' })

vim.keymap.set({ 'n', 'x', 'o' }, 'S', function() require('flash').treesitter() end,
    { desc = 'Flash: treesitter targets' })
vim.keymap.set({ 'x', 'o' }, 's', function() require('flash').jump() end,
    { desc = 'Flash: search' })

local qf_group = vim.api.nvim_create_augroup('quickfix-nav-maps', { clear = true })
vim.api.nvim_create_autocmd({ 'FileType' }, {
    group = qf_group,
    pattern = 'qf',
    desc = 'Quickfix: map Ctrl-n/Ctrl-p to :cnext/:cprev',
    callback = function()
        local opts = { noremap = true, silent = true, buffer = true }
        -- Move the quickfix cursor but return focus to the quickfix window
        vim.keymap.set('n', '<C-n>', function()
            vim.cmd('cnext')
            vim.cmd('wincmd p')
        end, opts)
        vim.keymap.set('n', '<C-p>', function()
            vim.cmd('cprev')
            vim.cmd('wincmd p')
        end, opts)
    end,
})


local user_cd = require('user.cd')
vim.keymap.set('n', '<leader>cd', function()
    user_cd.pick()
end, { desc = 'CD to worktree target' })
vim.api.nvim_create_user_command('Cd', function(opts)
    user_cd.cd(opts.args)
end, { nargs = 1, desc = 'CD to target' })

_G.ClearOtherBuffers = function()
    user_cd.clear_other_buffers()
end
vim.api.nvim_create_user_command('ClearOtherBuffers', function()
    user_cd.clear_other_buffers()
end, { desc = 'Close buffers outside the current workspace' })

vim.keymap.set('n', '<leader>obw', ':!open %:p:h<CR>', { desc = "[O]pen [B]buffer [W]indow", silent = true })
vim.keymap.set('n', '<leader>obe',
    function()
        vim.cmd("Oil " .. vim.fn.expand('%:p:h'))
    end
    , { desc = "[O]pen [B]buffer [E]explorer (Oil)", silent = true })


vim.keymap.set('n', '<leader>yp', function()
    local path = vim.fn.expand('%:p')
    path = path:gsub("^oil://", "")
    vim.fn.setreg('+', path)
end, { desc = 'Yank file path' })

vim.keymap.set('n', '<leader>yd', function()
    local path = vim.fn.expand('%:p:h')
    vim.fn.setreg('+', path)
    print('Yanked path: ' .. path)
end, { desc = 'Yank file directory' })

vim.keymap.set('n', '<leader>yn', function()
    local name = vim.fn.expand('%:t')
    vim.fn.setreg('+', name)
    print('Yanked file name: ' .. name)
end, { desc = 'Yank file name' })

vim.api.nvim_create_autocmd("LspAttach", {
    pattern = { '*.py', '*.lua', '*.bashrc', '*.bash_profile', '*.sh', '*.bash' },
    group = vim.api.nvim_create_augroup("UserLspInlayHints", { clear = true }),
    callback = function(args)
        if not (args.data and args.data.client_id) then
            return
        end
        local client = vim.lsp.get_client_by_id(args.data.client_id)
        if client and client.server_capabilities.inlayHintProvider then
            vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
        end
        vim.diagnostic.config({
            virtual_text = {
                prefix = "● ",
                spacing = 1,
                source = true,
            },
            signs = true,             -- Show error/warning signs in the sign column
            underline = true,         -- Underline errors in the text
            update_in_insert = false, -- Don't update diagnostics while in insert mode
        })
    end
})

vim.api.nvim_create_autocmd('TextYankPost', {
    desc = 'Highlight when yanking (copying) text',
    group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
    callback = function()
        vim.hl.on_yank()
    end,
})




vim.api.nvim_create_autocmd('LspAttach', {
    group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
    callback = function(event)
        local map = function(keys, func, desc)
            vim.keymap.set('n', keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
        end
        local tb = require('telescope.builtin')
        map('gd', tb.lsp_definitions, '[G]oto [D]efinition')
        map('gr', tb.lsp_references, '[G]oto [R]eferences')
        map('gI', tb.lsp_implementations, '[G]oto [I]mplementation')
        map('<leader>D', tb.lsp_type_definitions, 'Type [D]efinition')
        map('<leader>ds', tb.lsp_document_symbols, '[D]ocument [S]ymbols')
        map('<leader>ws', tb.lsp_dynamic_workspace_symbols, '[W]orkspace [S]ymbols')
        map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')
        map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction')
        map('K', vim.lsp.buf.hover, 'Hover Documentation')
        map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

        local client = vim.lsp.get_client_by_id(event.data.client_id)
        if client and client.server_capabilities.documentHighlightProvider then
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' },
                { buffer = event.buf, callback = vim.lsp.buf.document_highlight })
            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' },
                { buffer = event.buf, callback = vim.lsp.buf.clear_references })
        end
    end,
})

vim.api.nvim_create_autocmd({ "VimEnter", "ColorScheme" }, {
    callback = function() vim.cmd('highlight! link LualineCwd Directory') end,
})
