local api = vim.api
local state = require('vault.state').state

local M = {}

function M.fetch_dynamic_data(db_path, db_name, db_type, db_id)
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

function M.fetch_dynamic_pg_data(db_name, db_type, db_host, db_port, database, db_user, db_password, db_id)
  local pgmoon = require('pgmoon')
  local db = pgmoon.new({
    host     = db_host,
    port     = db_port or '5432',
    database = database,
    user     = db_user,
    password = db_password,
  })

  assert(db:connect())

  -- 1. Initialize the root structure
  state.db_data = {
    [db_name] = {
      id       = db_id or '',
      name     = db_name .. ' ' .. '[' .. db_type .. ']',
      type     = 'db',
      children = { 'Tables', 'Views', 'Indexes', 'Triggers' },
    },
    ['Tables']   = { name = 'Tables',   type = 'folder', children = {} },
    ['Views']    = { name = 'Views',    type = 'folder', children = {} },
    ['Indexes']  = { name = 'Indexes',  type = 'folder', children = {} },
    ['Triggers'] = { name = 'Triggers', type = 'folder', children = {} },
  }

  -- 2. Fetch all objects (Tables, Views, Triggers, Indexes)
  --    PostgreSQL uses information_schema and pg_catalog instead of sqlite_schema
  local schema, err = db:query([[
    SELECT table_name AS name, table_type AS type
    FROM information_schema.tables
    WHERE table_schema = 'public'

    UNION ALL

    SELECT indexname AS name, 'index' AS type
    FROM pg_indexes
    WHERE schemaname = 'public'

    UNION ALL

    SELECT trigger_name AS name, 'trigger' AS type
    FROM information_schema.triggers
    WHERE trigger_schema = 'public'
  ]])

  if not schema then
    error('Failed to fetch schema: ' .. tostring(err))
  end

  for _, obj in ipairs(schema) do
    -- Normalize PG types to match your folder keys
    -- information_schema returns 'BASE TABLE' and 'VIEW', so map them
    local normalized_type
    if obj.type == 'BASE TABLE' then
      normalized_type = 'table'
    elseif obj.type == 'VIEW' then
      normalized_type = 'view'
    else
      normalized_type = obj.type:lower() -- 'index', 'trigger'
    end

    local folder_key = normalized_type:gsub('^%l', string.upper) .. 's' -- e.g., 'table' -> 'Tables'

    if state.db_data[folder_key] then
      table.insert(state.db_data[folder_key].children, obj.name)

      -- 3. If it's a table, fetch its columns via information_schema
      if normalized_type == 'table' then
        local cols, col_err = db:query(string.format([[
          SELECT column_name AS name, data_type AS type
          FROM information_schema.columns
          WHERE table_schema = 'public'
            AND table_name = '%s'
          ORDER BY ordinal_position
        ]], obj.name))

        if not cols then
          error('Failed to fetch columns for ' .. obj.name .. ': ' .. tostring(col_err))
        end

        local field_children = {}
        for _, col in ipairs(cols) do
          local field_name = obj.name .. '.' .. col.name
          local display    = col.name .. ' ' .. col.type
          state.db_data[field_name] = { name = display, type = 'field' }
          table.insert(field_children, field_name)
        end

        state.db_data[obj.name] = {
          name     = obj.name,
          type     = 'table',
          children = field_children,
        }

        if state.open_nodes[obj.name] == nil then
          state.open_nodes[obj.name] = false
        end
      else
        state.db_data[obj.name] = { name = obj.name, type = normalized_type, children = {} }
      end
    end
  end

  db:disconnect()
  return state.db_data
end

function M.render_explorer_tree(buf)
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

