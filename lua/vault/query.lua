local api   = vim.api
local state = require('vault.state').state
local results = require('vault.results')

local M     = {}

local sql_keywords = {
  'SELECT',
  'FROM',
  'WHERE',
  'INSERT',
  'INTO',
  'UPDATE',
  'DELETE',
  'CREATE',
  'TABLE',
  'DROP',
  'ALTER',
  'JOIN',
  'LEFT',
  'RIGHT',
  'GROUP',
  'BY',
  'ORDER',
  'LIMIT',
  'HAVING',
}

-- 2. Autocomplete Engine Logic
local suggest_state = {
  win = nil,
  buf = nil,
  items = {},       -- filtered keyword list
  selected = 1,     -- 1-based index of highlighted item
}

function M.suggest_is_open()
  return suggest_state.win ~= nil
    and api.nvim_win_is_valid(suggest_state.win)
end

function M.suggest_close()
  if M.suggest_is_open() then
    api.nvim_win_close(suggest_state.win, true)
  end
  -- also wipe the buffer to avoid ghost content on re-open
  if suggest_state.buf ~= nil and api.nvim_buf_is_valid(suggest_state.buf) then
    api.nvim_buf_delete(suggest_state.buf, { force = true })
  end
  suggest_state.win      = nil
  suggest_state.buf      = nil
  suggest_state.items    = {}
  suggest_state.selected = 1
end

-- highlight the currently selected row inside the suggestion window
local function suggest_refresh_highlight()
  if not M.suggest_is_open() then return end
  local ns = api.nvim_create_namespace 'SuggestHL'
  api.nvim_buf_clear_namespace(suggest_state.buf, ns, 0, -1)
  -- selected is 1-based, nvim highlight is 0-based
  api.nvim_buf_add_highlight(
    suggest_state.buf, ns, 'PmenuSel',
    suggest_state.selected - 1, 0, -1
  )
end

-- move selection up/down, wraps around
function M.suggest_move(dir)
  if not M.suggest_is_open() then return end
  local count = #suggest_state.items
  suggest_state.selected = ((suggest_state.selected - 1 + dir) % count) + 1
  suggest_refresh_highlight()
end

