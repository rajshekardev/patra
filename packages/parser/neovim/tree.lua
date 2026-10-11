vim.pack.add({
  "https://github.com/nvim-treesitter/nvim-treesitter",
})

vim.filetype.add({ extension = { patra = "patra" } })

local patra_parser = vim.fn.stdpath("data") .. "/site/parser/patra.so"
vim.treesitter.language.add("patra", { path = patra_parser })
vim.treesitter.language.register("patra", "patra")

local ts = require("nvim-treesitter")

local ensure_installed = {
  -- languages
  "lua", "vim", "vimdoc", "query", "bash", "c", "cpp", "go",
  "rust", "python", "javascript", "typescript", "tsx", "json",
  "yaml", "html", "css", "svelte", "odin",

  -- extras
  "http", "dockerfile",
}

ts.install(ensure_installed)

vim.api.nvim_create_autocmd("FileType", {
  pattern = "*",
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    local lang = vim.treesitter.language.get_lang(ft)
    if not lang then return end
    pcall(vim.treesitter.start, args.buf, lang)
  end,
})
