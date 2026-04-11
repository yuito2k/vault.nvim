local api   = vim.api
--local ui = require('vault.ui')
local filter = require('vault.filter')
local state = require('vault.state').state

local M     = {}

function M.apply_table_highlights(buf, has_header)
  api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
  local line_count = api.nvim_buf_line_count(buf)
  if has_header then
    api.nvim_buf_add_highlight(buf, state.ns, state.hl_header, 0, 0, -1)
  end
  local start = has_header and 1 or 0
  for i = start, line_count - 1 do
    local hl = ((i + 1) % 2 == 0) and state.hl_row_even or state.hl_row_odd
    api.nvim_buf_add_highlight(buf, state.ns, hl, i, 0, -1)
  end
end

function M.render_results_table(buf, data)
  local win_id = vim.fn.bufwinid(buf)
  local win_width = win_id ~= -1 and api.nvim_win_get_width(win_id) or vim.o.columns

  local COL_PADDING = 2

  -- 1. Natural widths using display width
  local widths = {}
  for i, h in ipairs(data.headers) do
    widths[i] = vim.fn.strdisplaywidth(h)
    for _, row in ipairs(data.rows) do
      local stripped = tostring(row[i] or ''):match('^%s*(.-)%s*$')
      widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(stripped))
    end
    widths[i] = widths[i] + COL_PADDING
  end

  -- 2. Stretch last column to fill window
  local current_total = 0
  for i = 1, #widths - 1 do
    current_total = current_total + widths[i]
  end
  local remaining = win_width - current_total
  if remaining > widths[#widths] then
    widths[#widths] = remaining
  end

  -- 3. Cell builder — returns string and its BYTE length
  local function build_cell(val, width)
    local s = ' ' .. tostring(val or ''):match('^%s*(.-)%s*$')
    local display_w = vim.fn.strdisplaywidth(s)
    local padding = width - display_w
    if padding < 0 then padding = 0 end
    local spaces = string.rep(' ', padding)
    local full = s .. spaces
    return full, #full  -- byte length of full cell
  end

  -- 4. Build header + store byte offsets
  local header_str = ''
  state.table_cols = {}      -- byte offsets per column (from header, used for nav)
  local byte_pos = 0
  for i, h in ipairs(data.headers) do
    table.insert(state.table_cols, byte_pos)
    local full_cell, byte_len = build_cell(h:upper(), widths[i])
    header_str = header_str .. full_cell
    byte_pos = byte_pos + byte_len
  end

  -- 5. Build rows + store per-row byte offsets for accurate cell highlighting
  local row_lines = {}
  state.row_col_offsets = {}  -- [row_index] = { col1_byte, col2_byte, ... }
  for r_idx, row in ipairs(data.rows) do
    local line = ''
    local offsets = {}
    local row_byte_pos = 0
    for i, val in ipairs(row) do
      table.insert(offsets, row_byte_pos)
      local full_cell, byte_len = build_cell(val, widths[i])
      line = line .. full_cell
      row_byte_pos = row_byte_pos + byte_len
    end
    -- pad missing columns
    while #offsets < #data.headers do
      table.insert(offsets, row_byte_pos)
    end
    table.insert(row_lines, line)
    table.insert(state.row_col_offsets, offsets)
  end

  -- 6. Write header to r_win buffer, rows to r_ovr_win buffer
  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(buf, 'modifiable', true)
  api.nvim_buf_set_lines(buf, 0, -1, false, row_lines)  -- rows only
  api.nvim_buf_set_option(buf, 'modifiable', false)

  -- Write header to a separate sticky header buffer
  for id, name in pairs(state.wins) do
    if name == 'r_header' and api.nvim_win_is_valid(id) then
      local hbuf = api.nvim_win_get_buf(id)
      api.nvim_buf_set_option(hbuf, 'modifiable', true)
      api.nvim_buf_set_lines(hbuf, 0, -1, false, { header_str })
      api.nvim_buf_set_option(hbuf, 'modifiable', false)
      -- Apply header highlight
      api.nvim_buf_clear_namespace(hbuf, state.ns, 0, -1)
      api.nvim_buf_add_highlight(hbuf, state.ns, state.hl_header, 0, 0, -1)
    end
  end

  if win_id ~= -1 then
    api.nvim_win_set_option(win_id, 'wrap', false)
  end

  -- 7. No wrap on both windows
  for id, name in pairs(state.wins) do
    if name == 'r_overlay' and api.nvim_win_is_valid(id) then
      api.nvim_win_set_option(id, 'wrap', false)
      api.nvim_win_set_option(id, 'scrolloff', 0)
      api.nvim_win_set_option(id, 'sidescrolloff', 0)
      api.nvim_win_set_option(id, 'sidescroll', 1)
    end
    if name == 'results' and api.nvim_win_is_valid(id) then
      api.nvim_win_set_option(id, 'wrap', false)
      api.nvim_win_set_option(id, 'scrolloff', 0)
      api.nvim_win_set_option(id, 'sidescrolloff', 0)
      api.nvim_win_set_option(id, 'sidescroll', 1)
    end
  end

  M.apply_table_highlights(buf)
end

function M.move_cell(dir)
  local win    = api.nvim_get_current_win()
  local cursor = api.nvim_win_get_cursor(win)

  -- offset row index by 1 when search bar is on line 0
  local data_row_idx = filter.search_state.active and (cursor[1] - 1) or cursor[1]
  if data_row_idx < 1 then data_row_idx = 1 end

  local offsets = (state.row_col_offsets and state.row_col_offsets[data_row_idx])
    or state.table_cols
  local col_idx = 1
  for i, offset in ipairs(offsets) do
    if cursor[2] >= offset then col_idx = i end
  end

  local next_idx = math.max(1, math.min(#offsets, col_idx + dir))
  api.nvim_win_set_cursor(win, { cursor[1], offsets[next_idx] })

  vim.api.nvim_win_call(win, function()
    local view     = vim.fn.winsaveview()
    local win_width = api.nvim_win_get_width(win)
    local cursor_col = offsets[next_idx]
    local cell_end
    if offsets[next_idx + 1] then
      cell_end = offsets[next_idx + 1]
    else
      local line = api.nvim_buf_get_lines(
        api.nvim_win_get_buf(win), cursor[1] - 1, cursor[1], false)[1] or ''
      cell_end = #line
    end
    local leftcol = view.leftcol
    if dir > 0 then
      if cell_end > leftcol + win_width then
        view.leftcol = cell_end - win_width
        vim.fn.winrestview(view)
      end
    else
      if cursor_col < leftcol then
        view.leftcol = cursor_col
        vim.fn.winrestview(view)
      end
    end
  end)

  local ui = require('vault.ui')
  ui.update_ui_state()
end

-- ■■■ Inline Cell Edit (Ctrl+U) ■■■
local function get_pk_info(table_name)
  local pk_col, pk_cid = nil, -1
  pcall(function()
    local pragma = require('sqlite.db').with_open(state.db_path, function(conn)
      return conn:eval('PRAGMA table_info(' .. table_name .. ')')
    end)
    if type(pragma) == 'table' then
      for _, col in ipairs(pragma) do
        if col.pk and col.pk > 0 then
          if col.pk > pk_cid then -- handles composite PKs, takes first
            pk_col = col.name
            pk_cid = col.pk
          end
        end
      end
    end
  end)
  return pk_col
end

function M.edit_cell()
  local r_ovr_win = nil
  local last_sql = nil

  for id, name in pairs(state.wins) do
    if name == 'r_overlay' then r_ovr_win = id end
    if name == 'q_overlay' then
      local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(id), 0, -1, false)
      last_sql = table.concat(lines, ' '):match('^%s*(.-)%s*$')
    end
  end

  if not r_ovr_win or not api.nvim_win_is_valid(r_ovr_win) then return end
  if api.nvim_get_current_win() ~= r_ovr_win then return end

  local table_name = last_sql and last_sql:match('[Ff][Rr][Oo][Mm]%s+["\']?(%w+)["\']?')
  if not table_name then
    state.last_query_status = 'Cannot determine source table'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  local cursor  = api.nvim_win_get_cursor(r_ovr_win)
  local row_idx = cursor[1]
  local col_idx = 1
  local offsets = (state.row_col_offsets and state.row_col_offsets[row_idx]) or state.table_cols
  for i, offset in ipairs(offsets) do
    if cursor[2] >= offset then col_idx = i end
  end

  local current_set = state.result_sets and state.result_sets[state.result_set_index]
  if not current_set then return end

  local col_name   = current_set.headers[col_idx]
  local cell_value = current_set.rows[row_idx] and current_set.rows[row_idx][col_idx] or ''

  -- Get PK info
  local pk_col = get_pk_info(table_name)

  if col_name == pk_col then
    state.last_query_status = 'Cannot edit primary key column'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  if not pk_col then
    state.last_query_status = 'No primary key found on ' .. table_name
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  local pk_col_idx = nil
  for i, h in ipairs(current_set.headers) do
    if h == pk_col then pk_col_idx = i; break end
  end

  if not pk_col_idx then
    state.last_query_status = 'PK column not in result — SELECT ' .. pk_col .. ' to edit'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  local pk_value = current_set.rows[row_idx][pk_col_idx]

  -- Write UPDATE into query buffer and switch focus to it
  local update_sql = string.format(
    "UPDATE %s SET %s = '%s' WHERE %s = %s;",
    table_name,
    col_name,
    cell_value == 'NULL' and '' or cell_value:gsub("'", "''"),
    pk_col,
    pk_value
  )

  for id, name in pairs(state.wins) do
    if name == 'q_overlay' then
      local qbuf = api.nvim_win_get_buf(id)
      --api.nvim_buf_set_option(qbuf, 'modifiable', true)
      api.nvim_buf_set_lines(qbuf, 0, -1, false, { update_sql })
      --api.nvim_buf_set_option(qbuf, 'modifiable', false)
      break
    end
  end

  -- Switch focus to query window so user can edit the value then hit Enter
  local ui = require('vault.ui')
  ui.switch_to_win 'q_overlay'
  -- Place cursor right before the closing quote of the value
  -- so the user can immediately edit it
  local q_ovr_win = nil
  for id, name in pairs(state.wins) do
    if name == 'q_overlay' then q_ovr_win = id; break end
  end
  if q_ovr_win then
    -- find the position of the value between the quotes
    local quote_pos = update_sql:find("= '") + 3  -- land right after opening quote
    api.nvim_win_set_cursor(q_ovr_win, { 1, quote_pos - 1 })
    --vim.cmd 'startinsert!'
  end
end

function M.delete_row()
  local r_ovr_win = nil
  local last_sql = nil

  for id, name in pairs(state.wins) do
    if name == 'r_overlay' then r_ovr_win = id end
    if name == 'q_overlay' then
      local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(id), 0, -1, false)
      last_sql = table.concat(lines, ' '):match('^%s*(.-)%s*$')
    end
  end

  if not r_ovr_win or not api.nvim_win_is_valid(r_ovr_win) then return end
  if api.nvim_get_current_win() ~= r_ovr_win then return end

  local table_name = last_sql and last_sql:match('[Ff][Rr][Oo][Mm]%s+["\']?(%w+)["\']?')
  if not table_name then
    state.last_query_status = 'Cannot determine source table'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  local cursor  = api.nvim_win_get_cursor(r_ovr_win)
  local row_idx = cursor[1]

  local current_set = state.result_sets and state.result_sets[state.result_set_index]
  if not current_set then return end

  -- Get PK info
  local pk_col = get_pk_info(table_name)

  if not pk_col then
    state.last_query_status = 'No primary key found on ' .. table_name
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  local pk_col_idx = nil
  for i, h in ipairs(current_set.headers) do
    if h == pk_col then pk_col_idx = i; break end
  end

  if not pk_col_idx then
    state.last_query_status = 'PK column not in result — SELECT ' .. pk_col .. ' to delete'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  local pk_value = current_set.rows[row_idx][pk_col_idx]

  -- Build DELETE query
  local delete_sql = string.format(
    "DELETE FROM %s WHERE %s = %s;",
    table_name,
    pk_col,
    pk_value
  )

  -- Write into query buffer
  for id, name in pairs(state.wins) do
    if name == 'q_overlay' then
      local qbuf = api.nvim_win_get_buf(id)
      --api.nvim_buf_set_option(qbuf, 'modifiable', true)
      api.nvim_buf_set_lines(qbuf, 0, -1, false, { delete_sql })
      --api.nvim_buf_set_option(qbuf, 'modifiable', false)
      break
    end
  end

  -- Switch to query window with cursor on the query, normal mode
  local ui = require('vault.ui')
  ui.switch_to_win 'q_overlay'
  local q_ovr_win = nil
  for id, name in pairs(state.wins) do
    if name == 'q_overlay' then q_ovr_win = id; break end
  end
  if q_ovr_win then
    api.nvim_win_set_cursor(q_ovr_win, { 1, 0 })
  end
end

local function restore_esc(r_ovr_buf, r_ovr_win)
  if filter.search_state.active then
    vim.keymap.set('n', '<Esc>', function()
      search_close(r_ovr_win, r_ovr_buf)
    end, { buffer = r_ovr_buf, nowait = true, silent = true })
  else
    vim.keymap.set('n', '<Esc>', ui.close_all_windows, { buffer = r_ovr_buf, silent = true })
  end
end

-- ■■■ Export Submenu ■■■
local export_menu_win = nil
local export_menu_buf = nil

local function close_export_menu()
  if export_menu_win and api.nvim_win_is_valid(export_menu_win) then
    api.nvim_win_close(export_menu_win, true)
  end
  if export_menu_buf and api.nvim_buf_is_valid(export_menu_buf) then
    api.nvim_buf_delete(export_menu_buf, { force = true })
  end
  export_menu_win = nil
  export_menu_buf = nil
end

local function open_export_menu(r_ovr_win)
  close_export_menu()

  export_menu_buf = api.nvim_create_buf(false, true)
  local menu_lines = {
    ' Export',
    '   c  Export as CSV',
    '   j  Export as JSON',
    '',
  }
  api.nvim_buf_set_lines(export_menu_buf, 0, -1, false, menu_lines)
  api.nvim_buf_set_option(export_menu_buf, 'modifiable', false)

  local win_width  = api.nvim_win_get_width(r_ovr_win)
  local win_height = api.nvim_win_get_height(r_ovr_win)
  local menu_w, menu_h = 32, #menu_lines

  export_menu_win = api.nvim_open_win(export_menu_buf, false, {
    relative   = 'win',
    win        = r_ovr_win,
    row        = win_height - menu_h - 1,
    col        = win_width - menu_w - 1,
    width      = menu_w,
    height     = menu_h,
    style      = 'minimal',
    border     = 'rounded',
    focusable  = false,
    zindex     = 300,
    footer     = ' Close: <esc> ',
    footer_pos = 'right',
  })

  api.nvim_set_hl(0, 'ExportMenuBorder', { fg = '#BD93F9' })
  api.nvim_win_set_option(export_menu_win, 'winhl', 'Normal:Normal,FloatBorder:ExportMenuBorder')

  local ns = api.nvim_create_namespace('ExportMenuHL')
  api.nvim_buf_add_highlight(export_menu_buf, ns, 'CopyMenuHeader', 0, 0, -1)
  api.nvim_buf_add_highlight(export_menu_buf, ns, 'CopyMenuKey',    1, 3, 4)
  api.nvim_buf_add_highlight(export_menu_buf, ns, 'CopyMenuLabel',  1, 5, -1)
  api.nvim_buf_add_highlight(export_menu_buf, ns, 'CopyMenuKey',    2, 3, 4)
  api.nvim_buf_add_highlight(export_menu_buf, ns, 'CopyMenuLabel',  2, 5, -1)
  api.nvim_buf_add_highlight(export_menu_buf, ns, 'CopyMenuFooter', #menu_lines - 1, 0, -1)

  local r_ovr_buf = api.nvim_win_get_buf(r_ovr_win)

  local function cleanup()
    close_export_menu()
    pcall(vim.keymap.del, 'n', 'c', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'j', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<Esc>', { buffer = r_ovr_buf })
    restore_esc(r_ovr_buf, r_ovr_win)
  end

  local function do_export(format)
    local current_set = state.result_sets and state.result_sets[state.result_set_index]
    if not current_set then return end
    local active_rows = filter.get_active_rows(current_set)  -- ← use this instead of current_set.rows

    cleanup()

    require('telescope').extensions.file_browser.file_browser {
      cwd             = vim.fn.expand '$HOME',
      prompt_title    = 'Select Export Folder',
      hijack_netrw    = false,
      attach_mappings = function(prompt_bufnr, _)
        vim.schedule(function()
          local picker = require('telescope.actions.state').get_current_picker(prompt_bufnr)
          for _, win_key in ipairs { 'prompt_win', 'results_win', 'preview_win' } do
            if picker[win_key] and vim.api.nvim_win_is_valid(picker[win_key]) then
              vim.api.nvim_win_set_config(picker[win_key], { border = 'rounded', zindex = 400 })
            end
          end
        end)

        local actions      = require 'telescope.actions'
        local action_state = require 'telescope.actions.state'

        actions.select_default:replace(function()
          local entry    = action_state.get_selected_entry()
          actions.close(prompt_bufnr)

          -- Resolve folder path
          local folder = entry and (entry.path or entry.filename) or vim.fn.expand '$HOME'
          if vim.fn.isdirectory(folder) == 0 then
            folder = vim.fn.fnamemodify(folder, ':h')
          end

          -- Build filename from table name + timestamp
          local last_sql = ''
          for id, name in pairs(state.wins) do
            if name == 'q_overlay' then
              local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(id), 0, -1, false)
              last_sql = table.concat(lines, ' ')
              break
            end
          end
          local table_name = last_sql:match('[Ff][Rr][Oo][Mm]%s+["\']?(%w+)["\']?') or 'export'
          local timestamp  = os.date('%Y%m%d_%H%M%S')
          local filename   = folder .. '/' .. table_name .. '_' .. timestamp .. '.' .. format

          if format == 'csv' then
            -- Write CSV
            local f = io.open(filename, 'w')
            if not f then
              state.last_query_status = 'Error: Cannot write to ' .. folder
              ui.update_ui_state()
              return
            end
            -- Header row
            f:write(table.concat(current_set.headers, ',') .. '\n')
            -- Data rows
            for _, row in ipairs(active_rows.rows) do
              local escaped = {}
              for _, val in ipairs(row) do
                -- Wrap in quotes if contains comma, quote or newline
                local v = tostring(val or '')
                if v:find('[,"\n]') then
                  v = '"' .. v:gsub('"', '""') .. '"'
                end
                table.insert(escaped, v)
              end
              f:write(table.concat(escaped, ',') .. '\n')
            end
            f:close()

          elseif format == 'json' then
            local f = io.open(filename, 'w')
            if not f then
              state.last_query_status = 'Error: Cannot write to ' .. folder
              ui.update_ui_state()
              return
            end
          
            local out = {}
            table.insert(out, '[')
            for i, row in ipairs(active_rows.rows) do
              table.insert(out, '  {')
              for j, h in ipairs(current_set.headers) do
                local val = tostring(row[j] or '')
                local is_num = tonumber(val) ~= nil
                local formatted_val
                if is_num then
                  formatted_val = val
                else
                  val = val:gsub('\\', '\\\\'):gsub('"', '\\"')
                  formatted_val = '"' .. val .. '"'
                end
                local comma = (j < #current_set.headers) and ',' or ''
                table.insert(out, '    "' .. h .. '": ' .. formatted_val .. comma)
              end
              local obj_close = (i < #active_rows.rows) and '  },' or '  }'
              table.insert(out, obj_close)
            end
            table.insert(out, ']')
          
            f:write(table.concat(out, '\n'))
            f:write('\n')
            f:close()
          end

          state.last_query_status = 'Exported ' .. #current_set.rows .. ' rows → ' .. filename
          ui.update_ui_state()
        end)
        return true
      end,
    }
  end

  local bopts = { buffer = r_ovr_buf, nowait = true, silent = true }

  vim.keymap.set('n', 'c', function() do_export('csv')  end, bopts)
  vim.keymap.set('n', 'j', function() do_export('json') end, bopts)
  vim.keymap.set('n', '<Esc>', function() cleanup() end, bopts)
end

-- ■■■ Copy Menu (Ctrl+Y) ■■■
local copy_menu_win = nil
local copy_menu_buf = nil

function M.close_copy_menu()
  if copy_menu_win and api.nvim_win_is_valid(copy_menu_win) then
    api.nvim_win_close(copy_menu_win, true)
  end
  if copy_menu_buf and api.nvim_buf_is_valid(copy_menu_buf) then
    api.nvim_buf_delete(copy_menu_buf, { force = true })
  end
  copy_menu_win = nil
  copy_menu_buf = nil
end

local function flash_highlight(buf, start_row, end_row, hl_group, duration_ms)
  local ns = api.nvim_create_namespace('FlashHL')
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i = start_row, end_row do
    api.nvim_buf_add_highlight(buf, ns, hl_group, i, 0, -1)
  end
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end, duration_ms)
end

local function flash_cell(buf, row, col_start, col_end, hl_group, duration_ms)
  local ns = api.nvim_create_namespace('FlashCellHL')
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  api.nvim_buf_add_highlight(buf, ns, hl_group, row, col_start, col_end)
  vim.defer_fn(function()
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end, duration_ms)
end

function M.open_copy_menu()
  local r_ovr_win = nil
  for id, name in pairs(state.wins) do
    if name == 'r_overlay' then r_ovr_win = id; break end
  end
  if not r_ovr_win or api.nvim_get_current_win() ~= r_ovr_win then return end

  -- Close if already open
  if copy_menu_win and api.nvim_win_is_valid(copy_menu_win) then
    close_copy_menu()
    return
  end

  copy_menu_buf = api.nvim_create_buf(false, true)
  local menu_lines = {
    ' Copy',
    '   c  Copy cell',
    '   y  Copy row',
    '   a  Copy all',
    '',
    ' Export',
    '   ^e  Export...',
    '',
  }
  api.nvim_buf_set_lines(copy_menu_buf, 0, -1, false, menu_lines)
  api.nvim_buf_set_option(copy_menu_buf, 'modifiable', false)

  -- Position near bottom-right of results window
  local win_width  = api.nvim_win_get_width(r_ovr_win)
  local win_height = api.nvim_win_get_height(r_ovr_win)
  local menu_w, menu_h = 32, #menu_lines

  copy_menu_win = api.nvim_open_win(copy_menu_buf, false, {
    relative  = 'win',
    win       = r_ovr_win,
    row       = win_height - menu_h - 1,
    col       = win_width - menu_w - 1,
    width     = menu_w,
    height    = menu_h,
    style     = 'minimal',
    border    = 'rounded',
    focusable = false,
    zindex    = 300,
    footer    = ' Close: <esc> ',
    footer_pos = 'right',
  })

  -- Highlights
  api.nvim_set_hl(0, 'CopyMenuBorder',  { fg = '#6272A4' })
  api.nvim_set_hl(0, 'CopyMenuHeader',  { fg = '#F8F8F2', bold = true })
  api.nvim_set_hl(0, 'CopyMenuKey',     { fg = '#FFB86C', bold = true })
  api.nvim_set_hl(0, 'CopyMenuLabel',   { fg = '#8BE9FD' })
  api.nvim_set_hl(0, 'CopyMenuFooter',  { fg = '#6272A4', italic = true })
  api.nvim_set_hl(0, 'FlashRow',        { bg = '#50FA7B', fg = '#282a36', bold = true })
  api.nvim_set_hl(0, 'FlashCell',       { bg = '#FFB86C', fg = '#282a36', bold = true })

  api.nvim_win_set_option(copy_menu_win, 'winhl', 'Normal:Normal,FloatBorder:CopyMenuBorder')

  local ns = api.nvim_create_namespace('CopyMenuHL')
  -- Section headers
  api.nvim_buf_add_highlight(copy_menu_buf, ns, 'CopyMenuHeader', 0, 0, -1)
  api.nvim_buf_add_highlight(copy_menu_buf, ns, 'CopyMenuHeader', 5, 0, -1)
  -- Keys
  for _, line_idx in ipairs({ 1, 2, 3, 6 }) do
    api.nvim_buf_add_highlight(copy_menu_buf, ns, 'CopyMenuKey',   line_idx, 3, 4)
    api.nvim_buf_add_highlight(copy_menu_buf, ns, 'CopyMenuLabel', line_idx, 5, -1)
  end
  api.nvim_buf_add_highlight(copy_menu_buf, ns, 'CopyMenuFooter', #menu_lines - 1, 0, -1)

  -- Keymaps on r_ovr_buf while menu is open
  local r_ovr_buf = api.nvim_win_get_buf(r_ovr_win)
  local bopts = { buffer = r_ovr_buf, nowait = true, silent = true }

  -- c: Copy cell
  vim.keymap.set('n', 'c', function()
    local current_set = state.result_sets and state.result_sets[state.result_set_index]
    if not current_set then return end
    local cursor  = api.nvim_win_get_cursor(r_ovr_win)
    local row_idx = filter.search_state.active and (cursor[1] - 1) or cursor[1]
    if row_idx < 1 then row_idx = 1 end
    local col_idx = 1
    local offsets = (state.row_col_offsets and state.row_col_offsets[row_idx]) or state.table_cols
    for i, offset in ipairs(offsets) do
      if cursor[2] >= offset then col_idx = i end
    end
    local active_rows = filter.get_active_rows(current_set)
    local cell_value  = active_rows[row_idx] and active_rows[row_idx][col_idx] or ''
    vim.fn.setreg('+', cell_value)
    vim.fn.setreg('"', cell_value)
    local col_start = offsets[col_idx]
    local col_end   = offsets[col_idx + 1] or -1
    flash_cell(r_ovr_buf, cursor[1] - 1, col_start, col_end, 'FlashCell', 300)
    state.last_query_status = 'Copied cell: ' .. cell_value

    close_copy_menu()
    -- Remove temporary keymaps
    pcall(vim.keymap.del, 'n', 'c', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'y', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'a', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<C-e>', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<Esc>', { buffer = r_ovr_buf })
    restore_esc(r_ovr_buf, r_ovr_win)
    ui.update_ui_state()
  end, bopts)

  -- y: Copy row
  vim.keymap.set('n', 'y', function()
    local current_set = state.result_sets and state.result_sets[state.result_set_index]
    if not current_set then return end
    local cursor  = api.nvim_win_get_cursor(r_ovr_win)
    local row_idx = filter.search_state.active and (cursor[1] - 1) or cursor[1]
    if row_idx < 1 then row_idx = 1 end
    local active_rows = filter.get_active_rows(current_set)
    local row         = active_rows[row_idx]
    if not row then return end
    local row_str = table.concat(row, '\t')
    vim.fn.setreg('+', row_str)
    vim.fn.setreg('"', row_str)
    flash_highlight(r_ovr_buf, cursor[1] - 1, cursor[1] - 1, 'FlashRow', 300)
    state.last_query_status = 'Copied row ' .. row_idx

    close_copy_menu()
    pcall(vim.keymap.del, 'n', 'c', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'y', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'a', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<C-e>', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<Esc>', { buffer = r_ovr_buf })
    restore_esc(r_ovr_buf, r_ovr_win)
    ui.update_ui_state()
  end, bopts)

  -- a: Copy all
  vim.keymap.set('n', 'a', function()
    local current_set = state.result_sets and state.result_sets[state.result_set_index]
    if not current_set then return end
    local active_rows = filter.get_active_rows(current_set)
    local lines = { table.concat(current_set.headers, '\t') }
    for _, row in ipairs(active_rows) do
      table.insert(lines, table.concat(row, '\t'))
    end
    local all_str = table.concat(lines, '\n')
    vim.fn.setreg('+', all_str)
    vim.fn.setreg('"', all_str)
    local row_count = filter.search_state.active and 1 or 0
    flash_highlight(r_ovr_buf, row_count, row_count + #active_rows - 1, 'FlashRow', 300)
    state.last_query_status = 'Copied ' .. #active_rows .. ' rows'

    close_copy_menu()
    pcall(vim.keymap.del, 'n', 'c', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'y', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'a', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<C-e>', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<Esc>', { buffer = r_ovr_buf })
    restore_esc(r_ovr_buf, r_ovr_win)
    ui.update_ui_state()
  end, bopts)

  -- e: Export (placeholder)
  vim.keymap.set('n', '<C-e>', function()
    state.last_query_status = 'Export coming soon...'
    close_copy_menu()
    pcall(vim.keymap.del, 'n', 'c', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'y', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'a', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<C-e>', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<Esc>', { buffer = r_ovr_buf })
    restore_esc(r_ovr_buf, r_ovr_win)
    open_export_menu(r_ovr_win)
  end, bopts)

  -- Esc: close menu
  vim.keymap.set('n', '<Esc>', function()
    close_copy_menu()
    pcall(vim.keymap.del, 'n', 'c', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'y', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', 'a', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<C-e>', { buffer = r_ovr_buf })
    pcall(vim.keymap.del, 'n', '<Esc>', { buffer = r_ovr_buf })
    restore_esc(r_ovr_buf, r_ovr_win)
  end, bopts)
end

return M