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

  -- Save to history
  if state.is_connected and state.db_id then
    local hist_db = require('sqlite.db'):open(state.sys_db)
    for _, sql in ipairs(statements) do
      local trimmed = sql:match('^%s*(.-)%s*$')
      if trimmed ~= '' then
        -- avoid duplicate consecutive entries
        local last = hist_db:eval(
          string.format("SELECT query FROM query_history WHERE db_id='%s' ORDER BY created_at DESC LIMIT 1;",
            state.db_id:gsub("'","''")))
        local last_query = (type(last) == 'table' and last[1]) and last[1].query or ''
        local con = require('vault.connection')
        if last_query ~= trimmed then
          hist_db:eval(string.format(
            "INSERT INTO query_history (id, db_id, query) VALUES ('%s', '%s', '%s');",
            con.generate_id(),
            state.db_id:gsub("'","''"),
            trimmed:gsub("'","''")
          ))
        end
      end
    end
    hist_db:close()
  end

  local ui = require('vault.ui')
  ui.update_ui_state()
end

-- ■■■ Query History (Backspace in normal mode on q_ovr_buf) ■■■
local hist_state = {
  win       = nil,
  buf       = nil,
  records   = {},   -- { id, query, starred }
  cursor    = 1,
  ns        = vim.api.nvim_create_namespace('HistoryHL'),
}

local function hist_close(q_ovr_win, q_ovr_buf)
  if hist_state.win and vim.api.nvim_win_is_valid(hist_state.win) then
    vim.api.nvim_win_close(hist_state.win, true)
  end
  if hist_state.buf and vim.api.nvim_buf_is_valid(hist_state.buf) then
    vim.api.nvim_buf_delete(hist_state.buf, { force = true })
  end
  hist_state.win     = nil
  hist_state.buf     = nil
  hist_state.records = {}
  hist_state.cursor  = 1
end

