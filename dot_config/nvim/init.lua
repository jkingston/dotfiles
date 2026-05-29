-- Minimal Neovim Config (requires nvim 0.12+)

-- Options
vim.opt.number = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.termguicolors = true
vim.opt.signcolumn = "yes"
vim.opt.updatetime = 250
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.clipboard = "unnamedplus"

-- Leader key
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Plugins
vim.pack.add({
	"https://github.com/nvim-treesitter/nvim-treesitter",
	"https://github.com/neovim/nvim-lspconfig",
	"https://github.com/catppuccin/nvim",
	"https://github.com/lewis6991/gitsigns.nvim",
	"https://github.com/nvim-lualine/lualine.nvim",
	"https://github.com/stevearc/conform.nvim",
	"https://github.com/folke/which-key.nvim",
	"https://github.com/Saghen/blink.lib",
	"https://github.com/Saghen/blink.cmp",
})

-- Colorscheme
vim.cmd.colorscheme("catppuccin-nvim")

-- Line number glow effect
vim.opt.cursorline = true
vim.opt.cursorlineopt = "number"

local glow_ns = vim.api.nvim_create_namespace("line_glow")

local function get_hl_fg(name)
	local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
	return hl.fg and string.format("#%06x", hl.fg) or nil
end

local function hex_to_rgb(hex)
	hex = hex:gsub("#", "")
	return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
end

local function blend(fg, bg, alpha)
	local r1, g1, b1 = hex_to_rgb(fg)
	local r2, g2, b2 = hex_to_rgb(bg)
	return string.format(
		"#%02x%02x%02x",
		math.floor(r1 * alpha + r2 * (1 - alpha)),
		math.floor(g1 * alpha + g2 * (1 - alpha)),
		math.floor(b1 * alpha + b2 * (1 - alpha))
	)
end

local function setup_glow_highlights()
	local accent = get_hl_fg("Special") or get_hl_fg("Statement") or "#f5c2e7"
	local dim = get_hl_fg("LineNr") or get_hl_fg("Comment") or "#585b70"

	vim.api.nvim_set_hl(0, "LineGlow1", { fg = accent, bold = true })
	vim.api.nvim_set_hl(0, "LineGlow2", { fg = blend(accent, dim, 0.3) })
end

setup_glow_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = setup_glow_highlights })

local function update_glow()
	local buf = vim.api.nvim_get_current_buf()
	local cursor = vim.api.nvim_win_get_cursor(0)[1]
	local total = vim.api.nvim_buf_line_count(buf)

	vim.api.nvim_buf_clear_namespace(buf, glow_ns, 0, -1)

	for offset = -1, 1 do
		local line = cursor + offset
		if line >= 1 and line <= total then
			local hl = "LineGlow" .. (math.abs(offset) + 1)
			vim.api.nvim_buf_set_extmark(buf, glow_ns, line - 1, 0, {
				number_hl_group = hl,
			})
		end
	end
end

vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
	callback = update_glow,
})

-- Treesitter (new API for nvim 0.11+)
require("nvim-treesitter").install({
	"lua",
	"vim",
	"vimdoc",
	"python",
	"rust",
	"zig",
	"json",
	"yaml",
	"toml",
	"markdown",
})

-- Enable treesitter highlighting and indentation for all filetypes
vim.api.nvim_create_autocmd("FileType", {
	callback = function()
		pcall(vim.treesitter.start)
		vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
	end,
})

-- LSP (native API for nvim 0.11+)
-- nvim-lspconfig provides configs via lsp/<name>.lua in runtimepath
vim.lsp.enable({ "lua_ls", "pyright", "rust_analyzer", "zls" })

-- LSP keymaps (on attach)
vim.api.nvim_create_autocmd("LspAttach", {
	callback = function(args)
		local b = args.buf
		vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = b, desc = "Go to definition" })
		vim.keymap.set("n", "gD", vim.lsp.buf.declaration, { buffer = b, desc = "Go to declaration" })
		vim.keymap.set("n", "gr", vim.lsp.buf.references, { buffer = b, desc = "Go to references" })
		vim.keymap.set("n", "gi", vim.lsp.buf.implementation, { buffer = b, desc = "Go to implementation" })
		vim.keymap.set("n", "K", vim.lsp.buf.hover, { buffer = b, desc = "Hover docs" })
		vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, { buffer = b, desc = "Code action" })
		vim.keymap.set("n", "<leader>cr", vim.lsp.buf.rename, { buffer = b, desc = "Rename symbol" })
		vim.keymap.set("n", "<leader>cf", vim.lsp.buf.format, { buffer = b, desc = "Format file" })
		vim.keymap.set("n", "<leader>cd", vim.diagnostic.open_float, { buffer = b, desc = "Line diagnostics" })
		vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { buffer = b, desc = "Prev diagnostic" })
		vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { buffer = b, desc = "Next diagnostic" })
	end,
})

