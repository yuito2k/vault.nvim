local api   = vim.api
local state = require('vault.state').state

local M     = {}

-- inline search (Ctrl+/)
M.search_state = {
  active       = false,
  query        = '',
  matches      = {},  -- { row_idx, col_idx, col_start, col_end }
  match_count  = 0,
  ns           = api.nvim_create_namespace('SearchHL'),
}

-- ■■■ Inline Search (Ctrl+/) ■■■
local function search_render(r_ovr_win, r_ovr_buf)
  local current_set = state.result_sets and state.result_sets[state.result_set_index]
  if not current_set then return end

  local query    = M.search_state.query
  local filtered = M.search_state.filtered_rows  -- only matched rows
  local count_str   = M.search_state.match_count .. '/' .. #current_set.rows
  local header_line = '/ ' .. query .. ' ' .. count_str

  -- Compute column widths from FULL dataset (so columns don't jump)
  local win_id    = vim.fn.bufwinid(r_ovr_buf)
  local win_width = win_id ~= -1 and api.nvim_win_get_width(win_id) or vim.o.columns
  local COL_PADDING = 2

  local widths = {}
  for i, h in ipairs(current_set.headers) do
    widths[i] = vim.fn.strdisplaywidth(h)
    for _, row in ipairs(current_set.rows) do  -- use FULL rows for width calc
      local stripped = tostring(row[i] or ''):match('^%s*(.-)%s*$')
      widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(stripped))
    end
    widths[i] = widths[i] + COL_PADDING
  end

  local current_total = 0
  for i = 1, #widths - 1 do current_total = current_total + widths[i] end
  local remaining = win_width - current_total
  if remaining > widths[#widths] then widths[#widths] = remaining end

  local function build_cell(val, width)
    local s = ' ' .. tostring(val or ''):match('^%s*(.-)%s*$')
    local display_w = vim.fn.strdisplaywidth(s)
    local padding   = width - display_w
    if padding < 0 then padding = 0 end
    local full = s .. string.rep(' ', padding)
    return full, #full
  end

  -- Build lines + offsets from filtered rows only
  local row_lines = {}
  state.row_col_offsets = {}
  for _, row in ipairs(filtered) do
    local line, offsets, row_byte_pos = '', {}, 0
    for i, val in ipairs(row) do
      table.insert(offsets, row_byte_pos)
      local full_cell, byte_len = build_cell(val, widths[i])
      line         = line .. full_cell
      row_byte_pos = row_byte_pos + byte_len
    end
    while #offsets < #current_set.headers do
      table.insert(offsets, row_byte_pos)
    end
    table.insert(row_lines, line)
    table.insert(state.row_col_offsets, offsets)
  end

  -- Write: search bar on line 0, filtered rows below
  api.nvim_buf_set_option(r_ovr_buf, 'modifiable', true)
  local all_lines = { header_line }
  for _, l in ipairs(row_lines) do table.insert(all_lines, l) end
  api.nvim_buf_set_lines(r_ovr_buf, 0, -1, false, all_lines)
  api.nvim_buf_set_option(r_ovr_buf, 'modifiable', false)

  -- Update sticky header with same widths
  for id, name in pairs(state.wins) do
    if name == 'r_header' and api.nvim_win_is_valid(id) then
      local hbuf = api.nvim_win_get_buf(id)
      local header_str, byte_pos = '', 0
      state.table_cols = {}
      for i, h in ipairs(current_set.headers) do
        table.insert(state.table_cols, byte_pos)
        local full_cell, byte_len = build_cell(h:upper(), widths[i])
        header_str = header_str .. full_cell
        byte_pos   = byte_pos + byte_len
      end
      api.nvim_buf_set_option(hbuf, 'modifiable', true)
      api.nvim_buf_set_lines(hbuf, 0, -1, false, { header_str })
      api.nvim_buf_set_option(hbuf, 'modifiable', false)
      api.nvim_buf_clear_namespace(hbuf, state.ns, 0, -1)
      api.nvim_buf_add_highlight(hbuf, state.ns, state.hl_header, 0, 0, -1)
    end
  end

  -- Clear highlights
  api.nvim_buf_clear_namespace(r_ovr_buf, M.search_state.ns, 0, -1)
  api.nvim_buf_clear_namespace(r_ovr_buf, state.ns, 0, -1)

  -- Even/odd row highlights on filtered rows (offset +1 for search bar)
  for i = 0, #row_lines - 1 do
    local hl = ((i + 1) % 2 == 0) and state.hl_row_even or state.hl_row_odd
    api.nvim_buf_add_highlight(r_ovr_buf, state.ns, hl, i + 1, 0, -1)
  end

  -- Search bar highlights
  api.nvim_set_hl(0, 'SearchBarHL',   { bg = '#44475A', fg = '#F8F8F2', bold = true })
  api.nvim_set_hl(0, 'SearchQueryHL', { bg = '#44475A', fg = '#50FA7B', bold = true })
  api.nvim_set_hl(0, 'SearchCountHL', { bg = '#44475A', fg = '#FFB86C'             })
  api.nvim_set_hl(0, 'SearchMatchHL', { bg = '#F1FA8C', fg = '#282a36', bold = true })

  api.nvim_buf_add_highlight(r_ovr_buf, M.search_state.ns, 'SearchBarHL',   0, 0, -1)
  api.nvim_buf_add_highlight(r_ovr_buf, M.search_state.ns, 'SearchQueryHL', 0, 0, 2 + #query)
  local count_start = #header_line - #count_str
  api.nvim_buf_add_highlight(r_ovr_buf, M.search_state.ns, 'SearchCountHL', 0, count_start, -1)

  -- Highlight matched cells in filtered rows
  if query ~= '' then
    local q_lower = query:lower()
    for line_idx, row in ipairs(filtered) do
      local offsets = state.row_col_offsets[line_idx]
      for c_idx, val in ipairs(row) do
        if tostring(val or ''):lower():find(q_lower, 1, true) then
          local col_start = offsets[c_idx]
          local col_end   = offsets[c_idx + 1] or -1
          -- line_idx is 1-based filtered row, +1 for search bar line, -1 for 0-based = line_idx
          api.nvim_buf_add_highlight(r_ovr_buf, M.search_state.ns, 'SearchMatchHL',
            line_idx, col_start, col_end)
        end
      end
    end
  end
end

local function search_update(r_ovr_win, r_ovr_buf)
  local current_set = state.result_sets and state.result_sets[state.result_set_index]
  if not current_set then return end

  local query = M.search_state.query
  M.search_state.matches     = {}
  M.search_state.match_count = 0
  M.search_state.filtered_rows = {}

  if query == '' then
    -- Show all rows when query is empty
    M.search_state.filtered_rows = current_set.rows
    M.search_state.match_count   = #current_set.rows
  else
    local q_lower = query:lower()
    for _, row in ipairs(current_set.rows) do
      local matched = false
      for _, val in ipairs(row) do
        if tostring(val or ''):lower():find(q_lower, 1, true) then
          matched = true
          break
        end
      end
      if matched then
        table.insert(M.search_state.filtered_rows, row)
        M.search_state.match_count = M.search_state.match_count + 1
      end
    end
  end

  search_render(r_ovr_win, r_ovr_buf)
end

function M.get_active_rows(current_set)
  if M.search_state.active and M.search_state.filtered_rows and #M.search_state.filtered_rows > 0 then
    return M.search_state.filtered_rows
  else
    return current_set.rows
  end
end

-- Copy Menu (Ctrl+Y)


function M.search_close(r_ovr_win, r_ovr_buf)
  if not M.search_state.active then return end
  M.search_state.active      = false
  M.search_state.query       = ''
  M.search_state.matches     = {}
  M.search_state.match_count = 0
  M.search_state.filtered_rows = {}

  -- Remove all per-char keymaps
  local chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@#$%&*()'
  for i = 1, #chars do
    pcall(vim.keymap.del, 'n', chars:sub(i, i), { buffer = r_ovr_buf })
  end
  pcall(vim.keymap.del, 'n', '<BS>',  { buffer = r_ovr_buf })
  pcall(vim.keymap.del, 'n', '<Esc>', { buffer = r_ovr_buf })

  -- Re-render original full table (this also resets row_col_offsets correctly)
  local current_set = state.result_sets and state.result_sets[state.result_set_index]
  if current_set then
    local results = require('vault.results')
    results.render_results_table(r_ovr_buf, current_set)
  end

  api.nvim_buf_clear_namespace(r_ovr_buf, M.search_state.ns, 0, -1)

  -- Restore ALL original keymaps for r_ovr_buf
  local ui = require('vault.ui')
  vim.keymap.set('n', '<Esc>', ui.close_all_windows, { buffer = r_ovr_buf, silent = true })

  vim.keymap.set('n', 'e', function() ui.switch_to_win 'overlay' end, { buffer = r_ovr_buf })
  vim.keymap.set('n', 'q', function() ui.switch_to_win 'query'   end, { buffer = r_ovr_buf })
  vim.keymap.set('n', 'r', function() ui.switch_to_win 'results' end, { buffer = r_ovr_buf })

  local results = require('vault.results')
  vim.keymap.set('n', '<C-u>', results.edit_cell,        { buffer = r_ovr_buf, desc = 'Edit cell value' })
  vim.keymap.set('n', '<C-x>', results.delete_row,       { buffer = r_ovr_buf, desc = 'Delete row' })
  vim.keymap.set('n', '<C-y>', results.open_copy_menu,   { buffer = r_ovr_buf, desc = 'Open copy menu' })
  --vim.keymap.set('n', '<C-/>', function()
  --  open_search(r_ovr_win, r_ovr_buf)
  --end, { buffer = r_ovr_buf, desc = 'Search results' })

  vim.keymap.set('n', '<Tab>', function()
    if not state.result_sets or #state.result_sets < 2 then return end
    state.result_set_index = (state.result_set_index % #state.result_sets) + 1
    local r_ovr_buf_local = nil
    for id, name in pairs(state.wins) do
      if name == 'r_overlay' then
        r_ovr_buf_local = api.nvim_win_get_buf(id)
        break
      end
    end
    if r_ovr_buf_local then
      local results = require('vault.results')
      results.render_results_table(r_ovr_buf_local, state.result_sets[state.result_set_index])
    end
    local ui = require('vault.ui')
    ui.update_ui_state()
  end, { buffer = r_ovr_buf })

  for _, k in ipairs { 'h', 'l', '<Left>', '<Right>' } do
    vim.keymap.set('n', k, function()
      local results = require('vault.results')
      results.move_cell(k == 'h' or k == '<Left>' and -1 or 1)
    end, { buffer = r_ovr_buf })
  end

  local ui = require('vault.ui')
  ui.update_ui_state()
end

function M.open_search(r_ovr_win, r_ovr_buf)
  if M.search_state.active then
    M.search_close(r_ovr_win, r_ovr_buf)
    return
  end

  M.search_state.active        = true
  M.search_state.query         = ''
  M.search_state.matches       = {}
  M.search_state.match_count   = 0
  M.search_state.filtered_rows = {}

  -- Initial render: show all rows
  local current_set = state.result_sets and state.result_sets[state.result_set_index]
  if current_set then
    M.search_state.filtered_rows = current_set.rows
    M.search_state.match_count   = #current_set.rows
  end

  search_render(r_ovr_win, r_ovr_buf)

  -- place cursor on first data row, first cell
  local first_row = M.search_state.active and 2 or 1  -- 2 because line 0 is search bar
  local first_col = state.row_col_offsets and state.row_col_offsets[1] and state.row_col_offsets[1][1] or 0
  api.nvim_win_set_cursor(r_ovr_win, { first_row, first_col })

  -- Esc: close search, NOT the whole UI
  vim.keymap.set('n', '<Esc>', function()
    M.search_close(r_ovr_win, r_ovr_buf)
  end, { buffer = r_ovr_buf, nowait = true, silent = true })

  -- Backspace
  vim.keymap.set('n', '<BS>', function()
    if #M.search_state.query > 0 then
      M.search_state.query = M.search_state.query:sub(1, -2)
      search_update(r_ovr_win, r_ovr_buf)
    end
  end, { buffer = r_ovr_buf, nowait = true, silent = true })

  -- Character keymaps
  local chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@#$%&*()'
  for i = 1, #chars do
    local ch = chars:sub(i, i)
    vim.keymap.set('n', ch, function()
      M.search_state.query = M.search_state.query .. ch
      search_update(r_ovr_win, r_ovr_buf)
    end, { buffer = r_ovr_buf, nowait = true, silent = true })
  end
end

return M