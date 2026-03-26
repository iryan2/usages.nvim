local resolve = require("usages.resolve")

local M = {}

-- ── Flatten tree into visible lines ─────────────────────────────────

local function flatten(node, list)
  list = list or {}
  table.insert(list, node)
  if node.expanded and node.children then
    for _, child in ipairs(node.children) do
      flatten(child, list)
    end
  end
  return list
end

-- ── Render ──────────────────────────────────────────────────────────

function M.render(state)
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  state.flat = flatten(state.root)

  local lines = {}
  local width = state.config.width or 60

  -- Stats header
  local stats_text
  if state.stats then
    stats_text = string.format("%d refs -> %d ancestors", state.stats.refs, state.stats.ancestors)
  else
    stats_text = "loading..."
  end
  table.insert(lines, stats_text)
  table.insert(lines, string.rep("-", width))
  state.header_offset = 2

  local name_col = 40 -- right-align path info after this column

  for _, node in ipairs(state.flat) do
    local indent = string.rep("  ", node.depth)

    local icon
    if node.children == nil then
      icon = "○" -- not yet loaded
    elseif #node.children == 0 then
      icon = "·" -- leaf
    elseif node.expanded then
      icon = "▼"
    else
      icon = "▶"
    end

    local left = indent .. icon .. " " .. node.name

    local right = ""
    if node.filepath then
      right = vim.fn.fnamemodify(node.filepath, ":~:.")
      if node.ref_row then
        -- For ancestor nodes, show the line where the reference is
        right = right .. ":" .. (node.ref_row + 1)
      elseif node.row then
        right = right .. ":" .. (node.row + 1)
      end
    end

    -- Pad between name and path
    local pad_len = math.max(2, name_col - vim.fn.strdisplaywidth(left))
    local line = left .. string.rep(" ", pad_len) .. right
    table.insert(lines, line)
  end

  -- Footer with keybinding hints
  local preview_label = state.preview and "p: preview [on]" or "p: preview [off]"
  local footer_hints = preview_label .. "  ⏎: jump  o: ref  q: close"
  table.insert(lines, string.rep("─", width))
  table.insert(lines, footer_hints)
  local footer_start = #lines - 2 -- 0-indexed line of the separator

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  -- Apply highlights
  local offset = state.header_offset or 0
  vim.api.nvim_buf_clear_namespace(state.bufnr, state.ns, 0, -1)
  -- Header highlights
  if offset > 0 then
    vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, "Comment", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, "NonText", 1, 0, -1)
  end
  for i, node in ipairs(state.flat) do
    local line_idx = i - 1 + offset
    local indent_len = node.depth * 2
    -- Highlight the icon
    vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, "NonText", line_idx, indent_len, indent_len + #"▶" + 1)
    -- Highlight the component name
    local name_start = indent_len + #"▶ "
    local name_end = name_start + #node.name
    local hl = node.depth == 0 and "Title" or "Function"
    vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, hl, line_idx, name_start, name_end)
    -- Dim the file path
    local line_text = lines[i + offset]
    local path_start = #line_text
      - #(vim.fn.fnamemodify(node.filepath or "", ":~:.") .. ":" .. ((node.ref_row or node.row or 0) + 1))
    if path_start > 0 then
      vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, "Comment", line_idx, path_start, -1)
    end
  end
  -- Footer highlights
  vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, "NonText", footer_start, 0, -1)
  vim.api.nvim_buf_add_highlight(state.bufnr, state.ns, "Comment", footer_start + 1, 0, -1)
end

-- ── Navigation ──────────────────────────────────────────────────────

local function current_node(state)
  if not vim.api.nvim_win_is_valid(state.winnr) then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.winnr)[1]
  local idx = line - (state.header_offset or 0)
  if idx < 1 then
    return nil, line
  end
  return state.flat[idx], line
end


function M.expand_node(state)
  local node, line = current_node(state)
  if not node then
    return
  end

  -- Already expanded with children → move cursor down into first child
  if node.expanded and node.children and #node.children > 0 then
    vim.api.nvim_win_set_cursor(state.winnr, { line + 1, 0 })
    return
  end

  -- Has children from a previous load → just re-expand
  if node.children and #node.children > 0 then
    node.expanded = true
    M.render(state)
    return
  end

  -- Not yet loaded → fetch ancestors via LSP
  if node.children == nil then
    -- Show loading indicator
    node.children = {} -- mark as loading
    node.name = node.name -- keep name; we could add a spinner here
    M.render(state)

    resolve.find_ancestors(node, state.lsp_bufnr, function(ancestors)
      vim.schedule(function()
        node.children = ancestors
        node.expanded = #ancestors > 0
        M.render(state)
      end)
    end)
    return
  end

  -- children == {} → leaf node, nothing to expand
end

