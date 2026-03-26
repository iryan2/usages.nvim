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

All LSP requests are routed through the original buffer (which has tsserver attached), varying only the textDocument.uri in params.
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
Known limitations to address

Highlight calculation: The path highlight offset in ui.lua is fragile (does string length math that can misalign with multibyte icon characters). Should use vim.fn.strdisplaywidth or calculate column positions during line construction.
Self-reference filtering: Currently name-based, which could false-positive if two different components share a name. The dedup key (filepath:name) mostly covers this but the filtering check itself only compares names.
No refresh/re-root: No way to re-root the tree on the currently selected node (i.e., "start a new ancestor search from this component").

Technical environment

Neovim with treesitter and LSP (tsserver / typescript-language-server)
TypeScript/TSX React codebase
Plugin is pure Lua, no external dependencies beyond Neovim builtins
