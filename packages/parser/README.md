# Neovim setup

Generate and build the parser from this directory:

```sh
tree-sitter generate
tree-sitter build -o patra.so .
```

Add this to your Neovim config, replacing the repository path with your local
checkout path:

```lua
local parser_dir = "/path/to/patra/packages/parser"

vim.filetype.add({ extension = { patra = "patra" } })
vim.opt.runtimepath:prepend(parser_dir)
vim.treesitter.language.add("patra", {
  path = parser_dir .. "/patra.so",
})
vim.treesitter.language.register("patra", "patra")

vim.api.nvim_create_autocmd("FileType", {
  pattern = "patra",
  callback = function(args)
    vim.treesitter.start(args.buf, "patra")
  end,
})
```

The `queries/patra/injections.scm` query routes frontmatter to YAML, both Odin
blocks to Odin, `lang="ts"` or `lang="typescript"` scripts to TypeScript,
`lang="js"` or `lang="javascript"` scripts to JavaScript, style bodies to
CSS, and text between Patra blocks to HTML. Use `#` for YAML comments. Page
settings such as rendering options belong under a normal YAML key, for example
`rendering:`, so the frontmatter remains valid YAML.

Neovim must also have those language parsers installed; missing parsers are
skipped. The default config includes Odin in its automatic install list. The
Odin parser is currently marked unstable by nvim-treesitter.

To inspect the Patra tree in Neovim, open a `.patra` file and run
`:InspectTree`. Use `:checkhealth vim.treesitter` to check parser availability.
