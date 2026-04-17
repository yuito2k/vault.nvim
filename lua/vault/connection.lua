local api = vim.api
local state = require('vault.state').state
local explorer = require('vault.explorer')

local M = {}

local conn_state = {
  active_idx = 1,
  fields = {
    { name = ' Database Name ', value = 'MyDatabase', type = 'input', row = 4, col = 6, width = 75 },
    { name = ' Database Type ', value = 'SQLite', type = 'dropdown', row = 8, col = 6, width = 75, options = { 'SQLite', 'PostgreSQL', 'MySQL', 'OracleDB', 'MongoDB', 'MariaDB'} },
    { name = ' Database Path ', value = '/path/to/db.db', type = 'input', row = 12, col = 6, width = 70 },
    { name = 'Browser', value = '...', type = 'button', row = 12, col = 78, width = 3 },
  },
  -- PostgreSQL extra fields (hidden by default)
  pg_fields = {
    { name = ' Database Name ', value = 'MyDatabase', type = 'input', row = 4, col = 6, width = 75 },
    { name = ' Database Type ', value = 'PostgreSQL', type = 'dropdown', row = 8, col = 6, width = 75, options = { 'SQLite', 'PostgreSQL', 'MySQL', 'OracleDB', 'MongoDB', 'MariaDB'} },
    { name = ' Server ',   value = 'localhost', type = 'input', row = 12, col = 6,  width = 50 },
    { name = ' Port ',     value = '5432',      type = 'input', row = 12, col = 62, width = 20 },
    { name = ' Database ', value = 'postgres',          type = 'input', row = 16, col = 6,  width = 75 },
    { name = ' Username ', value = 'postgres',  type = 'input', row = 20, col = 6,  width = 35 },
    { name = ' Password ', value = 'secret',          type = 'input', row = 20, col = 44, width = 37 },
  },
  is_pg_mode = false,
  pg_wins    = {},
  wins = {}, -- Track all 4 field windows here
  main_win = nil,
}

-- 3. Function to update which one is "Bright"
function update_focus()
  if conn_state.is_pg_mode then

    for i, win in ipairs(conn_state.pg_wins) do
      if i == conn_state.active_idx then
        -- Active: Bright Border/Text
        api.nvim_win_set_option(win, 'winhl', 'Normal:NormalFloat,FloatBorder:FloatBorder')
        api.nvim_set_current_win(win)
      else
        -- Inactive: Dimmed (Comment color usually works well for dimming)
        api.nvim_win_set_option(win, 'winhl', 'Normal:Comment,FloatBorder:Comment')
      end
    end
  else
    for i, win in ipairs(conn_state.wins) do
      if i == conn_state.active_idx then
        -- Active: Bright Border/Text
        api.nvim_win_set_option(win, 'winhl', 'Normal:NormalFloat,FloatBorder:FloatBorder')
        api.nvim_set_current_win(win)
      else
        -- Inactive: Dimmed (Comment color usually works well for dimming)
        api.nvim_win_set_option(win, 'winhl', 'Normal:Comment,FloatBorder:Comment')
      end
    end
  end
end