local function hist_render()
  if not hist_state.buf or not vim.api.nvim_buf_is_valid(hist_state.buf) then return end

  local lines = {}
  for _, rec in ipairs(hist_state.records) do
    local prefix = rec.starred == 1 and ' ★ ' or '   '
    table.insert(lines, prefix .. rec.query)
  end

  if #lines == 0 then
    lines = { '  (no history yet)' }
  end

  vim.api.nvim_buf_set_option(hist_state.buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(hist_state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(hist_state.buf, 'modifiable', false)

  -- Clear highlights
  vim.api.nvim_buf_clear_namespace(hist_state.buf, hist_state.ns, 0, -1)

  -- Highlights
  vim.api.nvim_set_hl(0, 'HistCursorLine', { bg = '#292e42', bold = true })
  vim.api.nvim_set_hl(0, 'HistStarred',    { fg = '#F1FA8C', bold = true })
  vim.api.nvim_set_hl(0, 'HistQuery',      { fg = '#BD93F9' })
  vim.api.nvim_set_hl(0, 'HistEmpty',      { fg = '#6272A4', italic = true })

  for i, rec in ipairs(hist_state.records) do
    local line_idx = i - 1
    if i == hist_state.cursor then
      vim.api.nvim_buf_add_highlight(hist_state.buf, hist_state.ns, 'HistCursorLine', line_idx, 0, -1)
    else
      if rec.starred == 1 then
        vim.api.nvim_buf_add_highlight(hist_state.buf, hist_state.ns, 'HistStarred', line_idx, 0, 2)
        --vim.api.nvim_buf_add_highlight(hist_state.buf, hist_state.ns, 'HistQuery',   line_idx, 2, -1)
      else
        --vim.api.nvim_buf_add_highlight(hist_state.buf, hist_state.ns, 'HistQuery', line_idx, 2, -1)
      end
    end
  end

  if #hist_state.records == 0 then
    vim.api.nvim_buf_add_highlight(hist_state.buf, hist_state.ns, 'HistEmpty', 0, 0, -1)
  end

  -- Move win cursor
  if hist_state.win and vim.api.nvim_win_is_valid(hist_state.win) then
    local safe_cursor = math.max(1, math.min(hist_state.cursor, math.max(1, #hist_state.records)))
    vim.api.nvim_win_set_cursor(hist_state.win, { safe_cursor, 0 })
  end
end

local function hist_load()
  if not state.is_connected or not state.db_id then
    hist_state.records = {}
    return
  end
  local path = state.sys_db
  local db   = require('sqlite.db'):open(path)
  local result = db:eval(string.format(
    "SELECT id, query, starred FROM query_history WHERE db_id='%s' ORDER BY starred DESC, created_at DESC;",
    state.db_id:gsub("'","''")
  ))
  db:close()
  hist_state.records = (type(result) == 'table') and result or {}
end

function M.open_history(q_ovr_win, q_ovr_buf)
  if hist_state.win and vim.api.nvim_win_is_valid(hist_state.win) then
    hist_close(q_ovr_win, q_ovr_buf)
    return
  end

  if not state.is_connected or not state.db_id then
    state.last_query_status = 'Not connected to any db at the moment'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  hist_load()
  hist_state.cursor = 1

  hist_state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(hist_state.buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(hist_state.buf, 'wrap', false)

  -- Center on screen
  local ui     = vim.api.nvim_list_uis()[1]
  local width  = math.floor(ui.width  * 0.6)
  local height = math.floor(ui.height * 0.6)
  local row    = math.floor((ui.height - height) / 3.5)
  local col    = math.floor((ui.width  - width)  / 2)

  hist_state.win = vim.api.nvim_open_win(hist_state.buf, true, { -- true = focus it
    relative   = 'editor',
    row        = row,
    col        = col,
    width      = width,
    height     = height,
    style      = 'minimal',
    border     = 'rounded',
    title      = ' Query History — ' .. (state.db_type or '') .. ' ',
    title_pos  = 'left',
    footer     = ' Select: <enter> · Star: <*> · Delete: <^d> ',
    footer_pos = 'right',
    zindex     = 300,
  })

  vim.api.nvim_set_hl(0, 'HistBorder', { fg = '#8BE9FD' })
  vim.api.nvim_win_set_option(hist_state.win, 'winhl',     'Normal:Normal,FloatBorder:HistBorder,FloatTitle:FloatTitleActive')
  vim.api.nvim_win_set_option(hist_state.win, 'wrap',      false)
  vim.api.nvim_win_set_option(hist_state.win, 'cursorline', true)

  hist_render()

  -- Keymaps on hist_state.buf (NOT q_ovr_buf) so other bufs are unaffected
  local bopts = { buffer = hist_state.buf, nowait = true, silent = true }

  -- Remove j/k keymaps, replace with CursorMoved autocmd
  vim.api.nvim_create_autocmd('CursorMoved', {
    buffer   = hist_state.buf,
    callback = function()
      if hist_state.win and vim.api.nvim_win_is_valid(hist_state.win) then
        local cursor = vim.api.nvim_win_get_cursor(hist_state.win)
        hist_state.cursor = cursor[1]
        hist_render()
      end
    end,
  })

  vim.keymap.set('n', '<CR>', function()
    local rec = hist_state.records[hist_state.cursor]
    if not rec then return end
    hist_close(q_ovr_win, q_ovr_buf)
    vim.api.nvim_buf_set_option(q_ovr_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(q_ovr_buf, 0, -1, false, { rec.query })
    vim.api.nvim_buf_set_option(q_ovr_buf, 'modifiable', false)
    vim.api.nvim_set_current_win(q_ovr_win)
  end, bopts)

  vim.keymap.set('n', '<C-d>', function()
    local rec = hist_state.records[hist_state.cursor]
    if not rec then return end
    local path = state.sys_db
    local db   = require('sqlite.db'):open(path)
    db:eval(string.format("DELETE FROM query_history WHERE id='%s';", rec.id:gsub("'","''")))
    db:close()
    hist_load()
    hist_state.cursor = math.min(hist_state.cursor, math.max(1, #hist_state.records))
    hist_render()
  end, bopts)

  vim.keymap.set('n', '*', function()
    local rec = hist_state.records[hist_state.cursor]
    if not rec then return end
    local new_starred = rec.starred == 1 and 0 or 1
    local path = state.sys_db
    local db   = require('sqlite.db'):open(path)
    db:eval(string.format(
      "UPDATE query_history SET starred=%d WHERE id='%s';",
      new_starred, rec.id:gsub("'","''")
    ))
    db:close()
    hist_load()
    for i, r in ipairs(hist_state.records) do
      if r.id == rec.id then hist_state.cursor = i; break end
    end
    hist_render()
  end, bopts)

  vim.keymap.set('n', '<Esc>', function()
    hist_close(q_ovr_win, q_ovr_buf)
    vim.api.nvim_set_current_win(q_ovr_win)
  end, bopts)
end

return M