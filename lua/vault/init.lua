local api = vim.api
local M = {}

local state = {
  wins = {},
  parent_win_id = nil,
  tree_highlights = {},  -- populated by render_explorer_tree
  tree_line_map = {},
  result_sets = {},
  result_set_index = 1,
  ns = api.nvim_create_namespace 'DbUI_NS',
  overlay_ns = api.nvim_create_namespace 'ExplorerOverlayNS',
  q_overlay_ns = api.nvim_create_namespace 'QueryOverlayNS',
  r_overlay_ns = api.nvim_create_namespace 'ResultsOverlayNS',
  hl_active_border = 'FloatBorderActive',
  hl_inactive_border = 'FloatBorderInactive',
  hl_overlay_active = 'ExplorerOverlayActive',
  hl_first_line_text = 'ExplorerFirstLineText',
  hl_mode_normal = 'ModeNormal',
  hl_mode_insert = 'ModeInsert',
  -- Table colors
  hl_header = 'DbTableHeader',
  hl_row_even = 'DbTableRowEven',
  hl_row_odd = 'DbTableRowOdd',
  hl_cell_cursor = 'DbTableCellCursor',
  suggest_win = nil,
  suggest_buf = nil,
  suggestions = {},
  table_cols = {},
  last_query_status = '',
  -- DB states
  open_nodes = {}, -- Track state
  root_node_id = nil,
  is_connected = false,
  db_type = nil,
  db_path = nil,
  db_data = {},
  db_types = { 'SQLite', 'PostgreSQL', 'MySQL', 'OracleDB', 'MongoDB', 'MariaDB' },
  icons = {
    db = '⌘',
    folder_open = '▼',
    folder_closed = '▶',
    table = '',
    field = '',
  },
}

-- Define the options table here so it is available globally within your module scope
local opts = { noremap = true, silent = true }

local function map(buf, mode, lhs, rhs)
  -- This line will now correctly receive a Lua table for 'opts'
  api.nvim_buf_set_keymap(buf, mode, lhs, rhs, opts)
end

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

local function generate_id()
  -- Get current time in seconds since the epoch as a number (float in standard Lua)
  local timestamp = os.time() --

  -- Multiply by 1e7 (10,000,000) and convert to an integer
  -- Lua performs floating point arithmetic, so we use math.floor to get an integer value
  local scaled_time_int = math.floor(timestamp * 1e7)

  -- Format the integer as a hexadecimal string
  local hex_string = string.format('%x', scaled_time_int)

  -- The Python [2:] slice removes the "0x" prefix.
  -- Lua's string.format("%x", ...) does not add a prefix, so slicing is not needed.

  return hex_string
end

-- 1. Setup Highlight Groups
local function setup_highlight_groups()
  api.nvim_set_hl(0, state.hl_active_border, { fg = '#8BE9FD' })
  api.nvim_set_hl(0, state.hl_inactive_border, { fg = '#44475A' })
  api.nvim_set_hl(0, 'FloatTitleActive', { fg = '#8BE9FD', bg = 'NONE', bold = true })
  api.nvim_set_hl(0, 'FloatTitleInactive', { fg = '#44475A', bg = 'NONE' })
  api.nvim_set_hl(0, state.hl_overlay_active, { bg = '#2c323c' })
  api.nvim_set_hl(0, state.hl_first_line_text, { bg = '#44475a', fg = '#8BE9FD', bold = true })
  api.nvim_set_hl(0, state.hl_mode_normal, { fg = '#282a36', bg = '#8BE9FD', bold = true })
  api.nvim_set_hl(0, state.hl_mode_insert, { fg = '#282a36', bg = '#50FA7B', bold = true })
  -- Table Colors
  api.nvim_set_hl(0, state.hl_header, { bg = '#6272A4', fg = '#FFFFFF', bold = true })
  api.nvim_set_hl(0, state.hl_row_even, { bg = '#282a36' })
  api.nvim_set_hl(0, state.hl_row_odd, { bg = '#343746' })
  api.nvim_set_hl(0, state.hl_cell_cursor, { bg = '#CBDAD4', fg = '#282a36', bold = true })
  api.nvim_set_hl(0, 'DbWinNormalBG', { fg = '#6272A4', bg = 'NONE' })
  -- DB tree config
  -- background-only: no fg so icon colours can show through
  api.nvim_set_hl(0, 'ExplorerLineActiveBG', { bg = '#3d4555' })
  -- text colour for the label part only
  api.nvim_set_hl(0, 'ExplorerLineActive', { fg = '#F1FA8C', bg = '#44475A', bold = true }) -- Active line text color
  api.nvim_set_hl(0, 'ExplorerLineInactive', { fg = '#BD93F9', bg = 'NONE' }) -- Inactive line text color
  -- Define soft red for labels
  api.nvim_set_hl(0, 'SoftRedLabel', { fg = '#e06c75' })
  -- Define soft orange for keys/actions
  api.nvim_set_hl(0, 'SoftOrangeKey', { fg = '#d19a66' })
  api.nvim_set_hl(0, 'DbTimeGray', { fg = '#6272A4' }) -- A nice "Dracula" style muted gray/blue unimplemented for the bottom bar time color
  api.nvim_set_hl(0, 'MyCustomWinBG', { bg = '#1c1c23', fg = '#cdd6f4' }) -- for the new connection pop up
  -- Explorer tree
  api.nvim_set_hl(0, 'ExplorerConnector',  { fg = '#6272A4' })
  api.nvim_set_hl(0, 'ExplorerIconDB',     { fg = '#FFB86C', bold = true })
  api.nvim_set_hl(0, 'ExplorerIconOpen',   { fg = '#8BE9FD' })
  api.nvim_set_hl(0, 'ExplorerIconClosed', { fg = '#BD93F9' })
  api.nvim_set_hl(0, 'ExplorerIconField',  { fg = '#6272A4' })
  api.nvim_set_hl(0, 'ExplorerFolder',     { fg = '#8BE9FD', bold = true })
  api.nvim_set_hl(0, 'ExplorerTable',      { fg = '#F1FA8C' })
  api.nvim_set_hl(0, 'ExplorerField',      { fg = '#6272A4' })
  api.nvim_set_hl(0, 'ExplorerEmpty',      { fg = '#53566b', italic = true })
  -- Explorer tree highlights
  api.nvim_set_hl(0, 'ExplorerConnectorActive', { fg = '#BD93F9' })  -- add this line
  api.nvim_set_hl(0, 'ExplorerFieldName', { fg = '#F8F8F2', bold = true })
  api.nvim_set_hl(0, 'ExplorerFieldType', { fg = '#6272A4', italic = true })
end

-- 2. Autocomplete Engine Logic
local suggest_state = {
  win = nil,
  buf = nil,
  items = {},       -- filtered keyword list
  selected = 1,     -- 1-based index of highlighted item
}

local function suggest_is_open()
  return suggest_state.win ~= nil
    and api.nvim_win_is_valid(suggest_state.win)
end

local function suggest_close()
  if suggest_is_open() then
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
  if not suggest_is_open() then return end
  local ns = api.nvim_create_namespace 'SuggestHL'
  api.nvim_buf_clear_namespace(suggest_state.buf, ns, 0, -1)
  -- selected is 1-based, nvim highlight is 0-based
  api.nvim_buf_add_highlight(
    suggest_state.buf, ns, 'PmenuSel',
    suggest_state.selected - 1, 0, -1
  )
end

-- move selection up/down, wraps around
local function suggest_move(dir)
  if not suggest_is_open() then return end
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

  if not suggest_is_open() then
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
local function suggest_update(q_ovr_win)
  if not api.nvim_win_is_valid(q_ovr_win) then
    suggest_close()
    return
  end

  local cursor = api.nvim_win_get_cursor(q_ovr_win)
  local line   = api.nvim_get_current_line()
  -- grab the word fragment immediately before the cursor
  local before       = line:sub(1, cursor[2])
  local word_fragment = before:match '[%a_][%w_]*$'  -- must start with a letter

  if not word_fragment or #word_fragment < 1 then
    suggest_close()
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
    suggest_close()
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
local function suggest_confirm(q_ovr_win)
  if not suggest_is_open() or #suggest_state.items == 0 then
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

  suggest_close()
  return true
end

