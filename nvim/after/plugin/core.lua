-- function OpenMarkdownPreview(url)
--     vim.cmd.execute ("silent ! firefox --new-window " .. a:url)
-- end

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


local telescope_builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>sh', telescope_builtin.help_tags, { desc = '[S]earch [H]elp' })
vim.keymap.set('n', '<leader>sk', telescope_builtin.keymaps, { desc = '[S]earch [K]eymaps' })
vim.keymap.set('n', '<leader>sfc', telescope_builtin.find_files, { desc = '[S]earch [F]iles [C]WD' })
vim.keymap.set('n', '<leader>ss', telescope_builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
vim.keymap.set('n', '<leader>sw', telescope_builtin.grep_string, { desc = '[S]earch current [W]ord' })

local usertelescope = require('user.telescope')
vim.keymap.set("n", "<leader>sg", usertelescope.live_multigrep, { desc = 'Live multigrep <space><space>**filetype' })
vim.keymap.set('n', '<leader>sd', telescope_builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
vim.keymap.set('n', '<leader><leader>', telescope_builtin.buffers, { desc = '[ ] Find existing buffers' })


local db = require('user.db_functions')
vim.keymap.set('n', '<leader>sp', db.search_parent_from_buffer, { desc = 'Grep Parent from buffer path' })
vim.keymap.set('n', '<leader>mdo', db.markdown_open, { desc = 'Convert markdown to PDF (pandoc) and open' })



function EXTERNAL_PATHS_GLOBAL()
    local cmd = { "bash", "-lc", "source ~/.bashrc >/dev/null 2>&1 && EXTERNAL_PATHS_GLOBAL 2>/dev/null" }
    local ret = vim.system(cmd):wait()
    local out = vim.trim(ret.stdout or "")
    local parts = out == "" and {} or vim.split(out, "%s+")
    local dirs = { vim.fn.stdpath('config') }
    for _, p in ipairs(parts) do
        if p:match("%S") then table.insert(dirs, p) end
    end

    -- Filter out invalid paths
    local valid_dirs = {}
    for _, dir in ipairs(dirs) do
        if dir and dir ~= "" then
            table.insert(valid_dirs, dir)
        else
            print("invalid dir" .. dir)
        end
    end

    return valid_dirs
end

vim.keymap.set('n', '<leader>mlo', function()
    vim.cmd [[Noice all]]
end, { desc = '[M]essage [L]og [O]pen (all messages Noice)' })

vim.keymap.set('n', '<leader>mda', function()
    vim.cmd [[Noice dismiss]]
end, { desc = '[M]essage [D]ismiss [A]ll (clear all popup Noice messages)' })



vim.keymap.set('n', '<leader>sdg', function()
    local function as_list(x) return type(x) == 'table' and x or (x and { x } or {}) end
    local search_dirs = as_list(vim.fn.stdpath('config'))
    vim.list_extend(search_dirs, as_list(vim.fn.stdpath('data')))
    vim.list_extend(search_dirs, as_list(EXTERNAL_PATHS_GLOBAL()))
    --vim.notify(vim.inspect(search_dirs))
    usertelescope.live_multigrep({ prompt_title = "Dotfile + Lua Grep", search_dirs = search_dirs, file_ignore_patterns = { ".git/" }
    })
end, { desc = '[S]earch [D]otfile [G]rep' })
vim.keymap.set('n', '<leader>sdf', function()
    telescope_builtin.find_files({
        search_dirs = EXTERNAL_PATHS_GLOBAL(),
        hidden = true,
        file_ignore_patterns = { ".git/" }
    })
end, { desc = '[S]earch [D]otfiles [F]iles' })

vim.keymap.set('n', '<leader>ct', function()
    vim.api.nvim_get_current_buf()
    vim.cmd('LspClangdSwitchSourceHeader')
end, { desc = 'Clangd: switch source/header' })

vim.keymap.set('n', 'ss', function()
    require("flash").jump()
end, { desc = 'Jump list teleport (flash)' })

local qf_group = vim.api.nvim_create_augroup('quickfix-nav-maps', { clear = true })
vim.api.nvim_create_autocmd({ 'FileType' }, {
    group = qf_group,
    pattern = 'qf',
    desc = 'Quickfix: map Ctrl-n/Ctrl-p tos:cnext/:cprev',
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


vim.keymap.set('n', '<leader>cd', function()
    local dir = vim.fn.expand('%:p:h')
    vim.cmd('cd ' .. dir)
    print('Changed directory to ' .. dir)
end, { desc = "CD to buffer's dir" })

vim.keymap.set('n', '<leader>yp', function()
    local path = vim.fn.expand('%:p')
    vim.fn.setreg('+', path)
    print('Yanked path: ' .. path)
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


-- local tmux = require("tmux")
-- vim.keymap.set({ {'t', 'n'}, 'n' }, '<C-h>', tmux.move_left, { silent = true })
-- vim.keymap.set({ {'t', 'n'}, 'n' }, '<C-j>', tmux.move_bottom, { silent = true })
-- vim.keymap.set({ {'t', 'n'}, 'n' }, '<C-k>', tmux.move_top, { silent = true })
-- vim.keymap.set({ {'t', 'n'}, 'n' }, '<C-l>', tmux.move_right, { silent = true })
--
--




vim.o.ttimeoutlen = 0



vim.api.nvim_create_autocmd("LspAttach", {
    pattern = { '*.py', '*.lua', '*.bashrc', '*.bash_profile', '*.sh', '*.bash' },
    group = vim.api.nvim_create_augroup("UserLspInlayHints", {}),
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




function ShowCurrentLine()
    local current_line_text = vim.api.nvim_get_current_line()
    local current_line_cursor = vim.api.nvim_win_get_cursor(0)[2]
    if current_line_text == nil then
        return
    end
    local target_start = current_line_cursor + 2
    local lineAfter    = string.sub(current_line_text, target_start, -1)
    local delimiters   = { ",", " ", "}", ')' }

    local pattern      = "[^" .. table.concat(delimiters) .. "]+"
    local matched      = ''
    for match in string.gmatch(lineAfter, pattern) do
        matched = match
        break
    end
    local target_end = #matched

    local unmod_start = string.sub(current_line_text, 1, target_start - 1)
    local unmod_end = string.sub(current_line_text, target_end, -1)
    local replace = unmod_start .. "\"" .. matched .. "\" " .. unmod_end


    --vim.api.nvim_set_current_line(replace)
    -- replace target start and target end



    print(replace)
end

-- Map this function to a key (e.g., <leader>cl)
vim.api.nvim_set_keymap('n', '<Leader>cl', ':lua ShowCurrentLine()<CR>', { noremap = true, silent = true })
