local M = {}

-- ── Configuration ─────────────────────────────────────────────────

M._config = { debug = false, max_chain_depth = 5 }

function M.configure(config)
  M._config = config
end

M._log = {}

local function log(msg, ...)
  if M._config.debug then
    table.insert(M._log, string.format(msg, ...))
  end
end

function M.get_log()
  return M._log
end

-- ── Helpers ─────────────────────────────────────────────────────────

local function get_text(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr)
end

--- Load a buffer for a filepath (no window needed) and ensure its
--- filetype is set so treesitter can parse it.
local function ensure_buf(filepath)
  local bufnr = vim.fn.bufadd(filepath)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    vim.bo[bufnr].swapfile = false
  end
  vim.fn.bufload(bufnr)
  if vim.bo[bufnr].filetype == "" then
    local ft = vim.filetype.match({ filename = filepath, buf = bufnr })
    if ft then
      vim.bo[bufnr].filetype = ft
    end
  end
  return bufnr
end

-- ── LSP client helpers ──────────────────────────────────────────────

local TS_CLIENT_NAMES = {
  ts_ls = true,
  vtsls = true,
  tsserver = true,
  ["typescript-language-server"] = true,
}

--- Get all TypeScript LSP clients, prioritising those attached to lsp_bufnr.
local function get_ts_clients(lsp_bufnr)
  local buf_clients = vim.lsp.get_clients({
    bufnr = lsp_bufnr,
    method = "textDocument/references",
  })

  local all_clients = vim.lsp.get_clients({
    method = "textDocument/references",
  })

  local seen = {}
  local result = {}

  -- Buffer-attached clients first
  for _, c in ipairs(buf_clients) do
    if not seen[c.id] then
      seen[c.id] = true
      table.insert(result, c)
    end
  end

  -- Other TS clients from the session
  for _, c in ipairs(all_clients) do
    if not seen[c.id] and TS_CLIENT_NAMES[c.name] then
      seen[c.id] = true
      table.insert(result, c)
    end
  end

  return result
end

--- Find a buffer that a given client is attached to, for making requests.
local function get_request_bufnr(client, fallback_bufnr)
  local bufs = vim.lsp.get_buffers_by_client_id(client.id)
  if bufs then
    for _, b in ipairs(bufs) do
      if b == fallback_bufnr then
        return fallback_bufnr
      end
    end
    if #bufs > 0 then
      return bufs[1]
    end
  end
  return fallback_bufnr
end

-- ── Treesitter: detect JSX tag identifier at cursor ─────────────────

local JSX_TAG_PARENTS = {
  jsx_self_closing_element = true,
  jsx_opening_element = true,
  jsx_closing_element = true,
}

