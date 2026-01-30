local api = vim.api
local M = {}

local state = {
  wins = {},
  parent_win_id = nil,
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
  -- DB states
  open_nodes = { ['MyLocalDB'] = true, ['Tables'] = true, ['users'] = true }, -- Track state
  is_connected = false,
  db_type = nil,
  db_types = { "SQLite", "PostgreSQL", "MySQL", "OracleDB", "MongoDB", "MariaDB" },
  icons = {
    db = '⌘',
    folder_open = '',
    folder_closed = '',
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
    local hex_string = string.format("%x", scaled_time_int)

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
  api.nvim_set_hl(0, 'ExplorerLineActive', { fg = '#F1FA8C', bg = '#44475A', bold = true }) -- Active line text color
  api.nvim_set_hl(0, 'ExplorerLineInactive', { fg = '#BD93F9', bg = 'NONE' }) -- Inactive line text color
  -- Define soft red for labels
  api.nvim_set_hl(0, "SoftRedLabel", { fg = "#e06c75" }) 
  -- Define soft orange for keys/actions
  api.nvim_set_hl(0, "SoftOrangeKey", { fg = "#d19a66" })
end

-- 2. Autocomplete Engine Logic
local function close_suggestions()
  if state.suggest_win and api.nvim_win_is_valid(state.suggest_win) then
    api.nvim_win_close(state.suggest_win, true)
  end
  state.suggest_win = nil
end

local function confirm_suggestion(q_ovr_win)
  if #state.suggestions == 0 then
    return
  end
  local word = state.suggestions[1] -- Select first match
  local cursor = api.nvim_win_get_cursor(q_ovr_win)
  local line = api.nvim_get_current_line()
  local before = line:sub(1, cursor[2]):gsub('[%w_]+$', '')
  local after = line:sub(cursor[2] + 1)
  api.nvim_set_current_line(before .. word .. after)
  api.nvim_win_set_cursor(q_ovr_win, { cursor[1], #before + #word })
  close_suggestions()
end

local function show_suggestions(q_ovr_win)
  local cursor = api.nvim_win_get_cursor(q_ovr_win)
  local line = api.nvim_get_current_line()
  local before_cursor = line:sub(1, cursor[2])
  local current_word = before_cursor:match '[%w_]+$'

  if not current_word or #current_word < 1 then
    return close_suggestions()
  end

  state.suggestions = {}
  for _, k in ipairs(sql_keywords) do
    if k:lower():find('^' .. current_word:lower()) then
      table.insert(state.suggestions, k)
    end
  end

  if #state.suggestions == 0 then
    return close_suggestions()
  end

  if not state.suggest_win or not api.nvim_win_is_valid(state.suggest_win) then
    state.suggest_buf = api.nvim_create_buf(false, true)
    state.suggest_win = api.nvim_open_win(state.suggest_buf, false, {
      relative = 'cursor',
      row = 1,
      col = 0,
      width = 20,
      height = math.min(#state.suggestions, 5),
      style = 'minimal',
      border = 'single',
      focusable = false,
      zindex = 150,
    })
  end
  api.nvim_buf_set_lines(state.suggest_buf, 0, -1, false, state.suggestions)
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

-- 3. Table config
local function apply_table_highlights(buf)
  api.nvim_buf_clear_namespace(buf, state.ns, 0, -1)
  local line_count = api.nvim_buf_line_count(buf)
  api.nvim_buf_add_highlight(buf, state.ns, state.hl_header, 0, 0, -1)
  for i = 1, line_count - 1 do
    local hl = (i % 2 == 0) and state.hl_row_even or state.hl_row_odd
    api.nvim_buf_add_highlight(buf, state.ns, hl, i, 0, -1)
  end
end

local function render_results_table(buf, data)
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
    header_str = header_str .. h .. string.rep(' ', widths[i] - #h)
  end

  local row_lines = {}
  for _, row in ipairs(data.rows) do
    local line = ''
    for i, val in ipairs(row) do
      local s = tostring(val or '')
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

-- 4. Cursor & Cell Movement Logic
local function move_cell(dir)
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

local function render_explorer_tree(buf)
  local lines = {}
  api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  api.nvim_buf_set_option(buf, 'modifiable', true)

  local function add_line(text, level, is_open, node_id)
    local indent = string.rep('  ', level)
    local icon = ''
    if is_open ~= nil then -- Collapsible node (folder/db)
      icon = is_open and state.icons.folder_open or state.icons.folder_closed
    else -- Leaf node (field)
      icon = state.icons.field -- Or state.icons.table if you want a different icon
    end

    for _, word in ipairs(state.db_types) do
        local s, e = text:find(word)
        if s then
          table.insert(lines, indent .. icon .. ' ' .. text .. ' --ID:' .. (generate_id() or ''))
          return
        else
          table.insert(lines, indent .. icon .. ' ' .. text)
          return
        end
    end

    -- Store the node_id in the line for later extraction by toggle_node/switch_to_win
    --table.insert(lines, indent .. icon .. ' ' .. text .. ' --ID:' .. (node_id or ''))
    --table.insert(lines, indent .. icon .. ' ' .. text)
  end

  -- THE STATIC DATA MODEL
  local data = {
    ['MyLocalDB'] = { name = 'MyLocalDB [SQLite]', type = 'db', children = { 'Tables', 'Views', 'Indexes', 'Triggers' } },
    ['Tables'] = { name = 'Tables', type = 'folder', children = { 'users' } },
    ['Views'] = { name = 'Views', type = 'folder', children = {} },
    ['Indexes'] = { name = 'Indexes', type = 'folder', children = {} },
    ['Triggers'] = { name = 'Triggers', type = 'folder', children = {} },
    ['users'] = { name = 'users', type = 'table', children = { 'name TEXT', 'email TEXT', 'joined_at INTEGER' } },
    -- ADDED KEYS AND COMMAS BELOW = {name = 'name TEXT', type = 'field'}, = {name = 'email TEXT', type = 'field'},
    ['name TEXT'] = { name = 'name TEXT', type = 'field' },
    ['email TEXT'] = { name = 'email TEXT', type = 'field' },
    ['joined_at INTEGER'] = { name = 'joined_at INTEGER', type = 'field' },
  }

  -- THE RECURSIVE DRAW LOGIC
  local function draw_node(node_id, level)
    local node_data = data[node_id]

    -- Safeguard against missing data (fixes the previous error)
    if node_data == nil then
      print('Error: Missing node data for ID: ' .. tostring(node_id))
      return
    end

    local is_open = state.open_nodes[node_id]
    local display_name = node_data.name

    -- Handle different display types and add the current line
    if node_data.type == 'db' then
      -- DB node is always collapsible
      add_line(display_name, level, is_open, node_id)
      if is_open then
        -- Optional static extra line for the path
        add_line('Path: ./Blue Book/Codes/Test_Projects/db.nvim/examples/demo.db', level + 1, nil, nil)
      end
    elseif node_data.type == 'folder' or node_data.type == 'table' then
      -- Table and Folder nodes are collapsible
      add_line(display_name, level, is_open, node_id)
    else -- 'field' type (leaf node)
      add_line(display_name, level, nil, node_id)
    end

    -- Recursively draw children if the node is open and has children
    if is_open and node_data.children and #node_data.children > 0 then
      for _, child_id in ipairs(node_data.children) do
        draw_node(child_id, level + 1)
      end
    end
  end

  -- Start the drawing process from the root node
  draw_node('MyLocalDB', 0)

  -- Finally, update the Neovim buffer
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_buf_set_option(buf, 'modifiable', false)
end

-- Add a function you can call externally when a connection is made
-- M.connect_db = function ()
local connect_db = function(ovr_buf)
  -- Set default open states
  state.open_nodes = { ['MyLocalDB'] = true, ['Tables'] = false, ['Views'] = false, ['Indexes'] = false, ['Triggers'] = false }
  -- (You would also fetch real schema data here)
  render_explorer_tree(ovr_buf)
end

-- Update your M.toggle_node function definition elsewhere in your script
M.toggle_node = function()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)

  api.nvim_buf_set_option(buf, 'modifiable', true)
  local cursor_row = api.nvim_win_get_cursor(win)[1]
  local line = api.nvim_buf_get_lines(buf, cursor_row - 1, cursor_row, false)[1]

  -- Use a pattern match to reliably extract the hidden ID suffix:
  --local node_id = line:match '--ID:(%w+)' -- TODO: important line for later usage
  local node_id = line:match '(%w+)'
  local db_type = line:match '%[([^%]]+)%]'

  for _, word in ipairs(state.db_types) do
    if state.is_connected == false then
      if db_type == word then
        connect_db(buf)
        return
      end
    elseif state.is_connected == true then
      break
    end
  end

  if node_id and state.open_nodes[node_id] ~= nil then
    state.open_nodes[node_id] = not state.open_nodes[node_id]
    render_explorer_tree(buf) -- Re-render the explorer buffer
    -- Optional: Restore cursor position after redraw
    -- api.nvim_win_set_cursor(win, {cursor_row, 0})
  end

  api.nvim_buf_set_option(buf, 'modifiable', false)
end

-- 4. Main Focus and Bottom Bar Handler
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
      api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, state.hl_first_line_text, 0, 4, -1)
      api.nvim_win_set_option(ovr_win, 'winhl', 'Normal:' .. state.hl_overlay_active)
      if b_buf then
        api.nvim_buf_set_lines(b_buf, 0, -1, false, {})

        if state.is_connected == true then
          connection_status = 'Connected to SQLite'
        elseif state.is_connected == false then
          connection_status = 'Not Connected'
        end

        api.nvim_buf_set_lines(b_buf, 0, 1, false, { connection_status })
        --api.nvim_buf_set_lines(b_buf, 1, 2, false, { 'Connect: <enter> | New: n | Edit: e | Delete: d | Refresh: f | Close: <esc> (in normal mode)' })

        -- 1. Get window width
        local win_width = api.nvim_win_get_width(b_win) - 2
    
        -- 2. Your existing text
        local left_text = "Connect: <enter> | New: n | Edit: e | Delete: d | Refresh: f | Close: <esc> (in normal mode)"
        local right_text = "Help: ? | Leader: <space>"
    
        -- 3. Calculate spaces needed
        -- We subtract 1 or 2 to account for the sign column/edge
        local space_count = win_width - #left_text - #right_text - 1
    
        if space_count > 0 then
            local full_line = left_text .. string.rep(" ", space_count) .. right_text
            -- 4. Set the line
            api.nvim_buf_set_lines(b_buf, 1, 2, false, { full_line })
        else
            -- If window is too small, just put one space
            api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. " " .. right_text })
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
          connection_status = ' Connected to SQLite' --  TODO: add state.db_type logic later
        elseif state.is_connected == false then
          connection_status = ' Not Connected'
        end

        local mode_text = is_insert and ' INSERT ' or ' NORMAL '
        api.nvim_buf_set_lines(b_buf, 0, 1, false, { mode_text .. connection_status })
        --api.nvim_buf_set_lines(b_buf, 1, 2, false, { 'Insert Mode: i | Normal Mode: <esc> | Execute: <enter> | History: h | Close: <esc> (in normal mode)' })

        -- 1. Get window width
        local win_width = api.nvim_win_get_width(b_win) - 2
    
        -- 2. Your existing text
        local left_text = "Insert Mode: i | Normal Mode: <esc> | Execute: <enter> | History: h | Close: <esc> (in normal mode)"
        local right_text = "Help: ? | Leader: <space>"
    
        -- 3. Calculate spaces needed
        -- We subtract 1 or 2 to account for the sign column/edge
        local space_count = win_width - #left_text - #right_text - 1
    
        if space_count > 0 then
            local full_line = left_text .. string.rep(" ", space_count) .. right_text
            -- 4. Set the line
            api.nvim_buf_set_lines(b_buf, 1, 2, false, { full_line })
        else
            -- If window is too small, just put one space
            api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. " " .. right_text })
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
          connection_status = 'Connected to SQLite' --  TODO: add state.db_type logic later
        elseif state.is_connected == false then
          connection_status = 'Not Connected'
        end

        api.nvim_buf_set_lines(b_buf, 0, 1, false, { connection_status })

        -- 1. Get window width
        local win_width = api.nvim_win_get_width(b_win) - 2
    
        -- 2. Your existing text
        local left_text = "Close: <esc> (in normal mode)"
        local right_text = "Help: ? | Leader: <space>"
    
        -- 3. Calculate spaces needed
        -- We subtract 1 or 2 to account for the sign column/edge
        local space_count = win_width - #left_text - #right_text - 1
    
        if space_count > 0 then
            local full_line = left_text .. string.rep(" ", space_count) .. right_text
            -- 4. Set the line
            api.nvim_buf_set_lines(b_buf, 1, 2, false, { full_line })
        else
            -- If window is too small, just put one space
            api.nvim_buf_set_lines(b_buf, 1, 2, false, { left_text .. " " .. right_text })
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
  local ns = api.nvim_create_namespace("my_dynamic_highlights")
    
  -- Clear previous highlights in this namespace
  api.nvim_buf_clear_namespace(b_buf, ns, 0, -1)

  local lines = api.nvim_buf_get_lines(b_buf, 0, -1, false)
  for i, line in ipairs(lines) do
      local line_idx = i - 1

      -- Patterns to match: Label (Soft Red)
      local labels = { "Connect:", "New:", "Edit:", "Leader:", "Refresh:", "Help:", "Delete:", "Execute:", "History:", "Close:", "Insert Mode:", "Normal Mode:" }
      for _, word in ipairs(labels) do
          local s, e = line:find(word)
          if s then
              api.nvim_buf_add_highlight(b_buf, ns, "SoftRedLabel", line_idx, s-1, e)
          end
      end

      -- Patterns to match: Keys (Soft Orange)
      -- Uses lua patterns to find <...> or single letters after a colon
      local orange_patterns = { "<enter>", " n ", "<space>", "?", " e ", " f ", " d ", " i ", " h ", "<esc>" }
      for _, pat in ipairs(orange_patterns) do
          local s, e = line:find(pat)
          if s then
              -- Adjust start/end if you included spaces in the pattern to match precisely
              api.nvim_buf_add_highlight(b_buf, ns, "SoftOrangeKey", line_idx, s-1, e)
          end
      end
    end