-- Completion
local cmp = require("blink.cmp")
cmp.build():wait(60000)
cmp.setup({
	completion = {
		ghost_text = { enabled = true },
	},
	keymap = {
		preset = "default",
		["<CR>"] = { "accept", "fallback" },
	},
})

-- Gitsigns
require("gitsigns").setup()

-- Lualine
require("lualine").setup({
	options = {
		theme = "catppuccin-nvim",
		component_separators = "|",
		section_separators = "",
	},
})

-- Conform (formatting)
require("conform").setup({
	formatters_by_ft = {
		lua = { "stylua" },
		python = { "ruff_format" },
		rust = { "rustfmt" },
		zig = { "zigfmt" },
		json = { "prettier" },
		yaml = { "prettier" },
		markdown = { "prettier" },
	},
	format_on_save = {
		timeout_ms = 500,
		lsp_fallback = true,
	},
})

-- Which-key
require("which-key").setup({ delay = 300 })
require("which-key").add({
	{ "<leader>b", group = "Buffer" },
	{ "<leader>c", group = "Code" },
	{ "<leader>f", group = "File" },
	{ "<leader>g", group = "Git" },
	{ "<leader>x", group = "Diagnostics" },
})

-- Keymaps

-- General
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<cr>")
vim.keymap.set("n", "<leader>qq", "<cmd>qa<cr>", { desc = "Quit all" })
vim.keymap.set("n", "<leader>?", function()
	local buf = vim.api.nvim_create_buf(false, true)
	local readme = vim.fn.readfile(vim.fn.stdpath("config") .. "/README.md")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, readme)
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = math.floor(vim.o.columns * 0.8),
		height = math.floor(vim.o.lines * 0.8),
		row = math.floor(vim.o.lines * 0.1),
		col = math.floor(vim.o.columns * 0.1),
		style = "minimal",
		border = "rounded",
	})
	vim.cmd("/Keybindings Cheatsheet")
	vim.cmd("normal! zt")
	vim.cmd("nohlsearch")
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf })
end, { desc = "Cheatsheet" })

-- Files
vim.keymap.set("n", "<leader>w", "<cmd>w<cr>", { desc = "Save file" })
vim.keymap.set("n", "<leader>fn", "<cmd>enew<cr>", { desc = "New file" })

-- Buffers
vim.keymap.set("n", "<S-h>", "<cmd>bprevious<cr>", { desc = "Prev buffer" })
vim.keymap.set("n", "<S-l>", "<cmd>bnext<cr>", { desc = "Next buffer" })
vim.keymap.set("n", "<leader>bd", "<cmd>bdelete<cr>", { desc = "Delete buffer" })

-- Windows
vim.keymap.set("n", "<leader>-", "<cmd>split<cr>", { desc = "Split below" })
vim.keymap.set("n", "<leader>|", "<cmd>vsplit<cr>", { desc = "Split right" })
vim.keymap.set("n", "<leader>wd", "<cmd>close<cr>", { desc = "Close window" })
vim.keymap.set("n", "<C-h>", "<C-w>h", { desc = "Go to left window" })
vim.keymap.set("n", "<C-j>", "<C-w>j", { desc = "Go to lower window" })
vim.keymap.set("n", "<C-k>", "<C-w>k", { desc = "Go to upper window" })
vim.keymap.set("n", "<C-l>", "<C-w>l", { desc = "Go to right window" })

-- Diagnostics
vim.keymap.set("n", "<leader>xq", "<cmd>copen<cr>", { desc = "Quickfix list" })
vim.keymap.set("n", "<leader>xl", "<cmd>lopen<cr>", { desc = "Location list" })
vim.keymap.set("n", "[q", "<cmd>cprev<cr>", { desc = "Prev quickfix" })
vim.keymap.set("n", "]q", "<cmd>cnext<cr>", { desc = "Next quickfix" })

-- Git (gitsigns)
vim.keymap.set("n", "]c", function()
	require("gitsigns").next_hunk()
end, { desc = "Next git hunk" })
vim.keymap.set("n", "[c", function()
	require("gitsigns").prev_hunk()
end, { desc = "Prev git hunk" })
vim.keymap.set("n", "<leader>gb", function()
	require("gitsigns").blame_line()
end, { desc = "Git blame" })
vim.keymap.set("n", "<leader>gp", function()
	require("gitsigns").preview_hunk()
end, { desc = "Preview hunk" })
vim.keymap.set("n", "<leader>gr", function()
	require("gitsigns").reset_hunk()
end, { desc = "Reset hunk" })
