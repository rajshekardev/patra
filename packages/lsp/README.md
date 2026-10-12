# patra-lsp

`patra-lsp` is an experimental language server for `.patra` files. It sends each block body to its language server as a separate virtual document, then maps diagnostics, symbols, formatting edits, code actions, and other language features back to the original file. Block tags and delimiters are excluded from virtual source. Odin blocks receive a synthetic `package patra` line for OLS; it is not added to the `.patra` source. Temporary backing files let OLS run Odin's checker on each block so unresolved names such as an unimported `fmt` are reported; these files are removed when the document closes.

## Supported blocks

- `--- ... ---` frontmatter → YAML
- `<odin server> ... </odin>` and `<odin client> ... </odin>` → OLS
- `<script lang="ts">` / `lang="typescript"` → TypeScript; `lang="js"` / `lang="javascript"` or no `lang` → JavaScript
- markup between Patra blocks → HTML
- `<style> ... </style>` → CSS

The parser recognizes regions without altering the source file. YAML stays valid YAML, including `#` comments; the LSP does not add Patra-only syntax to it.

## Visibility and data flow

The Odin server block is the data and type authority.

- Server values and types can be referenced by YAML frontmatter and HTML. HTML references represent values available during server-side rendering.
- Odin client and script blocks do not receive server values. They receive server type declarations only, so values must be fetched through registered RPC endpoints.
- A server registration such as `rpc.demo.greet.list(list_greetings)` produces a typed `rpc.demo.greet.list.query()` completion. Procedures with non-context parameters are exposed as mutations. The RPC call is the client/script boundary; the raw handler and server state are not exposed.
- Odin client declarations can be used by scripts and HTML. Script declarations can be used by HTML.
- CSS receives HTML `id`/`class` selectors and only client/script values marked for CSS export.

Mark CSS values with a regular comment immediately above the declaration. This remains valid Odin or TypeScript/JavaScript syntax:

```odin
// @patra css --accent
accent: string = "#38bdf8"
```

```css
button { color: var(--accent); }
```

The custom property defaults to the exported name converted to kebab case, so `focusRing` maps to `--focus-ring`. An explicit `--name` overrides it. The LSP adds virtual CSS declarations for completion and checking; it does not change the `.patra` source.

The LSP provides editor completions, definitions, generated type declarations, and routed diagnostics. Its declaration scanner is intentionally lightweight. Runtime SSR embedding, RPC dispatch, and CSS variable updates must be implemented by the Patra compiler/runtime; this package does not execute those features.

## Install

```sh
bun add --global patra-lsp
```

The executable requires Node.js 20 or newer. It also launches the language servers below, which must be installed and available on `PATH`:

- OLS (`ols`)
- `yaml-language-server`
- `vscode-html-language-server`
- `vscode-css-language-server`
- `typescript-language-server` (with TypeScript available to it)

Override executable names with `PATRA_OLS`, `PATRA_YAML_LSP`, `PATRA_HTML_LSP`, `PATRA_CSS_LSP`, and `PATRA_TS_LSP` if needed.

## Neovim

```lua
vim.lsp.config("patra", {
  cmd = { "patra-lsp", "--stdio" },
  filetypes = { "patra" },
})
vim.lsp.enable("patra")
```

The repository's Neovim module enables this client automatically. Use `<leader>pt` to open its MiniPick controls and update the package.

## Development

```sh
npm install
npm test
npm pack --dry-run
```

Publish from this directory with `npm publish --access public` after setting the intended package version and logging in to npm.
