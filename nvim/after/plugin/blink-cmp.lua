require("luasnip.loaders.from_vscode").lazy_load()
local blink = require("blink.cmp")
blink.setup({
    -- 'default' (recommended) for mappings similar to built-in completions (C-y to accept)
    -- 'super-tab' for mappings similar to vscode (tab to accept)
    -- 'enter' for enter to accept
    -- 'none' for no mappings
    --
    -- All presets have the following mappings:
    -- C-space: Open menu or open docs if already open
    -- C-n/C-p or Up/Down: Select next/previous item
    -- C-e: Hide menu
    -- C-k: Toggle signature help (if signature.enabled = true)
    --
    -- See :h blink-cmp-config-keymap for defining your own keymap
    keymap = {
        ['<C-u>'] = { 'scroll_documentation_down', 'fallback' },
        ['<C-d>'] = { 'scroll_documentation_down', 'fallback' },
    },
    -- fuzzy = {
    -- 	implementation = "lua", -- use Lua fallback instead of Rust
    -- },


    signature = { enabled = true },
    appearance = {
        -- 'mono' (default) for 'Nerd Font Mono' or 'normal' for 'Nerd Font'
        -- Adjusts spacing to ensure icons are aligned
        nerd_font_variant = 'normal'
    },

    -- (Default) Only show the documentation popup when manually triggered
    completion = { documentation = { auto_show = true } },

    -- Default list of enabled providers defined so that you can extend it
    -- elsewhere in your config, without redefining it, due to `opts_extend`
    sources = {
        default = { 'lsp', 'path', 'cmdline', 'snippets', 'buffer' }
    },




    -- (Default) Rust fuzzy matcher for typo resistance and significantly better performance
    -- You may use a lua implementation instead by using `implementation = "lua"` or fallback to the lua implementation,
    -- when the Rust fuzzy matcher is not available, by using `implementation = "prefer_rust"`
    --
    -- See the fuzzy documentation for more information
    fuzzy = { implementation = "prefer_rust_with_warning" }
}
)

-- add to your init.lua (requires hrsh7th/nvim-cmp + hrsh7th/cmp-path + hrsh7th/cmp-cmdline)
local cmp = require('cmp')

-- regular insert-mode setup already done elsewhere
-- enable cmp for commandline:
cmp.setup.cmdline(':', {
    mapping = cmp.mapping.preset.cmdline(),
    sources = cmp.config.sources({
            { name = 'path' } -- file path completion for :e, :find, etc.
        },
        -- {
        -- 	name = 'buffer',
        -- 	option = {
        -- 		-- use all listed buffers as source (so completion sees other buffers too)
        -- 		get_bufnrs = function() return vim.api.nvim_list_bufs() end
        -- 	}
        -- },

        -- {
        -- 	name = 'bd',
        -- 	option = {
        -- 		-- use all listed buffers as source (so completion sees other buffers too)
        -- 		get_bufnrs = function() return vim.api.nvim_list_bufs() end
        -- 	}
        -- },
        {
            { name = 'cmdline' } -- command names / args
        }

    )
})


local cmp_autopairs = require('nvim-autopairs.completion.cmp')
cmp.event:on('confirm_done', cmp_autopairs.on_confirm_done())


-- RTFM. control w is standard for going up one directory override below will work but we dont want that

-- vim.keymap.set('c', '<C-U>', function()
-- 	vim.fn.feedkeys(vim.api.nvim_replace_termcodes('<C-W>', true, false, true), 'n')
-- end, { noremap = true, silent = true })



-- optionally for search:
-- cmp.setup.cmdline('/', {
-- 	mapping = cmp.mapping.preset.cmdline(),
-- 	sources = { { name = 'buffer' } }
-- })