function M.collapse_node(state)
  local node, line = current_node(state)
  if not node then
    return
  end

  if node.expanded then
    node.expanded = false
    M.render(state)
    return
  end

  -- Not expanded → move cursor to parent (nearest node above with lower depth)
  local offset = state.header_offset or 0
  local idx = line - offset
  for i = idx - 1, 1, -1 do
    if state.flat[i] and state.flat[i].depth < node.depth then
      vim.api.nvim_win_set_cursor(state.winnr, { i + offset, 0 })
      return
    end
  end
end

function M.jump_to_definition(state)
  local node = current_node(state)
  if not node or not node.filepath then
    return
  end

  if not vim.api.nvim_win_is_valid(state.editor_win) then
    return
  end

  -- Clear saved state so close won't restore
  state.editor_buf = nil
  state.editor_cursor = nil

  vim.api.nvim_set_current_win(state.editor_win)
  vim.cmd("edit " .. vim.fn.fnameescape(node.filepath))
  vim.api.nvim_win_set_cursor(state.editor_win, { node.row + 1, node.col or 0 })
  vim.cmd("normal! zz")
end

function M.jump_to_reference(state)
  local node = current_node(state)
  if not node or not node.ref_row then
    return
  end

  if not vim.api.nvim_win_is_valid(state.editor_win) then
    return
  end

  -- Clear saved state so close won't restore
  state.editor_buf = nil
  state.editor_cursor = nil

  vim.api.nvim_set_current_win(state.editor_win)
  vim.cmd("edit " .. vim.fn.fnameescape(node.filepath))
  vim.api.nvim_win_set_cursor(state.editor_win, { node.ref_row + 1, node.ref_col or 0 })
  vim.cmd("normal! zz")
end

local function preview_current_node(state)
  if not state.preview then
    return
  end
  local node = current_node(state)
  if not node or not node.filepath then
    return
  end
  if not vim.api.nvim_win_is_valid(state.editor_win) then
    return
  end
  local preview_buf = vim.fn.bufadd(node.filepath)
  vim.fn.bufload(preview_buf)
  vim.api.nvim_win_set_buf(state.editor_win, preview_buf)
  vim.api.nvim_win_set_cursor(state.editor_win, { node.row + 1, node.col or 0 })
  vim.api.nvim_win_call(state.editor_win, function()
    vim.cmd("normal! zz")
  end)
end

function M.close(state)
  if state.preview and state.editor_buf and vim.api.nvim_win_is_valid(state.editor_win) then
    vim.api.nvim_win_set_buf(state.editor_win, state.editor_buf)
    vim.api.nvim_win_set_cursor(state.editor_win, state.editor_cursor)
  end
  if vim.api.nvim_win_is_valid(state.winnr) then
    vim.api.nvim_win_close(state.winnr, true)
  end
end

-- ── Open the sidebar ────────────────────────────────────────────────

function M.open(root, config, lsp_bufnr)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "reactancestors"

  -- Capture editor window state for live preview restore
  local editor_win = vim.api.nvim_get_current_win()
  local editor_buf = vim.api.nvim_win_get_buf(editor_win)
  local editor_cursor = vim.api.nvim_win_get_cursor(editor_win)

  -- Open a left-side vertical split
  vim.cmd("topleft vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, config.width or 60)

  -- Clean sidebar appearance
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true

  local state = {
    root = root,
    config = config,
    bufnr = buf,
    winnr = win,
    lsp_bufnr = lsp_bufnr,
    flat = {},
    ns = vim.api.nvim_create_namespace("react_ancestors"),
    editor_win = editor_win,
    editor_buf = editor_buf,
    editor_cursor = editor_cursor,
    preview = true,
  }

  -- Keymaps
  local kopts = { buffer = buf, noremap = true, silent = true }

  vim.keymap.set("n", "l", function()
    M.expand_node(state)
  end, kopts)
  vim.keymap.set("n", "h", function()
    M.collapse_node(state)
  end, kopts)
  vim.keymap.set("n", "<CR>", function()
    M.jump_to_definition(state)
  end, kopts)
  vim.keymap.set("n", "o", function()
    M.jump_to_reference(state)
  end, kopts)
  vim.keymap.set("n", "p", function()
    state.preview = not state.preview
    if state.preview then
      preview_current_node(state)
    elseif state.editor_buf and vim.api.nvim_win_is_valid(state.editor_win) then
      vim.api.nvim_win_set_buf(state.editor_win, state.editor_buf)
      vim.api.nvim_win_set_cursor(state.editor_win, state.editor_cursor)
    end
    M.render(state)
  end, kopts)
  vim.keymap.set("n", "q", function()
    M.close(state)
  end, kopts)

  -- Live preview: update editor window as cursor moves through sidebar
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      preview_current_node(state)
    end,
  })

  -- Return focus to the tree window after setup
  vim.api.nvim_set_current_win(win)

  M.render(state)
  return state
end

return M