-- 3. Scrollbar Logic
local function get_h_scroll_indicator(win_id)
  if not api.nvim_win_is_valid(win_id) then
    return ''
  end
  local leftcol = api.nvim_win_call(win_id, function()
    return vim.fn.winsaveview().leftcol
  end)
  local win_width = api.nvim_win_get_width(win_id)
  local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(win_id), 0, -1, false)
  local max_w = 0
  for _, l in ipairs(lines) do
    max_w = math.max(max_w, #l)
  end
  if max_w <= win_width then
    return string.rep('░', win_width)
  end
  local bar_len = win_width
  local thumb_pos = math.floor((leftcol / (max_w - win_width)) * (bar_len - 1))
  local bar = ''
  for i = 0, bar_len - 1 do
    bar = bar .. (i == thumb_pos and '█████' or '░')
  end
  return bar
end

local function apply_table_highlights(buf, has_header)
  api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
  local line_count = api.nvim_buf_line_count(buf)
  if has_header then
    api.nvim_buf_add_highlight(buf, state.ns, state.hl_header, 0, 0, -1)
  end
  local start = has_header and 1 or 0
  for i = start, line_count - 1 do
    local hl = (i % 2 == 0) and state.hl_row_even or state.hl_row_odd
    api.nvim_buf_add_highlight(buf, state.ns, hl, i, 0, -1)
  end
end

-- 3. Table config
local function old_apply_table_highlights(buf)
  api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
  local line_count = api.nvim_buf_line_count(buf)
  api.nvim_buf_add_highlight(buf, state.ns, state.hl_header, 0, 0, -1)
  for i = 1, line_count - 1 do
    local hl = (i % 2 == 0) and state.hl_row_even or state.hl_row_odd
    api.nvim_buf_add_highlight(buf, state.ns, hl, i, 0, -1)
  end
end

local function render_results_table(buf, data)
  local win_id = vim.fn.bufwinid(buf)
  local win_width = win_id ~= -1 and vim.api.nvim_win_get_width(win_id) or vim.o.columns

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

  ---- 6. Write to buffer
  --api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  --api.nvim_buf_set_option(buf, 'modifiable', true)
  --api.nvim_buf_set_lines(buf, 0, -1, false, { header_str })
  --api.nvim_buf_set_lines(buf, 1, -1, false, row_lines)
  --api.nvim_buf_set_option(buf, 'modifiable', false)

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

  apply_table_highlights(buf)
end

local function oldv3_render_results_table(buf, data)
  local win_id = vim.fn.bufwinid(buf)
  local win_width = win_id ~= -1 and vim.api.nvim_win_get_width(win_id) or vim.o.columns

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

  -- 3. Cell builder — returns the string AND its byte length separately
  --    display_width = strdisplaywidth, but padding uses spaces (1 byte = 1 col)
  --    so byte_len = #content_bytes + padding_spaces
  local function build_cell(val, width)
    local s = ' ' .. tostring(val or ''):match('^%s*(.-)%s*$')
    local display_w = vim.fn.strdisplaywidth(s)
    local padding = width - display_w
    if padding < 0 then padding = 0 end
    local spaces = string.rep(' ', padding)
    return s .. spaces, #s + padding  -- content, byte_length
  end

  -- 4. Build header — track byte offsets for state.table_cols
  local header_str = ''
  state.table_cols = {}
  local byte_pos = 0
  for i, h in ipairs(data.headers) do
    table.insert(state.table_cols, byte_pos)
    local full_cell, byte_len = build_cell(h:upper(), widths[i])
    header_str = header_str .. full_cell
    byte_pos = byte_pos + byte_len
  end

  -- 5. Build rows — use same build_cell so byte offsets match header
  local row_lines = {}
  for _, row in ipairs(data.rows) do
    local line = ''
    for i, val in ipairs(row) do
      local full_cell, _ = build_cell(val, widths[i])
      line = line .. full_cell
    end
    table.insert(row_lines, line)
  end

  -- 6. Write to buffer
  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(buf, 'modifiable', true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { header_str })
  api.nvim_buf_set_lines(buf, 1, -1, false, row_lines)
  api.nvim_buf_set_option(buf, 'modifiable', false)

  -- 7. No wrap — horizontal scroll instead
  if win_id ~= -1 then
    api.nvim_win_set_option(win_id, 'wrap', false)
  end

  apply_table_highlights(buf)
end

local function oldv2_render_results_table(buf, data)
  local win_id = vim.fn.bufwinid(buf)
  local win_width = win_id ~= -1 and vim.api.nvim_win_get_width(win_id) or vim.o.columns

  local COL_PADDING = 2

  -- 1. Natural widths — no capping
  local widths = {}
  for i, h in ipairs(data.headers) do
    widths[i] = vim.fn.strdisplaywidth(h)
    for _, row in ipairs(data.rows) do
      local stripped = tostring(row[i] or ''):match('^%s*(.-)%s*$')
      widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(stripped))
    end
    widths[i] = widths[i] + COL_PADDING
  end

  -- 2. Stretch last column to at least fill window width
  local current_total = 0
  for i = 1, #widths - 1 do
    current_total = current_total + widths[i]
  end
  local remaining = win_width - current_total
  if remaining > widths[#widths] then
    widths[#widths] = remaining
  end

  -- 3. Helper: pad a cell to exact width (no truncation)
  local function cell(val, width)
    local s = ' ' .. tostring(val or ''):match('^%s*(.-)%s*$')
    -- Use vim.fn.strdisplaywidth for correct multibyte display width
    local display_w = vim.fn.strdisplaywidth(s)
    local padding = width - display_w
    if padding < 0 then padding = 0 end
    return s .. string.rep(' ', padding)
  end

  -- 4. Build header
  local header_str = ''
  state.table_cols = {}
  for i, h in ipairs(data.headers) do
    table.insert(state.table_cols, #header_str)
    header_str = header_str .. cell(h:upper(), widths[i])
  end

  -- 5. Build rows
  local row_lines = {}
  for _, row in ipairs(data.rows) do
    local line = ''
    for i, val in ipairs(row) do
      line = line .. cell(val, widths[i])
    end
    table.insert(row_lines, line)
  end

  -- 6. Write to buffer
  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(buf, 'modifiable', true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { header_str })
  api.nvim_buf_set_lines(buf, 1, -1, false, row_lines)
  api.nvim_buf_set_option(buf, 'modifiable', false)

  -- 7. Disable wrap so long lines scroll horizontally instead of wrapping
  if win_id ~= -1 then
    api.nvim_win_set_option(win_id, 'wrap', false)
  end

  apply_table_highlights(buf)
end

local function old_render_results_table(buf, data)
  -- 1. Get window width for padding (defaults to editor width if window isn't active)
  local win_id = vim.fn.bufwinid(buf)
  local win_width = win_id ~= -1 and vim.api.nvim_win_get_width(win_id) or vim.o.columns

  local widths = {}
  for i, h in ipairs(data.headers) do
    widths[i] = #h
    for _, row in ipairs(data.rows) do
      widths[i] = math.max(widths[i], #tostring(row[i] or ''))
    end
    widths[i] = widths[i] + 4
  end

  -- 2. Adjust last column to stretch to full width
  local current_total = 0
  for i = 1, #widths - 1 do
    current_total = current_total + widths[i]
  end
  local remaining = win_width - current_total
  if remaining > widths[#widths] then
    widths[#widths] = remaining
  end

  local header_str = ''
  state.table_cols = {}
  for i, h in ipairs(data.headers) do
    table.insert(state.table_cols, #header_str)
    local padded = ' ' .. h:upper()           -- leading space + capitalize
    header_str = header_str .. padded .. string.rep(' ', widths[i] - #padded)
  end

  local row_lines = {}
  for _, row in ipairs(data.rows) do
    local line = ''
    for i, val in ipairs(row) do
      local s = ' ' .. tostring(val or '')    -- leading space
      -- Use string.rep to pad each cell to the calculated width
      line = line .. s .. string.rep(' ', widths[i] - #s)
    end
    -- Ensure the line itself fills the full width even if row has fewer columns
    if #line < win_width then
      line = line .. string.rep(' ', win_width - #line)
    end
    table.insert(row_lines, line)
  end

  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(buf, 'modifiable', true)
  api.nvim_buf_set_lines(buf, 0, -1, false, { header_str })
  api.nvim_buf_set_lines(buf, 1, -1, false, row_lines)
  api.nvim_buf_set_option(buf, 'modifiable', false)
  apply_table_highlights(buf)
end

local function oldv2_move_cell(dir)
  local win = api.nvim_get_current_win()
  local cursor = api.nvim_win_get_cursor(win)

  local row_idx = cursor[1] - 1
  local offsets = (state.row_col_offsets and state.row_col_offsets[row_idx])
                  or state.table_cols

  local col_idx = 1
  for i, offset in ipairs(offsets) do
    if cursor[2] >= offset then
      col_idx = i
    end
  end

  local next_idx = math.max(1, math.min(#offsets, col_idx + dir))
  api.nvim_win_set_cursor(win, { cursor[1], offsets[next_idx] })
end

-- 4. Cursor & Cell Movement Logic
local function old_move_cell(dir)
  local win = api.nvim_get_current_win()
  local cursor = api.nvim_win_get_cursor(win)
  local current_idx = 1
  for i, offset in ipairs(state.table_cols) do
    if cursor[2] >= offset then
      current_idx = i
    end
  end
  local next_idx = math.max(1, math.min(#state.table_cols, current_idx + dir))
  api.nvim_win_set_cursor(win, { cursor[1], state.table_cols[next_idx] })
end

local function fetch_dynamic_data(db_path, db_name, db_type, db_id)
  local db = require('sqlite.db'):open(db_path)

  -- 1. Initialize the root structure
  state.db_data = {
    [db_name] = {
      id = db_id or '',
      name = db_name .. ' ' .. '[' .. db_type .. ']',
      type = 'db',
      children = { 'Tables', 'Views', 'Indexes', 'Triggers' },
    },
    ['Tables'] = { name = 'Tables', type = 'folder', children = {} },
    ['Views'] = { name = 'Views', type = 'folder', children = {} },
    ['Indexes'] = { name = 'Indexes', type = 'folder',children = {} },
    ['Triggers'] = { name = 'Triggers', type = 'folder', children = {} },
  }

  -- 2. Fetch all objects (Tables, Views, Triggers, Indexes)
  local schema = db:eval [[
      SELECT name, type FROM sqlite_schema 
      WHERE name NOT LIKE 'sqlite_%'
  ]]

  for _, obj in ipairs(schema) do
    local folder_key = obj.type:gsub('^%l', string.upper) .. 's' -- e.g., 'table' -> 'Tables'
    if state.db_data[folder_key] then
      table.insert(state.db_data[folder_key].children, obj.name)

      -- 3. If it's a table, fetch its columns (fields)
      if obj.type == 'table' then
        local cols = db:eval('PRAGMA table_info(' .. obj.name .. ')')
        local field_children = {}
        for _, col in ipairs(cols) do
          local field_name = obj.name .. '.' .. col.name
          local display = col.name .. ' ' .. col.type
          state.db_data[field_name] = { name = display, type = 'field' }
          table.insert(field_children, field_name)
        end

        state.db_data[obj.name] = {
          name = obj.name,
          type = 'table',
          children = field_children,
        }

        -- initialize so is_open is false (not nil) from the first render
        if state.open_nodes[obj.name] == nil then
          state.open_nodes[obj.name] = false
        end
      else
        -- Views/Indexes/Triggers usually don't have children in this UI
        state.db_data[obj.name] = { name = obj.name, type = obj.type, children = {} }
      end
    end
  end

  db:close()
  return state.db_data
end

local function render_explorer_tree(buf)
  local lines = {}
  local highlights = {}  -- { line_idx (0-based), col_start, col_end, hl_group }
  state.tree_line_map = {}  -- ← add this
  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(buf, 'modifiable', true)

  -- Track which levels still have more siblings coming (for │ connectors)
  -- prefix_stack[level] = true means that level still has items below
  local function build_prefix(level, is_last, prefix_stack)
    local prefix = ''
    for i = 1, level - 1 do
      if prefix_stack[i] then
        prefix = prefix .. '│  '
      else
        prefix = prefix .. '   '
      end
    end
    if level > 0 then
      prefix = prefix .. (is_last and '└ ' or '├ ')
    end
    return prefix
  end

  local function add_node_line(text, level, is_last, prefix_stack, node_type, is_open, node_id, nodeData)
    local prefix = build_prefix(level, is_last, prefix_stack)

    local icon = ''
    if node_type == 'db' then
      icon = (is_open and '▼' or '▶') .. '  '  -- collapsible + star
    elseif node_type == 'folder' or node_type == 'table' then
      icon = (is_open and '▼ ' or '▶ ')
    elseif node_type == 'field' then
      icon = ' '
    elseif node_type == 'path' then
      icon = '🖿 '
    elseif not nodeData.children then -- empty logic
      icon = ''
    end

    local line_nr = #lines

    -- for field nodes: split "name TYPE" into two styled segments
    if node_type == 'field' then
      local fname, ftype = text:match '^([^%s]+)%s+(.+)$'
      if fname and ftype then
        table.insert(lines, prefix .. icon .. fname .. ' ' .. ftype:upper())
        -- connector
        table.insert(highlights, { line_nr, 0, #prefix, 'ExplorerConnector' })
        -- icon (dash)
        table.insert(highlights, { line_nr, #prefix, #prefix + #icon, 'ExplorerIconField' })
        -- field name: bold
        local name_start = #prefix + #icon
        local name_end   = name_start + #fname
        table.insert(highlights, { line_nr, name_start, name_end, 'ExplorerFieldName' })
        -- field type: italic dim
        local type_start = name_end + 1  -- +1 for the space
        table.insert(highlights, { line_nr, type_start, -1, 'ExplorerFieldType' })
        return
      end
    end

    -- for path nodes: split "name TYPE" into two styled segments
    if node_type == 'path' then
      local fname, ftype = text:match '^([^%s]+)%s+(.+)$'
      if fname and ftype then
        table.insert(lines, prefix .. icon .. fname .. ' ' .. ftype:upper())
        -- connector
        table.insert(highlights, { line_nr, 0, #prefix, 'ExplorerConnector' })
        -- icon (dash)
        table.insert(highlights, { line_nr, #prefix, #prefix + #icon, 'ExplorerIconField' })
        -- field name: bold
        local name_start = #prefix + #icon
        local name_end   = name_start + #fname
        table.insert(highlights, { line_nr, name_start, name_end, 'ExplorerFieldName' })
        -- field type: italic dim
        local type_start = name_end + 1  -- +1 for the space
        table.insert(highlights, { line_nr, type_start, -1, 'ExplorerFieldType' })
        return
      end
    end

    table.insert(lines, prefix .. icon .. text)

    -- connector highlight
    if #prefix > 0 then
      table.insert(highlights, { line_nr, 0, #prefix, 'ExplorerConnector' })
    end

    local icon_start = #prefix
    local icon_end   = icon_start + #icon

    if node_type == 'db' then
      -- ▼/► in one color, * in another
      local arrow_end = icon_start + 2  -- '▼ ' or '► ' = 2 bytes (arrow + space... but ▼ is multibyte)
      -- safer: highlight the whole icon as one, then text
      table.insert(highlights, { line_nr, icon_start, icon_end, 'ExplorerIconDB' })
      table.insert(highlights, { line_nr, icon_end,   -1,       'ExplorerLineInactive' })
    elseif node_type == 'folder' then
      table.insert(highlights, { line_nr, icon_start, icon_end, is_open and 'ExplorerIconOpen' or 'ExplorerIconClosed' })
      table.insert(highlights, { line_nr, icon_end,   -1,       'ExplorerFolder' })
    elseif node_type == 'table' then
      table.insert(highlights, { line_nr, icon_start, icon_end, is_open and 'ExplorerIconOpen' or 'ExplorerIconClosed' })
      table.insert(highlights, { line_nr, icon_end,   -1,       'ExplorerTable' })
    elseif node_type == 'path' then
      table.insert(highlights, { line_nr, icon_start, icon_end, 'ExplorerConnector' })
    elseif not nodeData.children then
      table.insert(highlights, { line_nr, 0, -1, 'ExplorerEmpty' })
    end
  end

  -- THE RECURSIVE DRAW LOGIC
  local function draw_node(node_id, level, is_last, prefix_stack)
    local node_data = state.db_data[node_id]
    if node_data == nil then return end

    -- record which line this node is on BEFORE adding lines
    local my_line_nr = #lines  -- 0-based, since lines is 0-indexed after insert
    state.tree_line_map[my_line_nr] = node_id  -- ← add this

    local is_open    = state.open_nodes[node_id]
    local display    = node_data.name

    -- update prefix_stack: current level has more siblings if not last
    local new_stack = {}
    for k, v in pairs(prefix_stack) do new_stack[k] = v end
    new_stack[level] = not is_last

    -- draw the node itself
    if node_data.type == 'db' then
      add_node_line(display, level, is_last, new_stack, 'db', is_open, node_data.id, node_data)
      if is_open then
        add_node_line('Path: ' .. (state.db_path or ''), level + 1, false, new_stack, 'path', nil, nil, node_data)
      end
    elseif node_data.type == 'folder' then
      add_node_line(display, level, is_last, new_stack, 'folder', is_open, node_id, node_data)
    elseif node_data.type == 'table' then
      add_node_line(display, level, is_last, new_stack, 'table', is_open, node_id, node_data)
    else
      add_node_line(display, level, is_last, new_stack, 'field', nil, node_id, node_data)
    end

    -- draw children if open
    if is_open and node_data.children then
      local children = node_data.children
      if #children == 0 then
        -- empty placeholder
        local empty_prefix = build_prefix(level + 1, true, new_stack)
        local line_nr = #lines
        table.insert(lines, empty_prefix .. '(empty)')
        table.insert(highlights, { line_nr, 0, #empty_prefix, 'ExplorerConnector' })  -- was ExplorerEmpty
        table.insert(highlights, { line_nr, #empty_prefix, -1, 'ExplorerEmpty' })
        state.tree_line_map[line_nr] = node_id .. '__empty__'  -- ← add this
      else
        for i, child_id in ipairs(children) do
          local child_is_last = (i == #children)
          draw_node(child_id, level + 1, child_is_last, new_stack)
        end
      end
    end
  end

  local root_id = state.root_node_id or 'MyDatabase'
  draw_node(root_id, 0, true, {})

  api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
  for _, hl in ipairs(highlights) do
    api.nvim_buf_add_highlight(buf, state.ns, hl[4], hl[1], hl[2], hl[3])
  end

  state.tree_highlights = highlights  -- save here, once, after all nodes are done

  api.nvim_buf_set_option(buf, 'modifiable', false)
end

local function show_dropdown_picker(field, parent_win)
  if not field.options then
    return
  end

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, field.options)

  local picker_win = api.nvim_open_win(buf, true, {
    relative = 'win',
    win = parent_win,
    row = 1,
    col = -1,
    width = field.width or 20,
    height = #field.options,
    style = 'minimal',
    border = 'rounded',
    zindex = 300,
  })

  -- ADD THESE TWO LINES:
  -- Enable the horizontal highlight bar
  vim.api.nvim_set_option_value('cursorline', true, { win = picker_win })
  -- Optional: Link the highlight to a specific group like 'Visual' or 'PmenuSel'
  vim.api.nvim_set_option_value('winhl', 'CursorLine:Visual', { win = picker_win })

  vim.keymap.set('n', '<CR>', function()
    local line = api.nvim_get_current_line()
    field.value = line
    api.nvim_buf_set_lines(api.nvim_win_get_buf(parent_win), 0, -1, false, { line })
    api.nvim_win_close(picker_win, true)
  end, { buffer = buf, silent = true })

  vim.keymap.set('n', '<Esc>', function()
    api.nvim_win_close(picker_win, true)
  end, { buffer = buf, silent = true })
end

local conn_state = {
  active_idx = 1,
  fields = {
    { name = ' Database Name ', value = 'MyDatabase', type = 'input', row = 4, col = 6, width = 75 },
    { name = ' Database Type ', value = 'SQLite', type = 'dropdown', row = 8, col = 6, width = 75, options = { 'SQLite', 'PostgreSQL', 'MySQL', 'OracleDB', 'MongoDB', 'MariaDB'} },
    { name = ' Database Path ', value = '/path/to/db.db', type = 'input', row = 12, col = 6, width = 70 },
    { name = 'Browser', value = '...', type = 'button', row = 12, col = 78, width = 3 },
  },
  wins = {}, -- Track all 4 field windows here
  main_win = nil,
}

local function trigger_save_connection()
  -- 1. Helper to get text from a field's buffer
  local function get_field_text(index)
      local win = conn_state.wins[index]
      if win and vim.api.nvim_win_is_valid(win) then
          local buf = vim.api.nvim_win_get_buf(win)
          -- nvim_buf_get_lines(buf, start, end, strict)
          -- 0, -1 gets the entire content of the buffer
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          return lines[1] or "" -- Take the first line of the input
      end
      return ""
  end

  -- 2. Extract values based on your UI layout indices
  -- Replace [1], [2], etc. with the actual indices of your fields
  local typed_name = get_field_text(1)
  local selected_type = get_field_text(2)
  local typed_path = get_field_text(3)

  -- 3. Validation: Check if the file exists at the typed path
  local file_exists = vim.loop.fs_stat(typed_path)
  if not file_exists then
      print("Invalid Path: File does not exist!")
      return
  end

  local path = './database.db'
  local f = io.open(path, 'r')

  if f then
    f:close()
    local db = require('sqlite.db'):open(path)
    local db_id = generate_id()

    local insert_query = string.format(
      [[INSERT INTO database (id, name, type, path) VALUES ('%s', '%s', '%s', '%s');]],
      db_id:gsub("'", "''"),
      typed_name:gsub("'", "''"), -- Escape single quotes to prevent SQL injection
      selected_type:gsub("'", "''"),
      typed_path:gsub("'", "''")
    )

    local success, err = pcall(function()
      db:eval(insert_query) -- Replace 'db' with your actual database handler object
    end)

    if success then
      --print("Successfully saved connection: " .. typed_name)
      for id, name in pairs(state.wins) do
        if name == 'overlay' then
            local ovr_buf = vim.api.nvim_win_get_buf(id)
            api.nvim_buf_set_option(ovr_buf, 'buftype', 'nofile')
            api.nvim_buf_set_option(ovr_buf, 'modifiable', true)

            --api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { '' .. ' ' .. typed_name .. ' [' .. selected_type .. '] ' .. '--ID:' .. db_id })
            local line_content = '  ' .. typed_name .. ' [' .. selected_type .. '] ' .. '--ID:' .. db_id

            -- 1. Get the content of the very first line (index 0 to 1)
            local first_line = vim.api.nvim_buf_get_lines(ovr_buf, 0, 1, false)[1]

            -- 2. Check if the buffer is empty (line count is 1 and the line is empty)
            if vim.api.nvim_buf_line_count(ovr_buf) == 1 and first_line == "" then
                -- Replace the empty first line
                vim.api.nvim_buf_set_lines(ovr_buf, 0, 1, false, { line_content })
            else
                -- Append a new line at the very end
                vim.api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { line_content })
            end

            api.nvim_buf_set_option(ovr_buf, 'modifiable', false)
            break
        end
      end

      for i, win in ipairs(conn_state.wins) do
        api.nvim_win_close(win, true)
      end
      api.nvim_win_close(conn_state.main_win, true)
      -- TODO:  later replace with switch_to_win('overlay') the exact same thing
      for id, name in pairs(state.wins) do
        if name == 'overlay' and api.nvim_win_is_valid(id) then
          api.nvim_set_current_win(id)
          return
        end
      end
    elseif not success then
      print("Database Error: " .. tostring(err))
    end

    db:close()
  end
end

local function render_connection_ui()
  for id, name in pairs(state.wins) do
    if name == 'overlay' and api.nvim_win_is_valid(id) then
      api.nvim_set_current_win(id)
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width, height = 80, 26
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  conn_state.main_win = vim.api.nvim_open_win(buf, true, {
    relative = 'win',
    row = row - 5,
    col = col,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' New Connection ',
    title_pos = 'left',
    footer = ' (Move <tab>) (Select <enter>) (Save <s>) (Cancel <esc>) ',
    footer_pos = 'right',
    zindex = 250,
  })

  -- Apply the custom background to this specific window
  vim.api.nvim_set_option_value('winhl', 'Normal:MyCustomWinBG,FloatBorder:FloatBorder', { win = conn_state.main_win })

  -- 1. Draw Static Background (the boxes and labels)
  local lines = {
    '',
    '   General ',
    'ㅤ───────────────────────────────────────────────────────────────────────────',
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  -- 1. Clear any old windows if re-opening
  for _, win in pairs(conn_state.wins) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  conn_state.wins = {}

  -- 2. Create ALL field windows immediately
  for i, field in ipairs(conn_state.fields) do
    local ibuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { field.value })

    local win = vim.api.nvim_open_win(ibuf, false, { -- open as false (don't focus yet)
      relative = 'win',
      win = conn_state.main_win,
      row = field.row,
      col = field.col - 5,
      width = field.width,
      height = 1,
      title = field.name ~= 'Browser' and field.name or nil,
      style = 'minimal',
      border = 'rounded',
      zindex = 260,
    })
    conn_state.wins[i] = win

    -- Set common keymaps for every field buffer
    local opts = { buffer = ibuf, silent = true }
    vim.keymap.set('n', '<Tab>', function()
      conn_state.active_idx = (conn_state.active_idx % #conn_state.fields) + 1
      update_focus()
    end, opts)

    local opts = { buffer = ibuf, silent = true }
    vim.keymap.set('n', 's', function()
      trigger_save_connection()
    end, opts)

    -- ENTER to edit (simplified)
    vim.keymap.set('n', '<CR>', function()
      if field.type == 'button' then
        local path_field = conn_state.fields[i - 1] -- Assumes Path input is right before the Button
        local field_win = conn_state.wins[i - 1]
        local field_buf = api.nvim_win_get_buf(field_win)

        -- or you can use require('telescope.builtin').find_files {
        require('telescope').extensions.file_browser.file_browser {
          path = vim.fn.expand '%:p:h', -- Start at current file -- remove this line if use find_files
          cwd = vim.fn.expand '$HOME', -- OR start at Home to fix your issue -- remove this line if use find_files
          prompt_title = 'Select Database File',
          attach_mappings = function(prompt_bufnr, map)
            -- Schedule ensures the windows exist before we try to modify them
            vim.schedule(function()
              local picker = require('telescope.actions.state').get_current_picker(prompt_bufnr)

              -- Set zindex for the main prompt window
              if picker.prompt_win and vim.api.nvim_win_is_valid(picker.prompt_win) then
                vim.api.nvim_win_set_config(picker.prompt_win, { border = 'rounded', zindex = 400 })
              end

              -- Set zindex for the results window
              if picker.results_win and vim.api.nvim_win_is_valid(picker.results_win) then
                vim.api.nvim_win_set_config(picker.results_win, { border = 'rounded', zindex = 400 })
              end

              -- Set zindex for the preview window
              if picker.preview_win and vim.api.nvim_win_is_valid(picker.preview_win) then
                vim.api.nvim_win_set_config(picker.preview_win, { border = 'rounded', zindex = 400 })
              end
            end)

            local actions = require 'telescope.actions'
            local action_state = require 'telescope.actions.state'

            actions.select_default:replace(function()
              local selection = action_state.get_selected_entry()
              actions.close(prompt_bufnr)

              -- Update state and UI
              path_field.value = selection.path
              api.nvim_buf_set_lines(field_buf, 0, -1, false, { selection.path })
            end)
            return true
          end,
        }
      elseif field.type == 'dropdown' then
        -- Trigger the new picker function
        show_dropdown_picker(field, conn_state.wins[i])
      else
        vim.cmd 'startinsert!'
      end
    end, opts)

    -- ESC to close everything
    vim.keymap.set('n', '<esc>', function()
      for i, win in ipairs(conn_state.wins) do
        api.nvim_win_close(win, true)
      end
      api.nvim_win_close(conn_state.main_win, true)
      -- TODO:  later replace with switch_to_win('overlay') the exact same thing
      for id, name in pairs(state.wins) do
        if name == 'overlay' and api.nvim_win_is_valid(id) then
          api.nvim_set_current_win(id)
          return
        end
      end
    end, opts)
  end

  -- 3. Function to update which one is "Bright"
  function update_focus()
    for i, win in ipairs(conn_state.wins) do
      if i == conn_state.active_idx then
        -- Active: Bright Border/Text
        vim.api.nvim_win_set_option(win, 'winhl', 'Normal:NormalFloat,FloatBorder:FloatBorder')
        vim.api.nvim_set_current_win(win)
      else
        -- Inactive: Dimmed (Comment color usually works well for dimming)
        vim.api.nvim_win_set_option(win, 'winhl', 'Normal:Comment,FloatBorder:Comment')
      end
    end
  end

  update_focus()
end

local function render_edit_connection_ui(db_id, current_name, current_type, current_path)
  -- Focus overlay first (same pattern as render_connection_ui)
  for id, name in pairs(state.wins) do
    if name == 'overlay' and api.nvim_win_is_valid(id) then
      api.nvim_set_current_win(id)
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local width, height = 80, 26
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  -- Local edit state (mirrors conn_state but isolated)
  local edit_state = {
    active_idx = 1,
    fields = {
      { name = ' Database Name ', value = current_name, type = 'input',    row = 4,  col = 6, width = 75 },
      { name = ' Database Type ', value = current_type, type = 'dropdown', row = 8,  col = 6, width = 75, options = { 'SQLite', 'PostgreSQL', 'MySQL', 'OracleDB', 'MongoDB', 'MariaDB' } },
      { name = ' Database Path ', value = current_path, type = 'input',    row = 12, col = 6, width = 70 },
      { name = 'Browser',         value = '...', type = 'button',          row = 12, col = 78, width = 3 },
    },
    wins = {},
    main_win = nil,
  }

  edit_state.main_win = vim.api.nvim_open_win(buf, true, {
    relative = 'win',
    row = row - 5,
    col = col,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Edit Connection ',
    title_pos = 'left',
    footer = ' (Move <tab>) (Select <enter>) (Save <s>) (Cancel <esc>) ',
    footer_pos = 'right',
    zindex = 250,
  })

  vim.api.nvim_set_option_value('winhl', 'Normal:MyCustomWinBG,FloatBorder:FloatBorder', { win = edit_state.main_win })

  local lines = {
    '',
    '   General ',
    'ㅤ───────────────────────────────────────────────────────────────────────────',
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })

  -- Close any old field windows
  for _, win in pairs(edit_state.wins) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  edit_state.wins = {}

  -- Local update_focus for edit popup
  local function update_edit_focus()
    for i, win in ipairs(edit_state.wins) do
      if i == edit_state.active_idx then
        vim.api.nvim_win_set_option(win, 'winhl', 'Normal:NormalFloat,FloatBorder:FloatBorder')
        vim.api.nvim_set_current_win(win)
      else
        vim.api.nvim_win_set_option(win, 'winhl', 'Normal:Comment,FloatBorder:Comment')
      end
    end
  end

  -- Save handler (UPDATE instead of INSERT)
  local function trigger_update_connection()
    local function get_field_text(index)
      local win = edit_state.wins[index]
      if win and vim.api.nvim_win_is_valid(win) then
        local fbuf = vim.api.nvim_win_get_buf(win)
        local flines = vim.api.nvim_buf_get_lines(fbuf, 0, -1, false)
        return flines[1] or ''
      end
      return ''
    end

    local typed_name = get_field_text(1)
    local selected_type = get_field_text(2)
    local typed_path = get_field_text(3)

    -- Validate path
    if not vim.loop.fs_stat(typed_path) then
      print('Invalid Path: File does not exist!')
      return
    end

    local path = './database.db'
    local f = io.open(path, 'r')
    if not f then return end
    f:close()

    local db = require('sqlite.db'):open(path)
    local update_query = string.format(
      [[UPDATE database SET name='%s', type='%s', path='%s' WHERE id='%s';]],
      typed_name:gsub("'", "''"),
      selected_type:gsub("'", "''"),
      typed_path:gsub("'", "''"),
      db_id:gsub("'", "''")
    )

    local success, err = pcall(function()
      db:eval(update_query)
    end)

    if success then
      -- Refresh the overlay list
      for id, name in pairs(state.wins) do
        if name == 'overlay' then
          local ovr_buf = vim.api.nvim_win_get_buf(id)
          api.nvim_buf_set_option(ovr_buf, 'buftype', 'nofile')
          api.nvim_buf_set_option(ovr_buf, 'modifiable', true)
          -- Rebuild entire list from DB to reflect the rename
          api.nvim_buf_set_lines(ovr_buf, 0, -1, false, {})
          local result = db:eval('SELECT * FROM database')
          if type(result) == 'table' then
            for i, row in ipairs(result) do
              local line_content = ' ■ ' .. row.name .. ' [' .. row.type .. '] ' .. '--ID:' .. row.id
              if i == 1 then
                vim.api.nvim_buf_set_lines(ovr_buf, 0, 1, false, { line_content })
              else
                vim.api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { line_content })
              end
            end
          end
          api.nvim_buf_set_option(ovr_buf, 'modifiable', false)
          break
        end
      end

      -- Close edit popup windows
      for _, win in ipairs(edit_state.wins) do
        api.nvim_win_close(win, true)
      end
      api.nvim_win_close(edit_state.main_win, true)

      -- Return focus to overlay
      for id, name in pairs(state.wins) do
        if name == 'overlay' and api.nvim_win_is_valid(id) then
          api.nvim_set_current_win(id)
        end
      end
    else
      print('Database Error: ' .. tostring(err))
    end

    db:close()
  end

  -- Create field windows (same layout as render_connection_ui)
  for i, field in ipairs(edit_state.fields) do
    local ibuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { field.value })

    local win = vim.api.nvim_open_win(ibuf, false, {
      relative = 'win',
      win = edit_state.main_win,
      row = field.row,
      col = field.col - 5,
      width = field.width,
      height = 1,
      title = field.name ~= 'Browser' and field.name or nil,
      style = 'minimal',
      border = 'rounded',
      zindex = 260,
    })
    edit_state.wins[i] = win

    local bopts = { buffer = ibuf, silent = true }

    vim.keymap.set('n', '<Tab>', function()
      edit_state.active_idx = (edit_state.active_idx % #edit_state.fields) + 1
      update_edit_focus()
    end, bopts)

    vim.keymap.set('n', 's', function()
      trigger_update_connection()
    end, bopts)

    vim.keymap.set('n', '<CR>', function()
      if field.type == 'button' then
        local path_field = edit_state.fields[i - 1]
        local field_win = edit_state.wins[i - 1]
        local field_buf = api.nvim_win_get_buf(field_win)
        require('telescope').extensions.file_browser.file_browser {
          cwd = vim.fn.expand '$HOME',
          prompt_title = 'Select Database File',
          attach_mappings = function(prompt_bufnr, _)
            vim.schedule(function()
              local picker = require('telescope.actions.state').get_current_picker(prompt_bufnr)
              for _, win_key in ipairs { 'prompt_win', 'results_win', 'preview_win' } do
                if picker[win_key] and vim.api.nvim_win_is_valid(picker[win_key]) then
                  vim.api.nvim_win_set_config(picker[win_key], { border = 'rounded', zindex = 400 })
                end
              end
            end)
            local actions = require 'telescope.actions'
            local action_state = require 'telescope.actions.state'
            actions.select_default:replace(function()
              local selection = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              path_field.value = selection.path
              api.nvim_buf_set_lines(field_buf, 0, -1, false, { selection.path })
            end)
            return true
          end,
        }
      elseif field.type == 'dropdown' then
        show_dropdown_picker(field, edit_state.wins[i])
      else
        vim.cmd 'startinsert!'
      end
    end, bopts)

    vim.keymap.set('n', '<Esc>', function()
      for _, win in ipairs(edit_state.wins) do
        api.nvim_win_close(win, true)
      end
      api.nvim_win_close(edit_state.main_win, true)
      for id, name in pairs(state.wins) do
        if name == 'overlay' and api.nvim_win_is_valid(id) then
          api.nvim_set_current_win(id)
          return
        end
      end
    end, bopts)
  end

  update_edit_focus()
end

M.edit_db = function()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local cursor_row = api.nvim_win_get_cursor(win)[1]
  local line = api.nvim_buf_get_lines(buf, cursor_row - 1, cursor_row, false)[1]

  -- Only allow editing saved connections (not connected tree nodes)
  if state.is_connected then
    print('Disconnect first before editing a connection.')
    return
  end

  local node_id = line:match '--ID:(%w+)'
  local db_type = line:match '%[([^%]]+)%]'

  if not node_id or not db_type then
    print('No connection selected.')
    return
  end

  -- Fetch full record from DB
  local path = './database.db'
  local f = io.open(path, 'r')
  if not f then return end
  f:close()

  local db = require('sqlite.db'):open(path)
  local result = db:eval(
    string.format("SELECT name, type, path FROM database WHERE id = '%s';", node_id:gsub("'", "''"))
  )
  db:close()

  if not result or #result == 0 then
    print('Could not find connection with ID: ' .. node_id)
    return
  end

  local row = result[1]
  render_edit_connection_ui(node_id, row.name, row.type, row.path)
end

-- Add a function you can call externally when a connection is made
-- M.connect_db = function ()
local connect_db = function(ovr_buf, db_id)
  local path = './database.db'
  local f = io.open(path, 'r')

  if f then
    f:close()
    local db = require('sqlite.db'):open(path)

    local query = string.format(
      [[SELECT name, type, path FROM database WHERE id = '%s';]],
      db_id:gsub("'", "''")
    )

    local result = db:eval(query)
    local db_name = result[1].name
    local db_type = result[1].type
    local db_path = result[1].path

    state.db_data = fetch_dynamic_data(db_path, db_name, db_type, db_id)
    state.db_path = db_path
    state.db_type = db_type
    state.is_connected = true

    -- Set default open states
    --state.open_nodes = { [ db_name ] = true, ['Tables'] = false }
    -- (You would also fetch real schema data here)

    -- DYNAMIC FIX: Use the actual db_name from the database as the root key
    state.open_nodes = { 
      [db_name] = true,   -- Expands the Database root
      ['Tables'] = false   -- Expands the "Tables" folder automatically if true
    }
    state.root_node_id = db_name -- Store this to use in render_explorer_tree

    for _, child_id in ipairs(state.db_data[db_name].children) do
      if state.db_data[child_id].type == 'folder' then
        state.open_nodes[child_id] = false
        -- initialize all tables inside this folder
        for _, table_id in ipairs(state.db_data[child_id].children) do
          if state.db_data[table_id] and state.db_data[table_id].type == 'table' then
            state.open_nodes[table_id] = false
          end
        end
      end
    end

    render_explorer_tree(ovr_buf)
    db:close()
  end
end

M.delete_db = function()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)

  api.nvim_buf_set_option(buf, 'modifiable', true)
  local cursor_row = api.nvim_win_get_cursor(win)[1]
  local line = api.nvim_buf_get_lines(buf, cursor_row - 1, cursor_row, false)[1]

  if state.is_connected then
    print('Disconnect first before deleting a connection.')
    return
  end

  -- Use a pattern match to reliably extract the hidden ID suffix:
  local node_id = line:match '--ID:(%w+)' -- TODO: important line for later usage
  local node = line:match '(%w+)'
  local db_type = line:match '%[([^%]]+)%]'

  if not node_id or not db_type then
    print('No connection selected.')
    return
  end

  for _, word in ipairs(state.db_types) do
    if state.is_connected == false then
      if db_type == word then
        local path = './database.db'
        local f = io.open(path, 'r')

        if f then
          f:close()
          local db = require('sqlite.db'):open(path)
          local db_id = generate_id()

          local insert_query = string.format(
            [[DELETE FROM database WHERE id = '%s';]],
            node_id:gsub("'", "''") -- Escape single quotes to prevent SQL injection
          )

          local success, err = pcall(function()
            db:eval(insert_query) -- Replace 'db' with your actual database handler object
          end)

          if success then
            print("Successfully deleted connection: (ID:" .. node_id .. ")")
          elseif not success then
            print("Database Error: " .. tostring(err))
          end

          db:close()
        end
      end
    elseif state.is_connected == true then
      break        --        
    end
  end

  render_explorer_tree(buf)

  local path = './database.db'
  local f = io.open(path, 'r')

  if f then
    f:close()
    local db = require('sqlite.db'):open(path)
    local result = nil

    local success, err = pcall(function()
      result = db:eval("SELECT * from database") -- Replace 'db' with your actual database handler object
    end)

    if success then
      for id, name in pairs(state.wins) do
        if name == 'overlay' then
          local ovr_buf = vim.api.nvim_win_get_buf(id)
          api.nvim_buf_set_option(ovr_buf, 'buftype', 'nofile')
          api.nvim_buf_set_option(ovr_buf, 'modifiable', true)

          if result == true then
            break
          else
            for _, row in ipairs(result) do
              -- 1. Get the content of the very first line (index 0 to 1)
              local first_line = vim.api.nvim_buf_get_lines(ovr_buf, 0, 1, false)[1]

              --api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { '' .. ' ' .. typed_name .. ' [' .. selected_type .. '] ' .. '--ID:' .. db_id })
              local line_content = '  ' .. row.name .. ' [' .. row.type .. '] ' .. '--ID:' .. row.id

              -- 2. Check if the buffer is empty (line count is 1 and the line is empty)
              if vim.api.nvim_buf_line_count(ovr_buf) == 1 and first_line == "" then
                -- Replace the empty first line
                vim.api.nvim_buf_set_lines(ovr_buf, 0, 1, false, { line_content })
              else
                -- Append a new line at the very end
                vim.api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { line_content })
              end
            end
          end

          break
        end
      end
    elseif not success then
      print("Database Error: " .. tostring(err))
    end

    db:close()
  end

  api.nvim_buf_set_option(buf, 'modifiable', false)
end

-- New function to close the active DB tree and return to the saved list
M.disconnect_db = function()
  -- Only allow editing saved connections (not connected tree nodes)
  if not state.is_connected then
    print("You aren't connected to any database at the moment.")
    return
  end

  local ovr_win, ovr_buf = nil, nil
  for id, name in pairs(state.wins) do
      if name == 'overlay' then
          ovr_win = id
          ovr_buf = api.nvim_win_get_buf(id)
      end
  end

  if not ovr_buf then return end

  -- 1. Reset Connection States
  state.is_connected = false
  state.root_node_id = nil
  state.db_data = {} -- Clear the temporary schema data
  state.db_path = nil
  state.db_type = nil
    
  -- 2. Clean UI
  api.nvim_buf_set_option(ovr_buf, 'modifiable', true)
  api.nvim_buf_clear_namespace(ovr_buf, state.overlay_ns, 0, -1)
    
  -- 3. Re-render the initial list
  -- This will now fall back to your saved connection lines
  render_explorer_tree(ovr_buf)


  local path = './database.db'
  local f = io.open(path, 'r')

  if f then
    f:close()
    local db = require('sqlite.db'):open(path)
    local result = nil

    local success, err = pcall(function()
      result = db:eval("SELECT * from database") -- Replace 'db' with your actual database handler object
    end)

    if success then
      for id, name in pairs(state.wins) do
        if name == 'overlay' then
          local ovr_buf = vim.api.nvim_win_get_buf(id)
          api.nvim_buf_set_option(ovr_buf, 'buftype', 'nofile')
          api.nvim_buf_set_option(ovr_buf, 'modifiable', true)

          if result == true then
            break
          else
            for _, row in ipairs(result) do
              -- 1. Get the content of the very first line (index 0 to 1)
              local first_line = vim.api.nvim_buf_get_lines(ovr_buf, 0, 1, false)[1]

              --api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { '' .. ' ' .. typed_name .. ' [' .. selected_type .. '] ' .. '--ID:' .. db_id })
              local line_content = '  ' .. row.name .. ' [' .. row.type .. '] ' .. '--ID:' .. row.id

              -- 2. Check if the buffer is empty (line count is 1 and the line is empty)
              if vim.api.nvim_buf_line_count(ovr_buf) == 1 and first_line == "" then
                -- Replace the empty first line
                vim.api.nvim_buf_set_lines(ovr_buf, 0, 1, false, { line_content })
              else
                -- Append a new line at the very end
                vim.api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { line_content })
              end
            end
          end

          break
        end
      end
    elseif not success then
      print("Database Error: " .. tostring(err))
    end

    db:close()
  end
    
  api.nvim_buf_set_option(ovr_buf, 'modifiable', false)
end

-- Update your M.toggle_node function definition elsewhere in your script
M.toggle_node = function()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)

  api.nvim_buf_set_option(buf, 'modifiable', true)
  local cursor_row = api.nvim_win_get_cursor(win)[1]
  local line = api.nvim_buf_get_lines(buf, cursor_row - 1, cursor_row, false)[1]

  -- Use a pattern match to reliably extract the hidden ID suffix:
  local node_id = line:match '--ID:(%w+)' -- TODO: important line for later usage
  local node = line:match '(%w+)'
  local db_type = line:match '%[([^%]]+)%]'

  for _, word in ipairs(state.db_types) do
    if state.is_connected == false then
      if db_type == word then
        connect_db(buf, node_id)
        return
      end
    elseif state.is_connected == true then
      break        --        
    end
  end

  --if node and state.open_nodes[node] ~= nil then
  --  state.open_nodes[node] = not state.open_nodes[node]
  --  render_explorer_tree(buf) -- Re-render the explorer buffer
  --  -- Optional: Restore cursor position after redraw
  --  -- api.nvim_win_set_cursor(win, {cursor_row, 0})
  --end

  -- DYNAMIC FIX: If the node isn't in open_nodes yet, initialize it
  if node and state.db_data[node] then
    if state.open_nodes[node] == nil then
      state.open_nodes[node] = false
    end
    
    state.open_nodes[node] = not state.open_nodes[node]
    render_explorer_tree(buf)
  end

  api.nvim_buf_set_option(buf, 'modifiable', false)
end

local function update_ui_state()
  local exp_win, ovr_win, ovr_buf, q_ovr_buf, r_ovr_buf, ovr_scroll_buf, b_buf = nil, nil, nil, nil, nil, nil, nil
  for id, name in pairs(state.wins) do
    if name == 'explorer' then
      exp_win = id
    end
    if name == 'overlay' then
      ovr_win = id
      ovr_buf = api.nvim_win_get_buf(id)
    end
    if name == 'overlay_scroll' then
      ovr_scroll_buf = api.nvim_win_get_buf(id)
    end
    if name == 'query' then
      q_win = id
    end
    if name == 'q_overlay' then
      q_ovr_win = id
      q_ovr_buf = api.nvim_win_get_buf(id)
    end
    if name == 'results' then
      r_win = id
    end
    if name == 'r_overlay' then
      r_ovr_win = id
      r_ovr_buf = api.nvim_win_get_buf(id)
    end
    if name == 'bottom_bar' then
      b_win = id
      b_buf = api.nvim_win_get_buf(id)
    end
  end

  api.nvim_win_set_option(exp_win, 'number', false)
  api.nvim_win_set_option(exp_win, 'relativenumber', false)

  api.nvim_win_set_option(q_win, 'number', false)
  api.nvim_win_set_option(q_win, 'relativenumber', false)

  api.nvim_win_set_option(r_win, 'number', false)
  api.nvim_win_set_option(r_win, 'relativenumber', false)

  api.nvim_win_set_option(b_win, 'number', false)
  api.nvim_win_set_option(b_win, 'relativenumber', false)

  api.nvim_win_set_option(exp_win, 'cursorline', false)
  api.nvim_win_set_option(b_win, 'cursorline', false)

  local curr = api.nvim_get_current_win()
  if curr == exp_win and ovr_win then
    api.nvim_set_current_win(ovr_win)
    curr = ovr_win
  end
  if curr == q_win and q_ovr_win then
    api.nvim_set_current_win(q_ovr_win)
    curr = q_ovr_win
  end
  if curr == r_win and r_ovr_win then
    api.nvim_set_current_win(r_ovr_win)
    curr = r_ovr_win
  end

  local is_ovr_active = (curr == ovr_win)
  local is_q_ovr_active = (curr == q_ovr_win)
  local is_r_ovr_active = (curr == r_ovr_win)
  local is_insert = api.nvim_get_mode().mode == 'i'

  -- ─── Explorer / Overlay highlighting (ONE clear, everything in one block) ───
  if ovr_buf and api.nvim_buf_is_valid(ovr_buf) then
    api.nvim_buf_clear_namespace(ovr_buf, state.overlay_ns, 0, -1)

    if is_ovr_active then
      local cursor_row = api.nvim_win_get_cursor(ovr_win)[1]
      local cursor_line_0 = cursor_row - 1
      local lines_to_highlight = { [cursor_line_0] = true }
      local cursor_node_id = state.tree_line_map and state.tree_line_map[cursor_line_0]

      if cursor_node_id and not cursor_node_id:find('__empty__') then
        local function collect_child_lines(node_id)
          local node = state.db_data[node_id]

          if not node or not node.children then return end
          if not state.open_nodes[node_id] then
            -- Node is closed — but it still renders an (Empty) placeholder
            -- if its children list is empty. Collect that line too.
            if #node.children == 0 then
                for line_nr, nid in pairs(state.tree_line_map) do
                    if nid == node_id .. '__empty__' then
                        lines_to_highlight[line_nr] = true
                    end
                end
            end
            return
          end
        
          if #node.children == 0 then
            -- find the (Empty) line tied to this specific node
            for line_nr, nid in pairs(state.tree_line_map) do
              if nid == node_id .. '__empty__' then
                lines_to_highlight[line_nr] = true
              end
            end
            return
          end
        
          for _, child_id in ipairs(node.children) do
            for line_nr, nid in pairs(state.tree_line_map) do
              if nid == child_id then
                lines_to_highlight[line_nr] = true
                collect_child_lines(child_id)
                break
              end
            end
          end
        end
        collect_child_lines(cursor_node_id)
      end
    
      -- paint cursor line with full background + icon re-stamp + active text
      --api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerLineActiveBG', cursor_line_0, 0, -1)
    
      local text_start = 0
      for _, hl in ipairs(state.tree_highlights or {}) do
        if hl[1] == cursor_line_0 then
          api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, hl[4], hl[1], hl[2], hl[3])
          if hl[3] == -1 then text_start = hl[2] end
        end
      end
      local cursor_line_text = api.nvim_buf_get_lines(ovr_buf, cursor_line_0, cursor_line_0 + 1, false)[1] or ''
      api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerLineActive', cursor_line_0, text_start, #cursor_line_text)

      -- snap cursor to text start
      api.nvim_win_set_cursor(ovr_win, { cursor_row, text_start })
    
      -- paint child lines: connector fg only
      for line_nr, _ in pairs(lines_to_highlight) do
        if line_nr ~= cursor_line_0 then
          for _, hl in ipairs(state.tree_highlights or {}) do
            if hl[1] == line_nr then
              if hl[4] == 'ExplorerConnector' then
                if cursor_line_0 == 0 then
                  api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerConnectorActive', line_nr, hl[2], hl[3])
                  api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerConnectorActive', 1, hl[2], hl[3])
                else
                  api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerConnectorActive', line_nr, hl[2]+1, hl[3])
                end
              elseif hl[4] == 'ExplorerEmpty' then
                api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerEmpty', line_nr, hl[2], hl[3])
              end
            end
          end
        end
      end
    
      api.nvim_win_set_option(ovr_win, 'winhl', 'Normal:' .. state.hl_overlay_active)
    
      if b_buf then
        api.nvim_buf_set_lines(b_buf, 0, -1, false, {})
        connection_status = state.is_connected and ('Connected to ' .. state.db_type) or 'Not Connected'
        api.nvim_buf_set_lines(b_buf, 0, 1, false, { connection_status })
      
        local win_width  = api.nvim_win_get_width(b_win) - 2
        local left_text  = 'Connect: <enter> | New: ^n | Edit: ^e | Close: ^c | Delete: ^d | Exit: <esc>'
        local right_text = 'Help: ^? | Leader: <space>'
        local space_count = win_width - #left_text - #right_text - 1
      
        if space_count > 0 then
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. string.rep(' ', space_count) .. right_text })
        else
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. ' ' .. right_text })
        end
      end
    
    else
      api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, state.hl_first_line_text, 0, 4, -1)
      api.nvim_win_set_option(ovr_win, 'winhl', 'Normal:Normal')
    end
  end

  -- ─── Results: header protection + cell cursor ───────────────────────────────
  if curr == r_ovr_win then
    local cursor = api.nvim_win_get_cursor(r_ovr_win)
    local buf = api.nvim_win_get_buf(r_ovr_win)
    apply_table_highlights(buf, false)

    -- cursor[1] is 1-based, row_col_offsets is 1-based, so index directly
    local row_idx = cursor[1]
    local offsets = (state.row_col_offsets and state.row_col_offsets[row_idx])
                    or state.table_cols

    local col_idx = 1
    for i, offset in ipairs(offsets) do
      if cursor[2] >= offset then
        col_idx = i
      end
    end

    local start_col = offsets[col_idx]
    local next_offset = offsets[col_idx + 1] or -1

    api.nvim_win_set_cursor(r_ovr_win, { cursor[1], start_col })
    api.nvim_buf_add_highlight(buf, state.ns, state.hl_cell_cursor, cursor[1] - 1, start_col, next_offset)
  end

--  if curr == r_ovr_win then
--    local cursor = api.nvim_win_get_cursor(r_ovr_win)
--    if cursor[1] == 1 then
--      api.nvim_win_set_cursor(r_ovr_win, { 2, cursor[2] })
--      cursor = api.nvim_win_get_cursor(r_ovr_win)
--    end
--
--    local buf = api.nvim_win_get_buf(r_ovr_win)
--    apply_table_highlights(buf)
--
--    -- row_idx is 0-based into row_col_offsets (header is line 1, rows start line 2)
--    local row_idx = cursor[1] - 1  -- line 2 → index 1
--    local offsets = (state.row_col_offsets and state.row_col_offsets[row_idx])
--                    or state.table_cols
--
--    -- Find which column the cursor is in using this row's byte offsets
--    local col_idx = 1
--    for i, offset in ipairs(offsets) do
--      if cursor[2] >= offset then
--        col_idx = i
--      end
--    end
--
--    local start_col = offsets[col_idx]
--    local next_offset = offsets[col_idx + 1] or -1
--
--    -- Snap cursor to cell start
--    api.nvim_win_set_cursor(r_ovr_win, { cursor[1], start_col })
--    api.nvim_buf_add_highlight(buf, state.ns, state.hl_cell_cursor, cursor[1] - 1, start_col, next_offset)
--
----    local start_col = 0
----    for _, offset in ipairs(state.table_cols) do
----      if cursor[2] >= offset then
----        start_col = offset
----      end
----    end
----
----    local next_offset = -1
----    for _, offset in ipairs(state.table_cols) do
----      if offset > start_col then
----        next_offset = offset
----        break
----      end
----    end
----
----    api.nvim_buf_add_highlight(buf, state.ns, state.hl_cell_cursor, cursor[1] - 1, start_col, next_offset)
--  end

  -- ─── Borders & Titles ────────────────────────────────────────────────────────
  for win_id, name in pairs(state.wins) do
    if api.nvim_win_is_valid(win_id) and not name:find 'scroll' and name ~= 'overlay' and name ~= 'bottom_bar' then
      local active = (curr == win_id)
        or (name == 'explorer'  and is_ovr_active)
        or (name == 'query'     and is_q_ovr_active)
        or (name == 'results'   and is_r_ovr_active)
      local title_hl = active and 'FloatTitleActive' or 'FloatTitleInactive'

      api.nvim_win_set_option(
        win_id, 'winhl',
        'Normal:Normal,FloatBorder:' .. (active and state.hl_active_border or state.hl_inactive_border)
          .. ',FloatTitle:' .. title_hl
      )

      local title_text = ({ explorer = ' [e] Explorer ', query = ' [q] Query ', results = ' [r] Results ' })[name] or ''
      api.nvim_win_set_config(win_id, { title = title_text, title_pos = 'left' })
    end
  end

  -- ─── Query overlay ───────────────────────────────────────────────────────────
  if q_ovr_buf and api.nvim_buf_is_valid(q_ovr_buf) then
    api.nvim_buf_clear_namespace(q_ovr_buf, state.q_overlay_ns, 0, -1)
    if is_q_ovr_active then
      api.nvim_win_set_option(q_ovr_win, 'cursorline', true)
      if b_buf then
        local win_width   = api.nvim_win_get_width(b_win) - 2
        local mode_text   = is_insert and ' INSERT ' or ' NORMAL '
        local left_status = mode_text .. (state.is_connected and ' Connected to ' .. state.db_type or ' Not Connected')

        local formatted_time = os.date '[%H:%M:%S]'
        local right_status
        if state.last_query_status == '' then
          right_status = formatted_time
        else
          right_status = formatted_time .. ' ' .. state.last_query_status
        end

        local space_count = win_width - #left_status - #right_status - 1
        local full_line   = left_status .. string.rep(' ', space_count) .. right_status

        if space_count > 0 then
          api.nvim_buf_set_lines(b_buf, 0, 1, false, { full_line })
        else
          api.nvim_buf_set_lines(b_buf, 0, 1, false, { left_status .. ' ' .. right_status })
        end

        api.nvim_buf_add_highlight(b_buf, -1, (is_insert and state.hl_mode_insert or state.hl_mode_normal), 0, 0, #mode_text)

        if #right_status > 0 then
          local start_col = #full_line - #right_status
          api.nvim_buf_add_highlight(b_buf, -1, 'SoftOrangeKey', 0, start_col, -1)
        end

        local left_text = nil

        if is_insert then
          left_text  = 'Insert Mode: i | Execute: <enter> | AutoComplete: <tab> | Next: ^n | Previous: ^p | History: ^h | Exit: <esc>'
        else
          left_text  = 'Insert Mode: i | Execute: <enter> | History: ^h | Exit: <esc>'
        end

        local right_text = 'Help: ^? | Leader: <space>'
        local space_count2 = win_width - #left_text - #right_text - 1

        if space_count2 > 0 then
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. string.rep(' ', space_count2) .. right_text })
        else
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. ' ' .. right_text })
        end

        api.nvim_buf_add_highlight(b_buf, -1, (is_insert and state.hl_mode_insert or state.hl_mode_normal), 0, 0, #mode_text)
      end
    else
      api.nvim_win_set_option(q_ovr_win, 'cursorline', false)
    end
  end

  -- ─── Results overlay ─────────────────────────────────────────────────────────
  if r_ovr_buf and api.nvim_buf_is_valid(r_ovr_buf) then
    api.nvim_buf_clear_namespace(r_ovr_buf, state.r_overlay_ns, 0, -1)
    if is_r_ovr_active then
      if b_buf then
        api.nvim_buf_set_lines(b_buf, 0, -1, false, {})
        local win_width   = api.nvim_win_get_width(b_win) - 2

        local left_status = (state.is_connected and 'Connected to ' .. state.db_type or 'Not Connected')
        local formatted_time = os.date '[%H:%M:%S]'

        local right_status = ''
        if state.result_sets and #state.result_sets > 1 then
          right_status = formatted_time .. string.format(' Showing result of [%d/%d]', state.result_set_index, #state.result_sets)
        else
          right_status = formatted_time
        end

        local space_count = win_width - #left_status - #right_status - 1
        local full_line   = left_status .. string.rep(' ', space_count) .. right_status

        if space_count > 0 then
          api.nvim_buf_set_lines(b_buf, 0, 1, false, { full_line })
        else
          api.nvim_buf_set_lines(b_buf, 0, 1, false, { left_status .. ' ' .. right_status })
        end

        if #right_status > 0 then
          local start_col = #full_line - #right_status
          api.nvim_buf_add_highlight(b_buf, -1, 'SoftOrangeKey', 0, start_col, -1)
        end

        local win_width  = api.nvim_win_get_width(b_win) - 2

        --local left_text  = 'Exit: <esc>'
        local set_indicator = ''
        if state.result_sets and #state.result_sets > 1 then
          set_indicator = string.format(' | Press <tab> to change result table', state.result_set_index, #state.result_sets)
        end
        local left_text = 'Exit: <esc>' .. set_indicator

        local right_text = 'Help: ^? | Leader: <space>'
        local space_count = win_width - #left_text - #right_text - 1

        if space_count > 0 then
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. string.rep(' ', space_count) .. right_text })
        else
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. ' ' .. right_text })
        end
      end
    else
      api.nvim_buf_clear_namespace(r_ovr_buf, state.ns, 0, -1)
      apply_table_highlights(r_ovr_buf)
    end
  end

  -- ─── Scrollbar ───────────────────────────────────────────────────────────────
  if ovr_scroll_buf and ovr_win then
    api.nvim_buf_set_lines(ovr_scroll_buf, 0, -1, false, { get_h_scroll_indicator(ovr_win) })
  end

  -- Sync header scroll with results scroll
  for id, name in pairs(state.wins) do
    if name == 'r_header' and api.nvim_win_is_valid(id) then
      if r_ovr_win then
        local view = vim.api.nvim_win_call(r_ovr_win, function()
          return vim.fn.winsaveview()
        end)
        vim.api.nvim_win_call(id, function()
          vim.fn.winrestview({ leftcol = view.leftcol })
        end)
      end
    end
  end

  -- ─── Bottom bar key-hint highlights ─────────────────────────────────────────
  local ns = api.nvim_create_namespace 'my_dynamic_highlights'
  api.nvim_buf_clear_namespace(b_buf, ns, 0, -1)

  local lines = api.nvim_buf_get_lines(b_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local line_idx = i - 1

    local labels = { 'Connect:', 'New:', 'Edit:', 'Exit:', 'AutoComplete:', 'Next:', 'Previous:', 'Leader:', 'Refresh:', 'Help:', 'Delete:', 'Execute:', 'History:', 'Close:', 'Insert Mode:', 'Normal Mode:' }
    for _, word in ipairs(labels) do
      local s, e = line:find(word)
      if s then
        api.nvim_buf_add_highlight(b_buf, ns, 'SoftRedLabel', line_idx, s - 1, e)
      end
    end

    local orange_patterns = { '<enter>', ' ^n ', '<space>', '<tab>', ' ^? ', ' ^p ', ' ^e ', ' ^c ', ' ^d ', ' i ', ' ^h ', '<esc>' }
    for _, pat in ipairs(orange_patterns) do
      local s, e = line:find(pat)
      if s then
        api.nvim_buf_add_highlight(b_buf, ns, 'SoftOrangeKey', line_idx, s - 1, e)
      end
    end
  end
end

-- 4. Main Focus and Bottom Bar Handler
local function old_update_ui_state()
  local exp_win, ovr_win, ovr_buf, q_ovr_buf, r_ovr_buf, ovr_scroll_buf, b_buf = nil, nil, nil, nil, nil, nil, nil
  for id, name in pairs(state.wins) do
    if name == 'explorer' then
      exp_win = id
    end
    if name == 'overlay' then
      ovr_win = id
      ovr_buf = api.nvim_win_get_buf(id)
    end
    if name == 'overlay_scroll' then
      ovr_scroll_buf = api.nvim_win_get_buf(id)
    end
    if name == 'query' then
      q_win = id
    end
    if name == 'q_overlay' then
      q_ovr_win = id
      q_ovr_buf = api.nvim_win_get_buf(id)
    end
    if name == 'results' then
      r_win = id
    end
    if name == 'r_overlay' then
      r_ovr_win = id
      r_ovr_buf = api.nvim_win_get_buf(id)
    end
    if name == 'bottom_bar' then
      b_win = id
      b_buf = api.nvim_win_get_buf(id)
    end
  end

  api.nvim_win_set_option(exp_win, 'number', false)
  api.nvim_win_set_option(exp_win, 'relativenumber', false)

  api.nvim_win_set_option(q_win, 'number', false)
  api.nvim_win_set_option(q_win, 'relativenumber', false)

  --api.nvim_win_set_option(q_ovr_win, 'number', true)
  --api.nvim_win_set_option(q_ovr_win, 'relativenumber', true)

  api.nvim_win_set_option(r_win, 'number', false)
  api.nvim_win_set_option(r_win, 'relativenumber', false)

  api.nvim_win_set_option(b_win, 'number', false)
  api.nvim_win_set_option(b_win, 'relativenumber', false)

  api.nvim_win_set_option(exp_win, 'cursorline', false)
  api.nvim_win_set_option(b_win, 'cursorline', false)

  local curr = api.nvim_get_current_win()
  if curr == exp_win and ovr_win then
    api.nvim_set_current_win(ovr_win)
    curr = ovr_win
  end
  if curr == q_win and q_ovr_win then
    api.nvim_set_current_win(q_ovr_win)
    curr = q_ovr_win
  end
  if curr == r_win and r_ovr_win then
    api.nvim_set_current_win(r_ovr_win)
    curr = r_ovr_win
  end

  local is_ovr_active = (curr == ovr_win)
  local is_q_ovr_active = (curr == q_ovr_win)
  local is_r_ovr_active = (curr == r_ovr_win)
  local is_insert = api.nvim_get_mode().mode == 'i'

  -- DB tree highlighting logic
  if ovr_buf and api.nvim_buf_is_valid(ovr_buf) then
    -- CRITICAL: Clear previous highlights in the dedicated overlay_ns namespace
    api.nvim_buf_clear_namespace(ovr_buf, state.overlay_ns, 0, -1)

    local hl_group = 'ExplorerLineInactive' -- Default highlight

    if is_ovr_active then
      hl_group = 'ExplorerLineActive' -- Use active highlight if focused
      local cursor_row = api.nvim_win_get_cursor(ovr_win)[1]
      local line = api.nvim_buf_get_lines(ovr_buf, cursor_row - 1, cursor_row, false)[1] or ''

      -- Apply the active highlight to the exact line the cursor is on
      -- range: (buffer, ns, highlight_group, line_start_0_idx, col_start, col_end)
      api.nvim_buf_add_highlight(
        ovr_buf,
        state.overlay_ns,
        'ExplorerLineActive',
        cursor_row - 1, -- Neovim API uses 0-based index
        0, -- Start from column 0
        -1 -- Go to the end of the line
      )
      --- here
    end

    -- Re-apply the specific 'first line text' highlight over the active line highlight if needed
    api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, state.hl_first_line_text, 0, 4, -1)
  end

  -- Header Disable Logic -- FIXME: not working
  if curr == r_ovr_win then
    local cursor = api.nvim_win_get_cursor(r_ovr_win)

    -- PROTECTION: Force cursor to line 2 if it tries to land on the header (line 1)
    if cursor[1] == 1 then
      api.nvim_win_set_cursor(r_ovr_win, { 2, cursor[2] })
      cursor = api.nvim_win_get_cursor(r_ovr_win) -- Update local cursor variable for next steps
    end

    -- Apply highlights for the table and the active cell
    local buf = api.nvim_win_get_buf(r_ovr_win)
    apply_table_highlights(buf)

    local start_col = 0
    for i, offset in ipairs(state.table_cols) do
      if cursor[2] >= offset then
        start_col = offset
      end
    end

    local next_offset = -1
    for _, offset in ipairs(state.table_cols) do
      if offset > start_col then
        next_offset = offset
        break
      end
    end

    api.nvim_buf_add_highlight(buf, state.ns, state.hl_cell_cursor, cursor[1] - 1, start_col, next_offset)
  end

  -- Highlights: Borders & Titles
  for win_id, name in pairs(state.wins) do
    if api.nvim_win_is_valid(win_id) and not name:find 'scroll' and name ~= 'overlay' and name ~= 'bottom_bar' then
      local active = (curr == win_id)
        or (name == 'explorer' and is_ovr_active)
        or (name == 'query' and is_q_ovr_active)
        or (name == 'results' and is_r_ovr_active)
      local title_hl = active and 'FloatTitleActive' or 'FloatTitleInactive'

      --api.nvim_win_set_option(win_id, 'winhl', 'Normal:Normal,FloatBorder:' .. border_hl .. ',FloatTitle:' .. title_hl)
      api.nvim_win_set_option(
        win_id,
        'winhl',
        'Normal:Normal,FloatBorder:' .. (active and state.hl_active_border or state.hl_inactive_border) .. ',FloatTitle:' .. title_hl
      )

      local title_text = ({ explorer = ' [e] Explorer ', query = ' [q] Query ', results = ' [r] Results ' })[name] or ''
      api.nvim_win_set_config(win_id, { title = title_text, title_pos = 'left' })
    end
  end

  -- Highlights: Overlay First Line
  if ovr_buf and api.nvim_buf_is_valid(ovr_buf) then
    api.nvim_buf_clear_namespace(ovr_buf, state.overlay_ns, 0, -1)
    if is_ovr_active then
      if state.is_connected == true then
        api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, state.hl_first_line_text, 0, 4, -1) -- this is for highlighting the first line only
      else
        -- 1. Get the total number of lines in the buffer
        local line_count = api.nvim_buf_line_count(ovr_buf)

        -- 2. Loop through each line (0-indexed)
        for i = 0, line_count - 1 do
          api.nvim_buf_add_highlight(
            ovr_buf, 
            state.overlay_ns, 
            state.hl_first_line_text, 
            i,    -- current line index
            5,    -- start column  
            -1    -- end column (highlights to the end of the line)
          )
        end
      end
      
      api.nvim_win_set_option(ovr_win, 'winhl', 'Normal:' .. state.hl_overlay_active)
      if b_buf then
        api.nvim_buf_set_lines(b_buf, 0, -1, false, {})

        if state.is_connected == true then
          connection_status = 'Connected to ' .. state.db_type
        elseif state.is_connected == false then
          connection_status = 'Not Connected'
        end

        api.nvim_buf_set_lines(b_buf, 0, 1, false, { connection_status })
        --api.nvim_buf_set_lines(b_buf, 1, 2, false, { 'Connect: <enter> | New: n | Edit: e | Delete: d | Refresh: f | Close: <esc> (in normal mode)' })

        -- 1. Get window width
        local win_width = api.nvim_win_get_width(b_win) - 2

        -- 2. Your existing text
        local left_text = 'Connect: <enter> | New: ^n | Edit: ^e | Close: ^c | Delete: ^d | Exit: <esc>'
        local right_text = 'Help: ^? | Leader: <space>'

        -- 3. Calculate spaces needed
        -- We subtract 1 or 2 to account for the sign column/edge
        local space_count = win_width - #left_text - #right_text - 1

        if space_count > 0 then
          local full_line = left_text .. string.rep(' ', space_count) .. right_text
          -- 4. Set the line
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { full_line })
        else
          -- If window is too small, just put one space
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. ' ' .. right_text })
        end
      end
    else
      api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, state.hl_first_line_text, 0, 4, -1) -- comment this line if you want to dimm the text when inactive
      api.nvim_win_set_option(ovr_win, 'winhl', 'Normal:Normal')
    end
  end

  if q_ovr_buf and api.nvim_buf_is_valid(q_ovr_buf) then
    api.nvim_buf_clear_namespace(q_ovr_buf, state.q_overlay_ns, 0, -1)
    if is_q_ovr_active then
      api.nvim_win_set_option(q_ovr_win, 'cursorline', true)
      if b_buf then
        if state.is_connected == true then
          connection_status = ' Connected to ' .. state.db_type
        elseif state.is_connected == false then
          connection_status = ' Not Connected'
        end

        local win_width = api.nvim_win_get_width(b_win) - 2
        local mode_text = is_insert and ' INSERT ' or ' NORMAL '
        --local status_msg = state.last_query_status ~= '' and (' | ' .. state.last_query_status) or ''

        -- Left side content
        local left_status = mode_text .. (state.is_connected and ' Connected to ' .. state.db_type or ' Not Connected')
        -- Right side content (The Query Result)
        local formatted_time = os.date '[%H:%M:%S]'
        local right_status -- Declare it here first

        if state.last_query_status == '' then
          right_status = formatted_time
        else
          right_status = formatted_time .. ' ' .. state.last_query_status
        end

        -- Set the full status line
        -- api.nvim_buf_set_lines(b_buf, 0, 1, false, { mode_text .. connection_status .. status_msg })
        --api.nvim_buf_set_lines(b_buf, 1, 2, false, { 'Insert Mode: i | Normal Mode: <esc> | Execute: <enter> | History: h | Close: <esc> (in normal mode)' })

        -- Calculate padding
        local space_count = win_width - #left_status - #right_status - 1
        --local full_first_line = left_status .. string.rep(' ', math.max(1, space_count)) .. right_status
        local full_line = left_status .. string.rep(' ', space_count) .. right_status

        if space_count > 0 then
          -- Set the line
          api.nvim_buf_set_lines(b_buf, 0, 1, false, { full_line })
        else
          -- If window is too small, just put one space
          api.nvim_buf_set_lines(b_buf, 0, 1, false, { left_status .. ' ' .. right_status })
        end

        -- HIGHLIGHTS
        -- 1. Mode Highlight (Normal/Insert)
        api.nvim_buf_add_highlight(b_buf, -1, (is_insert and state.hl_mode_insert or state.hl_mode_normal), 0, 0, #mode_text)

        -- 2. Query Message Highlight (Soft Orange if exists)
        if #right_status > 0 then
          local start_col = #full_line - #right_status
          api.nvim_buf_add_highlight(b_buf, -1, 'SoftOrangeKey', 0, start_col, -1)
        end

        ---- Add a highlight for the status message specifically (Soft Orange or Green)
        --if state.last_query_status ~= '' then
        --  local start_col = #(mode_text .. connection_status .. ' | ')
        --  api.nvim_buf_add_highlight(b_buf, -1, 'SoftOrangeKey', 0, start_col, -1)
        --end

        -- 1. Get window width
        local win_width = api.nvim_win_get_width(b_win) - 2

        -- 2. Your existing text
        local left_text = 'Insert Mode: i | Execute: <enter> | Accept: <tab> | Next: ^n | Previous: ^p | History: ^h | Exit: <esc>'
        local right_text = 'Help: ^? | Leader: <space>'

        -- 3. Calculate spaces needed
        -- We subtract 1 or 2 to account for the sign column/edge
        local space_count = win_width - #left_text - #right_text - 1

        if space_count > 0 then
          local full_line = left_text .. string.rep(' ', space_count) .. right_text
          -- 4. Set the line
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { full_line })
        else
          -- If window is too small, just put one space
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. ' ' .. right_text })
        end

        api.nvim_buf_add_highlight(b_buf, -1, (is_insert and state.hl_mode_insert or state.hl_mode_normal), 0, 0, #mode_text)
      end
    else
      api.nvim_win_set_option(q_ovr_win, 'cursorline', false)
    end
  end

  if r_ovr_buf and api.nvim_buf_is_valid(r_ovr_buf) then
    api.nvim_buf_clear_namespace(r_ovr_buf, state.r_overlay_ns, 0, -1)
    if is_r_ovr_active then
      if b_buf then
        api.nvim_buf_set_lines(b_buf, 0, -1, false, {})

        if state.is_connected == true then
          connection_status = 'Connected to ' .. state.db_type
        elseif state.is_connected == false then
          connection_status = 'Not Connected'
        end

        api.nvim_buf_set_lines(b_buf, 0, 1, false, { connection_status })

        -- 1. Get window width
        local win_width = api.nvim_win_get_width(b_win) - 2

        -- 2. Your existing text
        local left_text = 'Exit: <esc>'
        local right_text = 'Help: ^? | Leader: <space>'

        -- 3. Calculate spaces needed
        -- We subtract 1 or 2 to account for the sign column/edge
        local space_count = win_width - #left_text - #right_text - 1

        if space_count > 0 then
          local full_line = left_text .. string.rep(' ', space_count) .. right_text
          -- 4. Set the line
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { full_line })
        else
          -- If window is too small, just put one space
          api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. ' ' .. right_text })
        end
      end

      -- api.nvim_win_set_option(r_ovr_win, 'winhl', 'Normal:' .. state.hl_overlay_active)
      -- else
      -- api.nvim_win_set_option(r_ovr_win, 'winhl', 'Normal:' .. state.hl_overlay_active)
    else
      -- CRITICAL FIX: Clear the cell cursor highlights when the window is inactive
      api.nvim_buf_clear_namespace(r_ovr_buf, state.ns, 0, -1)
      -- You might need to re-apply the basic row highlighting if that's in state.ns
      apply_table_highlights(r_ovr_buf)
    end
  end

  -- Update Scrollbar & Bottom Bar
  if ovr_scroll_buf and ovr_win then
    api.nvim_buf_set_lines(ovr_scroll_buf, 0, -1, false, { get_h_scroll_indicator(ovr_win) })
  end

  -- bottom buffer text highlighting
  local ns = api.nvim_create_namespace 'my_dynamic_highlights'

  -- Clear previous highlights in this namespace
  api.nvim_buf_clear_namespace(b_buf, ns, 0, -1)

  local lines = api.nvim_buf_get_lines(b_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local line_idx = i - 1

    -- Patterns to match: Label (Soft Red)
    local labels = { 'Connect:', 'New:', 'Edit:', 'Exit:', 'Accept:', 'Next:', 'Previous:', 'Leader:', 'Refresh:', 'Help:', 'Delete:', 'Execute:', 'History:', 'Close:', 'Insert Mode:', 'Normal Mode:' }
    for _, word in ipairs(labels) do
      local s, e = line:find(word)
      if s then
        api.nvim_buf_add_highlight(b_buf, ns, 'SoftRedLabel', line_idx, s - 1, e)
      end
    end

    -- Patterns to match: Keys (Soft Orange)
    -- Uses lua patterns to find <...> or single letters after a colon
    local orange_patterns = { '<enter>', ' ^n ', '<space>', '<tab>', ' ^? ', ' ^p ', ' ^e ', ' ^c ', ' ^d ', ' i ', ' ^h ', '<esc>' }
    for _, pat in ipairs(orange_patterns) do
      local s, e = line:find(pat)
      if s then
        -- Adjust start/end if you included spaces in the pattern to match precisely
        api.nvim_buf_add_highlight(b_buf, ns, 'SoftOrangeKey', line_idx, s - 1, e)
      end
    end
  end
end

local function move_cell(dir)
  local win = api.nvim_get_current_win()
  local cursor = api.nvim_win_get_cursor(win)

  local row_idx = cursor[1]  -- was cursor[1] - 1, now direct
  local offsets = (state.row_col_offsets and state.row_col_offsets[row_idx])
                  or state.table_cols

  local col_idx = 1
  for i, offset in ipairs(offsets) do
    if cursor[2] >= offset then
      col_idx = i
    end
  end

  local next_idx = math.max(1, math.min(#offsets, col_idx + dir))
  api.nvim_win_set_cursor(win, { cursor[1], offsets[next_idx] })

  --vim.api.nvim_win_call(win, function()
  --  local view = vim.fn.winsaveview()
  --  local win_width = api.nvim_win_get_width(win)
  --  local cursor_col = offsets[next_idx]
  --  local cell_end = offsets[next_idx + 1] or (cursor_col + 10)
  --  local leftcol = view.leftcol
--
  --  if dir > 0 then
  --    if cell_end > leftcol + win_width then
  --      view.leftcol = cell_end - win_width
  --      vim.fn.winrestview(view)
  --    end
  --  else
  --    if cursor_col < leftcol then
  --      view.leftcol = cursor_col
  --      vim.fn.winrestview(view)
  --    end
  --  end
  --end)

  vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      local win_width = api.nvim_win_get_width(win)
      local cursor_col = offsets[next_idx]

      -- get actual end of cell: next col start, or end of line
      local cell_end
      if offsets[next_idx + 1] then
        cell_end = offsets[next_idx + 1]
      else
        -- last cell: use actual line byte length
        local line = api.nvim_buf_get_lines(
          api.nvim_win_get_buf(win),
          cursor[1] - 1,
          cursor[1],
          false
        )[1] or ''
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

  update_ui_state()
end

local function oldv2_move_cell(dir)
  local win = api.nvim_get_current_win()
  local cursor = api.nvim_win_get_cursor(win)

  local row_idx = cursor[1] - 1
  local offsets = (state.row_col_offsets and state.row_col_offsets[row_idx])
                    or state.table_cols

  local col_idx = 1
  for i, offset in ipairs(offsets) do
    if cursor[2] >= offset then
      col_idx = i
    end
  end

  local next_idx = math.max(1, math.min(#offsets, col_idx + dir))
  api.nvim_win_set_cursor(win, { cursor[1], offsets[next_idx] })

  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    local win_width = api.nvim_win_get_width(win)
    local cursor_col = offsets[next_idx]
    -- get the end of this cell
    local cell_end = offsets[next_idx + 1] or (cursor_col + 10)
    local leftcol = view.leftcol

    if dir > 0 then
      -- scroll so the full cell is visible on the right
      if cell_end > leftcol + win_width then
        view.leftcol = cell_end - win_width
        vim.fn.winrestview(view)
      end
    else
      -- scroll so the full cell is visible on the left
      if cursor_col < leftcol then
        view.leftcol = cursor_col
        vim.fn.winrestview(view)
      end
    end
  end)
  
  update_ui_state()
end

local function execute_query()
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
    render_results_table(r_ovr_buf, { headers = { 'Error' }, rows = { { 'No query entered' } } })
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
      -- Has rows — extract headers from first row keys
      local headers = {}
      for k in pairs(result[1]) do table.insert(headers, k) end
      table.sort(headers) -- stable column order
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
  render_results_table(r_ovr_buf, state.result_sets[1])

  -- Build status: "Executed N statements in X ms"
  local stmt_word = #statements == 1 and '1 statement' or (#statements .. ' statements')
  state.last_query_status = string.format(
    'Executed %s in %.2fms', stmt_word, total_ms
  )

  update_ui_state()
end

local function old_execute_query()
  local q_ovr_win = nil
  local r_ovr_buf = nil

  -- Find the Query Overlay and Results Overlay
  for id, name in pairs(state.wins) do
    if name == 'q_overlay' then
      q_ovr_win = id
    end
    if name == 'r_overlay' then
      r_ovr_buf = api.nvim_win_get_buf(id)
    end
  end

  if not q_ovr_win or not r_ovr_buf then
    return
  end

  -- 1. Get the SQL query from the buffer
  local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(q_ovr_win), 0, -1, false)
  local sql = table.concat(lines, ' '):gsub('%s+', ' ') -- Flatten to one line

  if sql == '' or sql == ' ' then
    local headers = { 'Error' }
    local rows = { { 'No query entered' } }
    render_results_table(r_ovr_buf, { headers = headers, rows = rows })

    --print 'No query entered.'
    return
  end

  local elapsed_milliseconds = nil

  -- 2. Execute using sqlite.lua
  -- Ensure you have an active 'db' connection object stored in your state
  local success, result = pcall(function()
    local path = state.db_path
    return require('sqlite.db').with_open(path, function(conn)
      -- Record the start time using os.clock()
      local start_time = os.clock()

      -- ** Code to be benchmarked goes here **
      local result = conn:eval(sql)
      -- ** End of code to be benchmarked **

      -- Record the end time
      local end_time = os.clock()

      -- Calculate the elapsed time in seconds
      local elapsed_seconds = end_time - start_time

      -- Convert the time to milliseconds for display
      -- Multiply by 1000 and use string.format to round to two decimal places
      elapsed_milliseconds = elapsed_seconds * 1000

      return result
    end)
  end)

  if not success then
    local err_msg = tostring(result)

    -- Extract just the SQL error part after the last colon+space
    local clean_err = err_msg:match ':%s*(.+)$'
    -- Or if you want everything after "sql error:"
    local clean_err = err_msg:match '[Ee]rr[or]*:%s*(.+)$'

    --print('SQL Error: ' .. (clean_err or err_msg))
    --return
    --state.last_query_status = 'Error: ' .. tostring(result):sub(1, 30) -- Keep it short

    local headers = { 'Error' }
    local rows = { { 'SQL Error: ' .. clean_err or err_msg } }
    render_results_table(r_ovr_buf, { headers = headers, rows = rows })
  else
    -- 3. Format the result for the table renderer
    if type(result) == 'table' and #result > 0 then
      local headers = {}
      for k, _ in pairs(result[1]) do
        table.insert(headers, k)
      end

      local rows = {}
      for _, row_data in ipairs(result) do
        local row = {}
        for _, header in ipairs(headers) do
          table.insert(row, tostring(row_data[header] or 'NULL'))
        end
        table.insert(rows, row)
      end

      render_results_table(r_ovr_buf, { headers = headers, rows = rows })
      --print('Query executed: ' .. #result .. ' rows returned.')
      state.last_query_status = 'Query executed: ' .. #result .. ' rows returned in ' .. string.format('%.2f', elapsed_milliseconds) .. ' ms'
    else
      -- Handle non-select queries (INSERT/UPDATE/DELETE)
      render_results_table(r_ovr_buf, { headers = { 'Status' }, rows = { { 'Success' } } })
      --print 'Query executed successfully.'
      state.last_query_status = 'Query executed successfully (took' .. string.format('%.2f', elapsed_milliseconds) .. ' ms)'
    end
  end

  update_ui_state()
end

M.close_all_windows = function()
  pcall(api.nvim_del_augroup_by_name, 'DbViewEvents')
  suggest_close()

  for id, _ in pairs(state.wins) do
    if api.nvim_win_is_valid(id) then
      api.nvim_win_close(id, true)
    end
  end

  if state.parent_win_id and api.nvim_win_is_valid(state.parent_win_id) then
    api.nvim_win_close(state.parent_win_id, true)
  end

  state.wins = {}
  state.db_data = {}
  state.is_connected = false
end

local function switch_to_win(target)
  for id, name in pairs(state.wins) do
    if name == target and api.nvim_win_is_valid(id) then
      api.nvim_set_current_win(id)
      return
    end
  end
end

M.open_db_float = function()
  -- Use this line instead
  --local db = require 'sqlite.db'

  -- Now 'db' should not be nil, and db:open will work:
  --local conn, err = db:open '/home/yuito/Blue Book/database.db'

  --local path = '/home/yuito/Blue Book/database.db'
  --local f = io.open(path, 'r')

  --if f then
  --  f:close()
  --  local db = require('sqlite.db'):open(path)

  -- Use 'conn' for operations
  --  local schema = db:eval [[
  --    SELECT name, type FROM sqlite_schema
  --    WHERE type IN ('table', 'view', 'trigger') AND name NOT LIKE 'sqlite_%'
  --    ORDER BY type, name;
  --  ]]

  --  print(vim.inspect(schema))
  --  db:close()

  --  local users = db.with_open('/home/yuito/Blue Book/database.db', function(conn)
  -- 'conn' is valid ONLY inside this function block
  --    local result = conn:eval 'SELECT * FROM users'
  --    return result
  --  end)

  --  print(vim.inspect(users))

  -- Example of iterating through the users table:
  --for _, user_row in ipairs(users) do
  --  print('User Email: ' .. user_row.email .. ', Name: ' .. user_row.name)
  --end
  --else
  --  print('Error: Database file not found at ' .. path)
  --  return
  --end

  setup_highlight_groups()
  local ui = api.nvim_list_uis()[1]
  local w, h = math.floor(ui.width * 1), math.floor(ui.height * 0.9)
  local c, r = math.floor((ui.width - w) / 2) - 1, math.floor((ui.height - h) / 2) - 2

  local main_buf = api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(main_buf, 'bufhidden', 'wipe') -- Auto-delete buffer on close
  local main_window = api.nvim_open_win(main_buf, true, { relative = 'editor', width = w, height = h, col = c, row = r, style = 'minimal', border = 'none' })

  state.parent_win_id = main_window

  local bottom_h, exp_w = 2, math.floor(w * 0.25)
  local main_h = h - bottom_h - 2
  local q_w = (w - exp_w) - 4

  -- Explorer
  local exp_win = api.nvim_open_win(
    api.nvim_create_buf(false, true),
    true,
    { relative = 'win', win = state.parent_win_id, width = exp_w, height = main_h, col = 0, row = 0, border = 'rounded' }
  )
  state.wins[exp_win] = 'explorer'
  local ovr_buf = api.nvim_create_buf(false, true)
  local ovr_win = api.nvim_open_win(
    ovr_buf,
    false,
    { relative = 'win', win = exp_win, width = exp_w - 4, height = main_h - 2, col = 2, row = 2 - 1, style = 'minimal', border = 'none', zindex = 110 }
  )
  state.wins[ovr_win] = 'overlay'
  --api.nvim_buf_set_lines(ovr_buf, 0, -1, false, { "⌘ * DATABASE: sqlite:///./app.db", "⌘ Path: .../long_path_scrolling_test_string_1234567890" })
  api.nvim_win_set_option(ovr_win, 'wrap', false)
  state.wins[api.nvim_open_win(api.nvim_create_buf(false, true), false, {
    relative = 'win',
    win = ovr_win,
    width = exp_w - 4,
    height = 1,
    col = 0,
    row = main_h - 3,
    style = 'minimal',
    border = 'none',
    focusable = false,
    zindex = 120,
  })] =
    'overlay_scroll'

  -- Initially only show the DB name, closed
  state.open_nodes = { ['MyLocalDB'] = false }

  -- Call the new render function instead of setting lines manually
  render_explorer_tree(ovr_buf)

  -- Query Editor
  local q_buf = api.nvim_create_buf(false, true)
  local q_win = api.nvim_open_win(
    q_buf,
    false,
    { relative = 'win', win = state.parent_win_id, width = q_w, height = math.floor(main_h * 0.6) - 3, col = exp_w + 2, row = 0, border = 'rounded' }
  )
  state.wins[q_win] = 'query'

  local q_ovr_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(q_ovr_buf, 'filetype', 'sql')
  local q_ovr_win = api.nvim_open_win(q_ovr_buf, false, {
    relative = 'win',
    win = q_win,
    width = q_w - 4,
    height = math.floor(main_h * 0.6) - 5,
    col = 2,
    row = 1,
    style = 'minimal',
    border = 'none',
    zindex = 110,
  })
  state.wins[q_ovr_win] = 'q_overlay'
  api.nvim_buf_set_option(q_ovr_buf, 'buftype', 'nofile')

  --api.nvim_win_set_option(q_ovr_win, 'number', true) -- FIXME: bug the numberings are getting reversed
  --api.nvim_win_set_option(q_ovr_win, 'relativenumber', true)

  api.nvim_win_set_option(q_win, 'cursorline', false)
  api.nvim_win_set_option(q_ovr_win, 'cursorline', false)

  -- Results & Bottom Bar
  local r_buf = api.nvim_create_buf(false, true)
  local r_win = api.nvim_open_win(r_buf, false, {
    relative = 'win',
    win = state.parent_win_id,
    width = q_w,
    height = main_h - math.floor(main_h * 0.6) + 1,
    col = exp_w + 2,
    row = math.floor(main_h * 0.6) - 1,
    style = 'minimal',
    border = 'rounded',
  })
  state.wins[r_win] = 'results'

  local r_ovr_buf = api.nvim_create_buf(false, true)
  local r_ovr_win = api.nvim_open_win(r_ovr_buf, false, {
    relative = 'win',
    win = r_win,
    width = q_w - 4,
    height = math.floor(main_h * 0.6) - 7,  -- was -6, now -7
    col = 2,
    row = 2,                                  -- was 1, now 2
    style = 'minimal',
    border = 'none',
    zindex = 110,
  })
  state.wins[r_ovr_win] = 'r_overlay'

  local r_header_buf = api.nvim_create_buf(false, true)
  local r_header_win = api.nvim_open_win(r_header_buf, false, {
    relative = 'win',
    win = r_win,
    width = q_w - 4,
    height = 1,
    col = 2,
    row = 1,          -- sits at the top of r_win
    style = 'minimal',
    border = 'none',
    zindex = 115,     -- above r_ovr_win
    focusable = false,
  })
  state.wins[r_header_win] = 'r_header'
  api.nvim_win_set_option(r_header_win, 'wrap', false)

  api.nvim_win_set_option(r_ovr_win, 'wrap', false)
  api.nvim_win_set_option(r_ovr_win, 'sidescrolloff', 3)
  api.nvim_win_set_option(r_ovr_win, 'sidescroll', 1)

  render_results_table(r_ovr_buf, {
    headers = { 'ID', 'USERNAME', 'EMAIL', 'STATUS' },
    rows = {
      { '1', 'alice', 'alice@gmail.com', 'ACTIVE' },
      { '2', 'bob', 'bob@yahoo.com', 'INACTIVE' },
      {
        '3',
        'dev',
        'dev@nhl.edu.uk',
        'ACTIVE',
      },
    },
  })

  local path = './database.db'
  local f = io.open(path, 'r')

  if f then
    f:close()
    local db = require('sqlite.db'):open(path)
    local result = nil

    local success, err = pcall(function()
      result = db:eval("SELECT * from database") -- Replace 'db' with your actual database handler object
    end)

    if success then
      for id, name in pairs(state.wins) do
        if name == 'overlay' then
          local ovr_buf = vim.api.nvim_win_get_buf(id)
          api.nvim_buf_set_option(ovr_buf, 'buftype', 'nofile')
          api.nvim_buf_set_option(ovr_buf, 'modifiable', true)

          if result == true then
            break
          else
            for _, row in ipairs(result) do
              -- 1. Get the content of the very first line (index 0 to 1)
              local first_line = vim.api.nvim_buf_get_lines(ovr_buf, 0, 1, false)[1]

              --api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { '' .. ' ' .. typed_name .. ' [' .. selected_type .. '] ' .. '--ID:' .. db_id })
              local line_content = '  ' .. row.name .. ' [' .. row.type .. '] ' .. '--ID:' .. row.id

              -- 2. Check if the buffer is empty (line count is 1 and the line is empty)
              if vim.api.nvim_buf_line_count(ovr_buf) == 1 and first_line == "" then
                -- Replace the empty first line
                vim.api.nvim_buf_set_lines(ovr_buf, 0, 1, false, { line_content })
              else
                -- Append a new line at the very end
                vim.api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { line_content })
              end
            end
          end

          break
        end
      end
    elseif not success then
      print("Database Error: " .. tostring(err))
    end

    db:close()
  end
  api.nvim_buf_set_option(ovr_buf, 'modifiable', false)

  api.nvim_win_set_option(r_win, 'cursorline', false)
  api.nvim_win_set_option(r_ovr_win, 'cursorline', false)

  state.wins[api.nvim_open_win(
    api.nvim_create_buf(false, true),
    false,
    { relative = 'win', win = state.parent_win_id, width = w - 2, height = bottom_h, col = 0, row = h - bottom_h, border = 'rounded' }
  )] =
    'bottom_bar'

  -- Events
  api.nvim_create_augroup('DbViewEvents', { clear = true })
  api.nvim_create_autocmd({ 'WinEnter', 'CursorMoved', 'ModeChanged', 'InsertEnter', 'WinScrolled' }, { group = 'DbViewEvents', callback = update_ui_state })
  
  api.nvim_create_autocmd('TextChangedI', {
    group = 'DbViewEvents',
    buffer = q_ovr_buf,          -- only fire for the query buffer, not globally
    callback = function()
      suggest_update(q_ovr_win)
    end,
  })

  -- close suggestions when leaving insert mode
  api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave' }, {
    group  = 'DbViewEvents',
    buffer = q_ovr_buf,
    callback = function()
      suggest_close()
    end,
  })
  --api.nvim_create_autocmd('WinEnter', { group='DbViewEvents', callback=function() if api.nvim_get_current_win() == q_win then vim.cmd('startinsert') end end })

  -- Cell Navigation Maps
  for _, k in ipairs { 'h', 'l', '<Left>', '<Right>' } do
    vim.keymap.set('n', k, function()
      move_cell(k == 'h' or k == '<Left>' and -1 or 1)
    end, { buffer = r_ovr_buf })
  end

  -- Keymaps
  for id, name in pairs(state.wins) do
    if not name:find 'scroll' and name ~= 'bottom_bar' then
      local b = api.nvim_win_get_buf(id)
      vim.keymap.set('n', 'e', function()
        switch_to_win 'overlay'
      end, { buffer = b })
      vim.keymap.set('n', 'q', function()
        switch_to_win 'query'
      end, { buffer = b })
      vim.keymap.set('n', 'r', function()
        switch_to_win 'results'
      end, { buffer = b })
      if name == 'overlay' then
        vim.keymap.set('n', '<C-n>', function()
          render_connection_ui()
        end, { buffer = b, noremap = true, silent = true })

        vim.keymap.set('n', '<C-e>', function()
          M.edit_db()
        end, { buffer = b, noremap = true, silent = true, desc = 'Edit selected DB connection' })
      end
      vim.keymap.set('n', '<C-c>', function()
        M.disconnect_db()
      end, { buffer = ovr_buf, desc = "Close DB Tree and return to list" })
      vim.keymap.set('n', '<C-d>', function()
        M.delete_db()
      end, { buffer = ovr_buf, desc = "Delete DB Connection and return to list" })
      vim.keymap.set('n', '<Esc>', M.close_all_windows, { buffer = b })
      if name == 'overlay' then
        map(ovr_buf, 'n', '<CR>', [[<cmd>lua require'db.ui'.toggle_node()<CR>]])
      end
      if name == 'query' then
        vim.keymap.set('i', '<Tab>', function()
          local confirmed = suggest_confirm(q_ovr_win)
          if not confirmed then
            api.nvim_feedkeys(
              api.nvim_replace_termcodes('<Tab>', true, false, true),
              'n', false
            )
          end
        end, { buffer = q_ovr_buf })        -- ← q_ovr_buf, not b
      
        vim.keymap.set('i', '<C-n>', function()
          suggest_move(1)
        end, { buffer = q_ovr_buf })        -- ← q_ovr_buf, not b
      
        vim.keymap.set('i', '<C-p>', function()
          suggest_move(-1)
        end, { buffer = q_ovr_buf })        -- ← q_ovr_buf, not b
      
        vim.keymap.set('i', '<Esc>', function()
          if suggest_is_open() then
            suggest_close()
            vim.cmd 'stopinsert'
          else
            vim.cmd 'stopinsert'
          end
        end, { buffer = q_ovr_buf })        -- ← q_ovr_buf, not b
      end
      if name == 'q_overlay' then
        -- Execute query on Enter in Normal mode
        vim.keymap.set('n', '<CR>', execute_query, { buffer = b, desc = 'Execute SQL Query' })
      end

      -- Cycle through multiple result sets with Tab
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
          render_results_table(r_ovr_buf_local, state.result_sets[state.result_set_index])
        end
        update_ui_state()
      end, { buffer = r_ovr_buf })
    end
  end
  update_ui_state()
end

return M
