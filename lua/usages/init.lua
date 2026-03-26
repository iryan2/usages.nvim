-- usages.nvim
-- Navigate upward through React component usage hierarchy.
-- Place cursor on a component definition, invoke :Usages,
-- then drill upward through the tree of components that render it.
--
-- Directory structure:
--   lua/usages/init.lua      (this section)
--   lua/usages/resolve.lua   (LSP + treesitter resolution)
--   lua/usages/ui.lua        (sidebar tree buffer)

-- ╔══════════════════════════════════════════════════════════════════╗
-- ║  lua/usages/init.lua                                   ║
-- ╚══════════════════════════════════════════════════════════════════╝

local resolve = require("usages.resolve")
local ui = require("usages.ui")

local M = {}

M.config = {
  max_depth = 10,
  width = 60,
  debug = false,
  max_chain_depth = 5,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  resolve.configure(M.config)

  vim.api.nvim_create_user_command("Usages", function()
    M.show()
  end, { desc = "Show React component ancestor tree" })

  vim.api.nvim_create_user_command("UsagesLog", function()
    local log_lines = resolve.get_log()
    if #log_lines == 0 then
      vim.notify("[usages] No log (enable debug and run :Usages first)", vim.log.levels.INFO)
      return
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, log_lines)
    vim.cmd("split")
    vim.api.nvim_win_set_buf(0, buf)
  end, { desc = "Show usages debug log" })
end

function M.show()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2] -- 0-indexed for LSP/treesitter

  -- If cursor is on a JSX tag name (e.g., Button in <Button />), resolve
  -- its definition and use that as the root. Otherwise fall back to the
  -- enclosing declaration at cursor.
  local root_name, root_filepath, root_row, root_col

  local jsx_id = resolve.jsx_identifier_at_cursor(bufnr, row, col)
  if jsx_id then
    root_name = jsx_id.name
    root_filepath = vim.api.nvim_buf_get_name(bufnr)
    root_row = row
    root_col = col
  end

  if not root_name then
    local component = resolve.component_at_cursor(bufnr, row, col)
    if not component then
      vim.notify("[usages] No component or JSX tag found at cursor", vim.log.levels.WARN)
      return
    end
    root_name = component.name
    root_filepath = vim.api.nvim_buf_get_name(bufnr)
    root_row = component.row
    root_col = component.col
  end

  local root = {
    name = root_name,
    filepath = root_filepath,
    row = root_row,
    col = root_col,
    children = nil, -- nil = not yet loaded; {} = loaded, no results
    expanded = false,
    depth = 0,
    ref_row = nil, -- only set on ancestor nodes (where the reference lives)
    ref_col = nil,
  }

  -- We keep a handle to a buffer with LSP attached, so we can make
  -- reference requests for any file in the project from it.
  local lsp_bufnr = bufnr

  local tree_state = ui.open(root, M.config, lsp_bufnr)

  resolve.find_ancestors(root, lsp_bufnr, function(ancestors, stats)
    vim.schedule(function()
      root.children = ancestors
      if #ancestors > 0 then
        root.expanded = true
      end
      tree_state.stats = stats
      ui.render(tree_state)
    end)
  end)
end

return M