-- open or reuse the floating window and populate it
local function suggest_open_or_update(q_ovr_win)
  local items  = suggest_state.items
  local height = math.min(#items, 8)
  local width  = 24

  -- derive position from cursor
  local cursor_screen = api.nvim_win_get_cursor(q_ovr_win)
  -- place window just below the current line, at column 0
  local win_row = cursor_screen[1]   -- 1-based line → used as 0-based row offset below cursor
  local win_col = cursor_screen[2]

  if not M.suggest_is_open() then
    suggest_state.buf = api.nvim_create_buf(false, true)
    suggest_state.win = api.nvim_open_win(suggest_state.buf, false, {
      relative  = 'win',
      win       = q_ovr_win,
      row       = win_row,      -- appears one line below cursor
      col       = win_col,
      width     = width,
      height    = height,
      style     = 'minimal',
      border    = 'rounded',
      focusable = false,
      zindex    = 200,
    })
    -- style: match Dracula palette used elsewhere in the plugin
    api.nvim_set_hl(0, 'SuggestNormal', { bg = '#282a36', fg = '#f8f8f2' })
    api.nvim_win_set_option(suggest_state.win, 'winhl', 'Normal:SuggestNormal,FloatBorder:FloatBorderInactive')
  else
    -- just resize/reposition in place
    api.nvim_win_set_config(suggest_state.win, {
      relative = 'win',
      win      = q_ovr_win,
      row      = win_row,
      col      = win_col,
      width    = width,
      height   = height,
    })
  end

  api.nvim_buf_set_option(suggest_state.buf, 'modifiable', true)
  api.nvim_buf_set_lines(suggest_state.buf, 0, -1, false, items)
  api.nvim_buf_set_option(suggest_state.buf, 'modifiable', false)

  suggest_refresh_highlight()
end

-- called from TextChangedI — computes matches and shows/hides the window
function M.suggest_update(q_ovr_win)
  if not api.nvim_win_is_valid(q_ovr_win) then
    M.suggest_close()
    return
  end

  local cursor = api.nvim_win_get_cursor(q_ovr_win)
  local line   = api.nvim_get_current_line()
  -- grab the word fragment immediately before the cursor
  local before       = line:sub(1, cursor[2])
  local word_fragment = before:match '[%a_][%w_]*$'  -- must start with a letter

  if not word_fragment or #word_fragment < 1 then
    M.suggest_close()
    return
  end

  -- filter keywords: case-insensitive prefix match
  local fragment_upper = word_fragment:upper()
  local matched = {}
  for _, kw in ipairs(sql_keywords) do
    -- vim.startswith is not available in all nvim versions, use plain find
    if kw:sub(1, #fragment_upper) == fragment_upper then
      table.insert(matched, kw)
    end
  end

  if #matched == 0 then
    M.suggest_close()
    return
  end

  -- reset selection only when the item list actually changed
  local list_changed = (#matched ~= #suggest_state.items)
  if not list_changed then
    for i, v in ipairs(matched) do
      if v ~= suggest_state.items[i] then
        list_changed = true
        break
      end
    end
  end

  suggest_state.items = matched
  if list_changed then
    suggest_state.selected = 1
  end

  suggest_open_or_update(q_ovr_win)
end

-- confirm: replaces the current word fragment with the selected suggestion
function M.suggest_confirm(q_ovr_win)
  if not M.suggest_is_open() or #suggest_state.items == 0 then
    return false   -- caller can decide to insert a real Tab
  end

  local word   = suggest_state.items[suggest_state.selected]
  local cursor = api.nvim_win_get_cursor(q_ovr_win)
  local line   = api.nvim_get_current_line()

  -- replace only the trailing word fragment, keep everything else
  local before_fragment = line:sub(1, cursor[2]):gsub('[%a_][%w_]*$', '')
  local after_cursor    = line:sub(cursor[2] + 1)

  api.nvim_set_current_line(before_fragment .. word .. after_cursor)
  api.nvim_win_set_cursor(q_ovr_win, { cursor[1], #before_fragment + #word })

  M.suggest_close()
  return true
end

function M.execute_query()
  local q_ovr_win = nil
  local r_ovr_buf = nil
  for id, name in pairs(state.wins) do
    if name == 'q_overlay' then q_ovr_win = id end
    if name == 'r_overlay' then r_ovr_buf = api.nvim_win_get_buf(id) end
  end
  if not q_ovr_win or not r_ovr_buf then return end

  local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(q_ovr_win), 0, -1, false)
  local full_text = table.concat(lines, ' ')

  -- Split on semicolons, filter blank statements
  local statements = {}
  for stmt in full_text:gmatch('[^;]+') do
    local trimmed = stmt:match('^%s*(.-)%s*$')
    if trimmed ~= '' then
      table.insert(statements, trimmed)
    end
  end

  if #statements == 0 then
    results.render_results_table(r_ovr_buf, { headers = { 'Error' }, rows = { { 'No query entered' } } })
    return
  end

  -- NEW: store multiple result sets
  state.result_sets = {}
  state.result_set_index = 1

  local total_start = os.clock()
  local total_rows = 0
  local had_error = false

  for _, sql in ipairs(statements) do
    local elapsed_ms = nil
    local success, result = pcall(function()
      return require('sqlite.db').with_open(state.db_path, function(conn)
        local t0 = os.clock()
        local r = conn:eval(sql)
        elapsed_ms = (os.clock() - t0) * 1000
        return r
      end)
    end)

    if not success then
      local err_msg = tostring(result)
      local clean_err = err_msg:match('[Ee]rr[or]*:%s*(.+)$') or err_msg
      table.insert(state.result_sets, { headers = { 'Error' }, rows = { { clean_err } } })
      had_error = true

    elseif type(result) == 'table' and #result > 0 then
      local headers = {}
      for k in pairs(result[1]) do table.insert(headers, k) end

      -- PRAGMA for column order — isolated, cannot affect result
      local col_order = {}
      local table_name = sql:match('[Ff][Rr][Oo][Mm]%s+["\']?(%w+)["\']?')
      if table_name then
        local ok, pragma = pcall(function()
          return require('sqlite.db').with_open(state.db_path, function(conn)
            return conn:eval('PRAGMA table_info(' .. table_name .. ')')
          end)
        end)
        if ok and type(pragma) == 'table' then
          for _, col in ipairs(pragma) do
            col_order[col.name] = col.cid
          end
        end
      end

      if next(col_order) then
        table.sort(headers, function(a, b)
          return (col_order[a] or 999) < (col_order[b] or 999)
        end)
      else
        table.sort(headers)
      end

      -- rows building unchanged
      local rows = {}
      for _, row_data in ipairs(result) do
        local row = {}
        for _, h in ipairs(headers) do
          table.insert(row, tostring(row_data[h] or 'NULL'))
        end
        table.insert(rows, row)
      end
      total_rows = total_rows + #rows
      table.insert(state.result_sets, { headers = headers, rows = rows })
    elseif type(result) == 'table' and #result == 0 then
      -- SELECT returned zero rows — still show the column headers if possible
      -- Re-run with a LIMIT 0 trick to get column names
      local headers = {}
      pcall(function()
        local col_result = require('sqlite.db').with_open(state.db_path, function(conn)
          return conn:eval(sql .. ' LIMIT 0')
        end)
        if type(col_result) == 'table' then
          for k in pairs(col_result) do table.insert(headers, k) end
          table.sort(headers)
        end
      end)
      if #headers == 0 then headers = { 'Result' } end
      table.insert(state.result_sets, { headers = headers, rows = {} })
    else
      -- result == true means a non-SELECT DML (INSERT/UPDATE/DELETE)
      table.insert(state.result_sets, { headers = { 'Status' }, rows = { { 'Success' } } })
    end
  end

  local total_ms = (os.clock() - total_start) * 1000

  -- Render the first result set immediately
  results.render_results_table(r_ovr_buf, state.result_sets[1])

  -- Build status: "Executed N statements in X ms"
  local stmt_word = #statements == 1 and '1 statement' or (#statements .. ' statements')
  state.last_query_status = string.format(
    'Executed %s in %.2fms', stmt_word, total_ms
  )

  local ui = require('vault.ui')
  ui.update_ui_state()
end

return M