-- ■■■ Select Top 100 (Ctrl+S) ■■■
function M.select_top_100()
  if not state.is_connected then
    state.last_query_status = 'Not connected to any database'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  -- Get current line in overlay
  local ovr_win = nil
  local ovr_buf = nil
  for id, name in pairs(state.wins) do
    if name == 'overlay' then
      ovr_win = id
      ovr_buf = api.nvim_win_get_buf(id)
      break
    end
  end

  if not ovr_win then return end

  local cursor_row = api.nvim_win_get_cursor(ovr_win)[1]
  local node_id    = state.tree_line_map and state.tree_line_map[cursor_row - 1]

  if not node_id then
    state.last_query_status = 'No node selected'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  -- Get node data
  local node = state.db_data[node_id]
  if not node or node.type ~= 'table' then
    state.last_query_status = 'Cursor is not on a table'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  -- Build query
  local sql = string.format('SELECT * FROM %s LIMIT 100;', node_id)

  -- Write into query buffer
  for id, name in pairs(state.wins) do
    if name == 'q_overlay' then
      local qbuf = api.nvim_win_get_buf(id)
      api.nvim_buf_set_lines(qbuf, 0, -1, false, { sql })
      break
    end
  end

  -- Execute it
  local query = require('vault.query')
  query.execute_query()

  -- Switch focus to results
  local ui = require('vault.ui')
  ui.switch_to_win 'r_overlay'
end

-- ■■■ Refresh Explorer Tree ■■■
function M.refresh_explorer_tree()
  if not state.is_connected or not state.db_path or not state.root_node_id then
    state.last_query_status = 'Not connected to any database'
    local ui = require('vault.ui')
    ui.update_ui_state()
    return
  end

  -- Save current open_nodes state before refresh
  local saved_open_nodes = {}
  for k, v in pairs(state.open_nodes) do
    saved_open_nodes[k] = v
  end

  -- Re-fetch schema data
  local db_name = state.root_node_id
  local db_type = state.db_type
  local db_path = state.db_path
  local db_id   = nil

  -- Get db_id from current db_data
  if state.db_data[db_name] then
    db_id = state.db_data[db_name].id
  end

  -- Re-fetch fresh schema
  if state.db_type == "SQLite" then
    state.db_data = M.fetch_dynamic_data(db_path, db_name, db_type, db_id)
  elseif state.db_type == "PostgreSQL" then
    state.db_data = M.fetch_dynamic_pg_data(db_name, db_type, state.db_host, state.db_port, state.db_database, state.db_username, state.db_password, db_id)
  end

  -- Restore open_nodes — keep existing states, init new nodes as closed
  state.open_nodes = {}
  for k, v in pairs(saved_open_nodes) do
    state.open_nodes[k] = v
  end

  -- Make sure new tables default to closed if not in saved state
  for node_id, node in pairs(state.db_data) do
    if node.type == 'table' and state.open_nodes[node_id] == nil then
      state.open_nodes[node_id] = false
    end
    if node.type == 'folder' and state.open_nodes[node_id] == nil then
      state.open_nodes[node_id] = false
    end
  end

  -- Re-render the explorer tree
  local ovr_buf = nil
  for id, name in pairs(state.wins) do
    if name == 'overlay' then
      ovr_buf = api.nvim_win_get_buf(id)
      break
    end
  end

  if ovr_buf then
    M.render_explorer_tree(ovr_buf)
  end

  state.last_query_status = 'Explorer refreshed'
  local ui = require('vault.ui')
  ui.update_ui_state()
end

function M.toggle_node()
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
        local connection = require('vault.connection')
        if db_type == "SQLite" then
          connection.connect_sql_db(buf, node_id)
        elseif db_type == "PostgreSQL" then
          connection.connect_pg_db(buf, node_id)
        end
        return
      end
    elseif state.is_connected == true then
      break        --        
    end
  end

  -- DYNAMIC FIX: If the node isn't in open_nodes yet, initialize it
  if node and state.db_data[node] then
    if state.open_nodes[node] == nil then
      state.open_nodes[node] = false
    end
    
    state.open_nodes[node] = not state.open_nodes[node]
    M.render_explorer_tree(buf)
  end

  api.nvim_buf_set_option(buf, 'modifiable', false)
end

return M