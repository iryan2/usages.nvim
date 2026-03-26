usages.nvim — Project Context
What this is
A Neovim plugin that lets you navigate upward through a React component's usage hierarchy — the inverse of "go to definition." Place your cursor on a component definition, run :Usages, and a sidebar opens showing every component that renders it. Expand any ancestor to see its ancestors, drilling all the way up to App. Think Ranger-style directory navigation but for component ancestry: CreateReleaseButton → CreateReleasePage → AllPageRegistrations → AllRoutes → App.
How it works
The core loop is: find export → get references → resolve enclosing component → repeat.

Treesitter walks upward from the cursor to find the nearest enclosing React component (PascalCase function_declaration or variable_declarator).
LSP textDocument/references finds all usage sites of that component's name identifier. This catches JSX usage (<Foo />), render prop passing (renderItem={Foo}), and re-exports.
For each reference, the plugin loads the target file into a hidden buffer, sets its filetype for treesitter, and walks upward from the reference site to find the enclosing parent component.
Results are deduplicated by filepath:componentName and presented in a sidebar tree buffer.
Expansion is lazy — children are only fetched when you press l on a node.

LSP requests are sent to all TypeScript LSP clients in the session (ts_ls, vtsls, tsserver), not just the one attached to the invoking buffer. This handles monorepos where different packages may have different LSP instances.
When a reference lands on a re-export (e.g., barrel `export { Button } from "./Button"`), the plugin follows the chain by recursively querying references at the re-export position. This crosses package boundaries in monorepos where the component is re-exported through index files before reaching consumer code. Chain depth is limited by `max_chain_depth` (default 5).
Current state
A working first draft exists as a single-file prototype split into three logical modules:

lua/usages/init.lua — setup, user command, entry point
lua/usages/resolve.lua — component_at_cursor() (treesitter upward walk), find_ancestors() (LSP references → treesitter resolution)
lua/usages/ui.lua — sidebar buffer, tree rendering, keymaps

Sidebar keybindings

l — expand node (lazy-loads ancestors via LSP on first expand)
h — collapse node, or move cursor to parent
<CR> — jump to component definition in editor window
o — jump to reference site (where the component is rendered)
q — close sidebar

Each tree node stores
lua{
name, -- component name (PascalCase)
filepath, -- absolute path to file
row, col, -- position of the component's name identifier (0-indexed)
children, -- nil (not loaded) | {} (leaf) | table (ancestors)
expanded, -- boolean
depth, -- integer, for indentation
ref_row, -- line of the reference site (only on ancestor nodes)
ref_col, -- column of the reference site
}

Configuration options (passed to setup())

max_depth = 10 — maximum tree expansion depth
width = 60 — sidebar width
debug = false — when true, logs LSP queries, reference counts, re-export chain hops, and ancestor resolution via vim.notify
max_chain_depth = 5 — maximum re-export chain hops to follow

Technical environment

Neovim with treesitter and LSP (tsserver / typescript-language-server)
TypeScript/TSX React codebase
Plugin is pure Lua, no external dependencies beyond Neovim builtins
