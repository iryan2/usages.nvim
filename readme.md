# usages.nvim

Navigate **upward** through a React component's usage hierarchy — the inverse of "go to definition."

Place your cursor on a component definition, run `:Usages`, and a sidebar opens showing every component that renders it. Expand any ancestor to see *its* ancestors, drilling all the way up to `App`.

```
CreateReleaseButton → CreateReleasePage → AllPageRegistrations → AllRoutes → App
```

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "iryan2/usages.nvim",
  opts = {
    width = 60,          -- sidebar width (default: 60)
    max_depth = 10,      -- maximum tree expansion depth (default: 10)
    max_chain_depth = 5, -- maximum re-export chain hops (default: 5)
    debug = false,       -- enable debug logging (default: false)
  },
}
```

### Requirements

- Neovim with treesitter and LSP (`tsserver` / `typescript-language-server`)
- TypeScript/TSX React codebase

## How it works

The core loop is: **find export → get references → resolve enclosing component → repeat.**

1. **Treesitter** walks upward from the cursor to find the nearest enclosing React component (PascalCase `function_declaration` or `variable_declarator`).
2. **LSP** `textDocument/references` finds all usage sites of that component's name identifier — JSX usage (`<Foo />`), render prop passing (`renderItem={Foo}`), and re-exports.
3. For each reference, the plugin loads the target file into a hidden buffer, sets its filetype for treesitter, and walks upward from the reference site to find the **enclosing parent component**.
4. Results are **deduplicated** by `filepath:componentName` and presented in a sidebar tree buffer.
5. Expansion is **lazy** — children are only fetched when you press `l` on a node.

All LSP requests are routed through the original buffer (which has tsserver attached), varying only the `textDocument.uri` in params.

## Keybindings

| Key    | Action                                          |
|--------|--------------------------------------------------|
| `l`    | Expand node (lazy-loads ancestors via LSP)       |
| `h`    | Collapse node, or move cursor to parent          |
| `<CR>` | Jump to component definition in editor window    |
| `o`    | Jump to reference site (where component is used) |
| `q`    | Close sidebar                                    |

## Plugin structure

```
lua/usages/init.lua      — setup, user command, entry point
lua/usages/resolve.lua   — component_at_cursor(), find_ancestors()
lua/usages/ui.lua        — sidebar buffer, tree rendering, keymaps
```