end

M.close_all_windows = function()
  pcall(api.nvim_del_augroup_by_name, 'DbViewEvents')
  close_suggestions()
  for id, _ in pairs(state.wins) do
    if api.nvim_win_is_valid(id) then
      api.nvim_win_close(id, true)
    end
  end
  if state.parent_win_id and api.nvim_win_is_valid(state.parent_win_id) then
    api.nvim_win_close(state.parent_win_id, true)
  end
  state.wins = {}
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
  setup_highlight_groups()
  local ui = api.nvim_list_uis()[1]
  local w, h = math.floor(ui.width * 1), math.floor(ui.height * 0.9)
  local c, r = math.floor((ui.width - w) / 2) - 1, math.floor((ui.height - h) / 2) - 2

  state.parent_win_id = api.nvim_open_win(
    api.nvim_create_buf(false, true),
    true,
    { relative = 'editor', width = w, height = h, col = c, row = r, style = 'minimal', border = 'none' }
  )

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
    height = math.floor(main_h * 0.6) - 6,
    col = 2,
    row = 1,
    style = 'minimal',
    border = 'none',
    zindex = 110,
  })
  state.wins[r_ovr_win] = 'r_overlay'

  render_results_table(r_ovr_buf, {
    headers = { 'ID', 'USERNAME', 'EMAIL', 'STATUS' },
    rows = {
      { '1', 'alice', 'asdfjhskdjf@x.com', 'ACTIVE' },
      { '2', 'bob', 'bsmdfkjsdfs@y.com', 'INACTIVE' },
      {
        '3',
        'dev',
        'dsjkhfskjdhgjkdsg@z.com',
        'ACTIVE',
      },
    },
  })

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
    callback = function()
      show_suggestions(q_ovr_win)
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
      vim.keymap.set('n', '<Esc>', M.close_all_windows, { buffer = b })
      if name == 'overlay' then
        map(ovr_buf, 'n', '<CR>', [[<cmd>lua require'db.ui'.toggle_node()<CR>]])
      end
      if name == 'query' then
        vim.keymap.set('i', '<Tab>', function()
          if state.suggest_win then
            confirm_suggestion(q_ovr_win)
          else
            return '<Tab>'
          end
        end, { buffer = b, expr = true })
        vim.keymap.set('i', '<Esc>', '<cmd>stopinsert<cr>', { buffer = b })
      end
    end
  end
  update_ui_state()
end

return M