local function show_pg_fields(main_win, ibuf_list)
  -- Close existing pg field windows
  for _, win in ipairs(conn_state.pg_wins) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  conn_state.pg_wins = {}

  if not conn_state.is_pg_mode then return end

  for i, field in ipairs(conn_state.pg_fields) do
    local ibuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, { field.value })

    local win = vim.api.nvim_open_win(ibuf, true, {
      relative = 'win',
      win      = main_win,
      row      = field.row,
      col      = field.col - 5,
      width    = field.width,
      height   = 1,
      title    = field.name,
      style    = 'minimal',
      border   = 'rounded',
      zindex   = 260,
    })
    conn_state.pg_wins[i] = win

    -- hint text styling
    vim.api.nvim_set_hl(0, 'PgFieldHint', { fg = '#6272A4', italic = true })

    local bopts = { buffer = ibuf, silent = true }

    vim.keymap.set('n', '<Tab>', function()
      -- Tab cycles through pg fields
      conn_state.active_idx = (conn_state.active_idx % 
        (#conn_state.pg_fields)) + 1
      
      update_focus()
    end, bopts)

    vim.keymap.set('n', '<CR>', function()
      vim.cmd 'startinsert!'
    end, bopts)

    vim.keymap.set('n', 's', function()
      M.trigger_save_connection()
    end, bopts)

    vim.keymap.set('n', '<Esc>', function()
      for _, w in ipairs(conn_state.wins) do
        if vim.api.nvim_win_is_valid(w) then
          vim.api.nvim_win_close(w, true)
        end
      end
      for _, w in ipairs(conn_state.pg_wins) do
        if vim.api.nvim_win_is_valid(w) then
          vim.api.nvim_win_close(w, true)
        end
      end
      vim.api.nvim_win_close(conn_state.main_win, true)

      conn_state.is_pg_mode = false
      conn_state.pg_wins    = {}
      conn_state.wins = {}
      conn_state.main_win = nil

      for id, name in pairs(state.wins) do
        if name == 'overlay' and vim.api.nvim_win_is_valid(id) then
          vim.api.nvim_set_current_win(id)
          return
        end
      end
    end, bopts)
  end

  update_focus()
end

function M.generate_id()
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

function M.show_dropdown_picker(field, parent_win)
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
  api.nvim_set_option_value('cursorline', true, { win = picker_win })
  -- Optional: Link the highlight to a specific group like 'Visual' or 'PmenuSel'
  api.nvim_set_option_value('winhl', 'CursorLine:Visual', { win = picker_win })

  vim.keymap.set('n', '<CR>', function()
    local line = api.nvim_get_current_line()
    field.value = line
    api.nvim_buf_set_lines(api.nvim_win_get_buf(parent_win), 0, -1, false, { line })
    api.nvim_win_close(picker_win, true)

    -- Toggle PostgreSQL fields
    local is_pg = (line == 'PostgreSQL' or line == 'MySQL')
    if is_pg ~= conn_state.is_pg_mode then
      conn_state.is_pg_mode = is_pg

      -- Hide/show path field and browser button
      --local path_win    = conn_state.wins[3]
      --local browser_win = conn_state.wins[4]
      --if path_win and vim.api.nvim_win_is_valid(path_win) then
      --  vim.api.nvim_win_set_config(path_win, {
      --    hide = is_pg  -- hide path field for network DBs
      --  })
      --end
      --if browser_win and vim.api.nvim_win_is_valid(browser_win) then
      --  vim.api.nvim_win_set_config(browser_win, {
      --    hide = is_pg
      --  })
      --end

      for i, win in ipairs(conn_state.wins) do
        api.nvim_win_close(win, true)
      end

      show_pg_fields(conn_state.main_win, nil)
    end
  end, { buffer = buf, silent = true })

  vim.keymap.set('n', '<Esc>', function()
    api.nvim_win_close(picker_win, true)
  end, { buffer = buf, silent = true })
end

function M.trigger_save_connection()
  -- 1. Helper to get text from a field's buffer
  local function get_field_text(index)
      local win = conn_state.wins[index]
      if win and api.nvim_win_is_valid(win) then
          local buf = api.nvim_win_get_buf(win)
          -- nvim_buf_get_lines(buf, start, end, strict)
          -- 0, -1 gets the entire content of the buffer
          local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
          return lines[1] or "" -- Take the first line of the input
      end
      return ""
  end

  local function get_pg_field_text(index)
    local win = conn_state.pg_wins[index]
    if win and vim.api.nvim_win_is_valid(win) then
      local buf   = vim.api.nvim_win_get_buf(win)
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      return lines[1] or ''
    end
    return ''
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

  local path = state.sys_db
  local f = io.open(path, 'r')

  if f then
    f:close()

    if conn_state.is_pg_mode then
      -- PostgreSQL / MySQL connection string
      local server   = get_pg_field_text(1)
      local port     = get_pg_field_text(2)
      local database = get_pg_field_text(3)
      local username = get_pg_field_text(4)
      local password = get_pg_field_text(5)

      -- Build connection string as the "path"
      local conn_str = string.format(
        '%s://%s:%s@%s:%s/%s',
        selected_type:lower(),
        username, password, server, port, database
      )

      -- Save to db
      local path = state.db_path_internal
      local db   = require('sqlite.db'):open(path)
      local db_id = generate_id()
      local insert_query = string.format(
        [[INSERT INTO database (id, name, type, path) VALUES ('%s', '%s', '%s', '%s');]],
        db_id:gsub("'","''"),
        typed_name:gsub("'","''"),
        selected_type:gsub("'","''"),
        conn_str:gsub("'","''")
      )
      local success, err = pcall(function() db:eval(insert_query) end)
      if success then
        -- refresh overlay list same as SQLite save
        -- ... same overlay refresh code ...
        for _, w in ipairs(conn_state.wins) do
          if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end
        end
        for _, w in ipairs(conn_state.pg_wins) do
          if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end
        end
        vim.api.nvim_win_close(conn_state.main_win, true)
        for id, name in pairs(state.wins) do
          if name == 'overlay' and vim.api.nvim_win_is_valid(id) then
            vim.api.nvim_set_current_win(id)
            return
          end
        end
      else
        print('Database Error: ' .. tostring(err))
      end
      db:close()
    else
      local db = require('sqlite.db'):open(path)
      local db_id = M.generate_id()

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
end

function M.render_connection_ui()
  for id, name in pairs(state.wins) do
    if name == 'overlay' and api.nvim_win_is_valid(id) then
      api.nvim_set_current_win(id)
    end
  end

  local buf = api.nvim_create_buf(false, true)
  local width, height = 80, 26
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  conn_state.main_win = api.nvim_open_win(buf, true, {
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
  api.nvim_set_option_value('winhl', 'Normal:MyCustomWinBG,FloatBorder:FloatBorder', { win = conn_state.main_win })

  -- 1. Draw Static Background (the boxes and labels)
  local lines = {
    '',
    '   General ',
    'ㅤ───────────────────────────────────────────────────────────────────────────',
  }
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value('modifiable', false, { buf = buf })

  -- 1. Clear any old windows if re-opening
  for _, win in pairs(conn_state.wins) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  conn_state.wins = {}

  -- 2. Create ALL field windows immediately
  for i, field in ipairs(conn_state.fields) do
    local ibuf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(ibuf, 0, -1, false, { field.value })

    local win = api.nvim_open_win(ibuf, false, { -- open as false (don't focus yet)
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
      M.trigger_save_connection()
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
              if picker.prompt_win and api.nvim_win_is_valid(picker.prompt_win) then
                api.nvim_win_set_config(picker.prompt_win, { border = 'rounded', zindex = 400 })
              end

              -- Set zindex for the results window
              if picker.results_win and api.nvim_win_is_valid(picker.results_win) then
                api.nvim_win_set_config(picker.results_win, { border = 'rounded', zindex = 400 })
              end

              -- Set zindex for the preview window
              if picker.preview_win and api.nvim_win_is_valid(picker.preview_win) then
                api.nvim_win_set_config(picker.preview_win, { border = 'rounded', zindex = 400 })
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
        M.show_dropdown_picker(field, conn_state.wins[i])
      else
        vim.cmd 'startinsert!'
      end
    end, opts)

    -- ESC to close everything
    vim.keymap.set('n', '<esc>', function()
      for i, win in ipairs(conn_state.wins) do
        api.nvim_win_close(win, true)
      end

      if conn_state.is_pg_mode then
        for _, win in ipairs(conn_state.pg_wins) do
          if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
          end
        end
      end

      api.nvim_win_close(conn_state.main_win, true)

      conn_state.is_pg_mode = false
      conn_state.pg_wins    = {}
      conn_state.wins = {}
      conn_state.main_win = nil

      -- TODO:  later replace with switch_to_win('overlay') the exact same thing
      for id, name in pairs(state.wins) do
        if name == 'overlay' and api.nvim_win_is_valid(id) then
          api.nvim_set_current_win(id)
          return
        end
      end
    end, opts)
  end

  update_focus()
end

function M.render_edit_connection_ui(db_id, current_name, current_type, current_path)
  -- Focus overlay first (same pattern as render_connection_ui)
  for id, name in pairs(state.wins) do
    if name == 'overlay' and api.nvim_win_is_valid(id) then
      api.nvim_set_current_win(id)
    end
  end

  local buf = api.nvim_create_buf(false, true)
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

  edit_state.main_win = api.nvim_open_win(buf, true, {
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

  api.nvim_set_option_value('winhl', 'Normal:MyCustomWinBG,FloatBorder:FloatBorder', { win = edit_state.main_win })

  local lines = {
    '',
    '   General ',
    'ㅤ───────────────────────────────────────────────────────────────────────────',
  }
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_option_value('modifiable', false, { buf = buf })

  -- Close any old field windows
  for _, win in pairs(edit_state.wins) do
    if api.nvim_win_is_valid(win) then
      api.nvim_win_close(win, true)
    end
  end
  edit_state.wins = {}

  -- Local update_focus for edit popup
  local function update_edit_focus()
    for i, win in ipairs(edit_state.wins) do
      if i == edit_state.active_idx then
        api.nvim_win_set_option(win, 'winhl', 'Normal:NormalFloat,FloatBorder:FloatBorder')
        api.nvim_set_current_win(win)
      else
        api.nvim_win_set_option(win, 'winhl', 'Normal:Comment,FloatBorder:Comment')
      end
    end
  end

  -- Save handler (UPDATE instead of INSERT)
  local function trigger_update_connection()
    local function get_field_text(index)
      local win = edit_state.wins[index]
      if win and api.nvim_win_is_valid(win) then
        local fbuf = api.nvim_win_get_buf(win)
        local flines = api.nvim_buf_get_lines(fbuf, 0, -1, false)
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

    local path = state.sys_db
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
    local ibuf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(ibuf, 0, -1, false, { field.value })

    local win = api.nvim_open_win(ibuf, false, {
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
                if picker[win_key] and api.nvim_win_is_valid(picker[win_key]) then
                  api.nvim_win_set_config(picker[win_key], { border = 'rounded', zindex = 400 })
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
        M.show_dropdown_picker(field, edit_state.wins[i])
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
  local path = state.sys_db
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
  M.render_edit_connection_ui(node_id, row.name, row.type, row.path)
end

-- Add a function you can call externally when a connection is made
-- M.connect_db = function ()
function M.connect_db(ovr_buf, db_id)
  local path = state.sys_db
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

    state.db_data = explorer.fetch_dynamic_data(db_path, db_name, db_type, db_id)
    state.db_id = db_id  -- add this alongside state.db_path, state.db_type etc.
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

    explorer.render_explorer_tree(ovr_buf)
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
        local path = state.sys_db
        local f = io.open(path, 'r')

        if f then
          f:close()
          local db = require('sqlite.db'):open(path)

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

  explorer.render_explorer_tree(buf)

  local path = state.sys_db
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
          local ovr_buf = api.nvim_win_get_buf(id)
          api.nvim_buf_set_option(ovr_buf, 'buftype', 'nofile')
          api.nvim_buf_set_option(ovr_buf, 'modifiable', true)

          if result == true then
            break
          else
            for _, row in ipairs(result) do
              -- 1. Get the content of the very first line (index 0 to 1)
              local first_line = api.nvim_buf_get_lines(ovr_buf, 0, 1, false)[1]

              --api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { '' .. ' ' .. typed_name .. ' [' .. selected_type .. '] ' .. '--ID:' .. db_id })
              local line_content = '  ' .. row.name .. ' [' .. row.type .. '] ' .. '--ID:' .. row.id

              -- 2. Check if the buffer is empty (line count is 1 and the line is empty)
              if api.nvim_buf_line_count(ovr_buf) == 1 and first_line == "" then
                -- Replace the empty first line
                api.nvim_buf_set_lines(ovr_buf, 0, 1, false, { line_content })
              else
                -- Append a new line at the very end
                api.nvim_buf_set_lines(ovr_buf, -1, -1, false, { line_content })
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
  state.db_id = nil
  state.last_select_sql = nil
    
  -- 2. Clean UI
  api.nvim_buf_set_option(ovr_buf, 'modifiable', true)
  api.nvim_buf_clear_namespace(ovr_buf, state.overlay_ns, 0, -1)
    
  -- 3. Re-render the initial list
  -- This will now fall back to your saved connection lines
  explorer.render_explorer_tree(ovr_buf)


  local path = state.sys_db
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

return M