--- Check if cursor is on a JSX tag name (e.g., `Button` in `<Button />`).
---@return { name: string } | nil
function M.jsx_identifier_at_cursor(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    return nil
  end

  local root = trees[1]:root()
  local node = root:named_descendant_for_range(row, col, row, col)

  if node and node:type() == "identifier" then
    local parent = node:parent()
    if parent and JSX_TAG_PARENTS[parent:type()] then
      return { name = get_text(node, bufnr) }
    end
  end

  return nil
end

-- ── LSP: resolve definition synchronously ────────────────────────────

--- Resolve the definition of the symbol at (row, col) via LSP.
---@return { filepath: string, row: number, col: number } | nil
function M.resolve_definition_sync(bufnr, row, col)
  local params = {
    textDocument = { uri = vim.uri_from_fname(vim.api.nvim_buf_get_name(bufnr)) },
    position = { line = row, character = col },
  }

  local clients = get_ts_clients(bufnr)
  for _, client in ipairs(clients) do
    local req_bufnr = get_request_bufnr(client, bufnr)
    local result = client.request_sync("textDocument/definition", params, 5000, req_bufnr)
    if result and result.result then
      local defs = result.result
      -- Handle single Location or array of Locations/LocationLinks
      if defs.uri or defs.targetUri then
        defs = { defs }
      end
      if #defs > 0 then
        local def = defs[1]
        local uri = def.targetUri or def.uri
        local range = def.targetSelectionRange or def.targetRange or def.range
        if uri and range then
          return {
            filepath = vim.uri_to_fname(uri),
            row = range.start.line,
            col = range.start.character,
          }
        end
      end
    end
  end

  return nil
end

-- ── Treesitter: find enclosing component ────────────────────────────

--- Try to extract a named declaration from a treesitter node.
--- Recognises function_declaration and variable_declarator with any name.
---@return { name: string, row: number, col: number } | nil
local function try_extract_component(node, bufnr)
  local ntype = node:type()

  if ntype == "function_declaration" or ntype == "variable_declarator" then
    local name_node = node:field("name")[1]
    if name_node then
      local name = get_text(name_node, bufnr)
      if name then
        local sr, sc = name_node:start()
        return { name = name, row = sr, col = sc }
      end
    end
  end

  return nil
end

--- Walk up from (row, col) to find the nearest enclosing named declaration.
---@param bufnr number
---@param row number 0-indexed
---@param col number 0-indexed
---@return { name: string, row: number, col: number } | nil
function M.component_at_cursor(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    return nil
  end

  local root = trees[1]:root()
  local node = root:named_descendant_for_range(row, col, row, col)

  while node do
    local result = try_extract_component(node, bufnr)
    if result then
      return result
    end
    node = node:parent()
  end

  return nil
end

-- ── Treesitter: detect re-export sites ──────────────────────────────

--- Check if a reference position is inside a re-export statement
--- (e.g., `export { Button } from "./Button"`).
--- Only matches exports with a `from "..."` source clause.
local function is_reexport(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return false
  end

  local trees = parser:parse()
  if not trees or #trees == 0 then
    return false
  end

  local root = trees[1]:root()
  local node = root:named_descendant_for_range(row, col, row, col)

  while node do
    local ntype = node:type()
    if ntype == "export_statement" then
      local source = node:field("source")
      return source and #source > 0
    end
    if ntype == "program" then
      break
    end
    node = node:parent()
  end

  return false
end

-- ── LSP: find references → resolve parent components ────────────────

--- Internal: recursively query references and follow re-export chains.
--- Uses a shared `state` table for async coordination across all hops.
local function query_refs(filepath, row, col, source_node, state, chain_depth, lsp_bufnr)
  local max_chain_depth = M._config.max_chain_depth or 5

  -- Prevent re-querying the same position
  local query_key = filepath .. ":" .. row .. ":" .. col
  if state.seen_queries[query_key] then
    log("skip already-queried position: %s:%d:%d", vim.fn.fnamemodify(filepath, ":t"), row, col)
    return
  end
  state.seen_queries[query_key] = true

  local clients = get_ts_clients(lsp_bufnr)
  if #clients == 0 then
    if chain_depth == 0 then
      vim.notify("[usages] No LSP client with references support", vim.log.levels.WARN)
    end
    return
  end

  local params = {
    textDocument = { uri = vim.uri_from_fname(filepath) },
    position = { line = row, character = col },
    context = { includeDeclaration = false },
  }

  for _, client in ipairs(clients) do
    state.pending = state.pending + 1
    local req_bufnr = get_request_bufnr(client, lsp_bufnr)

    log("query %s:%d:%d (chain %d) via %s", vim.fn.fnamemodify(filepath, ":t"), row, col, chain_depth, client.name)

    local ok, _ = client:request("textDocument/references", params, function(err, result)
      vim.schedule(function()
        if err then
          log("LSP error: %s", vim.inspect(err))
        end

        local reexports = {}

        if not err and result then
          state.stats.refs = state.stats.refs + #result
          log("  %d refs from %s (chain %d)", #result, vim.fn.fnamemodify(filepath, ":t"), chain_depth)

          for _, ref in ipairs(result) do
            local ref_path = vim.uri_to_fname(ref.uri)
            local ref_row = ref.range.start.line
            local ref_col = ref.range.start.character

            local ref_bufnr = ensure_buf(ref_path)
            local parent = M.component_at_cursor(ref_bufnr, ref_row, ref_col)

            if parent and not (parent.name == source_node.name and ref_path == source_node.filepath) then
              local key = ref_path .. ":" .. parent.name
              if not state.seen_ancestors[key] then
                state.seen_ancestors[key] = true
                log("  + ancestor: %s in %s", parent.name, vim.fn.fnamemodify(ref_path, ":t"))
                table.insert(state.ancestors, {
                  name = parent.name,
                  filepath = ref_path,
                  row = parent.row,
                  col = parent.col,
                  children = nil,
                  expanded = false,
                  depth = source_node.depth + 1,
                  ref_row = ref_row,
                  ref_col = ref_col,
                })
              end
            elseif not parent and chain_depth < max_chain_depth then
              if is_reexport(ref_bufnr, ref_row, ref_col) then
                state.stats.reexports = state.stats.reexports + 1
                log("  -> re-export: %s:%d:%d", vim.fn.fnamemodify(ref_path, ":t"), ref_row, ref_col)
                table.insert(reexports, { path = ref_path, row = ref_row, col = ref_col })
              else
                log("  . skip non-component: %s:%d:%d", vim.fn.fnamemodify(ref_path, ":t"), ref_row, ref_col)
              end
            end
          end

          -- Start recursive queries BEFORE decrementing pending,
          -- so the counter stays positive while work remains.
          for _, re in ipairs(reexports) do
            query_refs(re.path, re.row, re.col, source_node, state, chain_depth + 1, lsp_bufnr)
          end
        end

        state.pending = state.pending - 1
        if state.pending == 0 and not state.done then
          state.done = true
          table.sort(state.ancestors, function(a, b)
            return a.name < b.name
          end)
          state.stats.ancestors = #state.ancestors
          log("done: %d refs -> %d ancestors", state.stats.refs, state.stats.ancestors)
          state.root_callback(state.ancestors)
        end
      end)
    end, req_bufnr)

    if not ok then
      log("failed to send request to %s", client.name)
      state.pending = state.pending - 1
    end
  end
end

--- Given a tree node (with filepath, row, col), find all components
--- that render it by:
---   1. Calling textDocument/references via LSP (all TS clients)
---   2. For each reference site, loading the buffer and walking
---      treesitter upward to find the enclosing component
---   3. Following re-export chains when references land on barrel
---      exports with no enclosing component
---
---@param tree_node table  A node from the UI tree
---@param lsp_bufnr number A buffer with an attached LSP client
---@param callback fun(ancestors: table[])
function M.find_ancestors(tree_node, lsp_bufnr, callback)
  M._log = {}

  local state = {
    ancestors = {},
    seen_ancestors = {}, -- dedup by filepath:componentName
    seen_queries = {}, -- prevent re-querying same position
    pending = 0,
    done = false,
    stats = { refs = 0, ancestors = 0, reexports = 0 },
  }
  state.root_callback = function(ancestors)
    callback(ancestors, state.stats)
  end

  query_refs(tree_node.filepath, tree_node.row, tree_node.col, tree_node, state, 0, lsp_bufnr)

  -- If no queries were started (no clients), call back immediately
  if state.pending == 0 and not state.done then
    state.done = true
    callback({}, state.stats)
  end
end

return M
