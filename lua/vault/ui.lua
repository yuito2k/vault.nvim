local api   = vim.api
local state = require('vault.state').state
local highlight = require('vault.highlights')
local explorer = require('vault.explorer')
local results = require('vault.results')
local connection = require('vault.connection')
local query = require('vault.query')
local filter = require('vault.filter')

local M     = {}

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

function M.close_all_windows()
  pcall(api.nvim_del_augroup_by_name, 'DbViewEvents')
  query.suggest_close()

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

function M.switch_to_win(target)
  for id, name in pairs(state.wins) do
    if name == target and api.nvim_win_is_valid(id) then
      api.nvim_set_current_win(id)
      return
    end
  end
end

function M.update_ui_state()
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

      local function has_value(tab, val)
        for _, value in ipairs(tab) do
            if value == val then
                return true
            end
        end
        return false
      end
    
      -- paint child lines: connector fg only
      for line_nr, _ in pairs(lines_to_highlight) do
        if line_nr ~= cursor_line_0 then
          for _, hl in ipairs(state.tree_highlights or {}) do
            if hl[1] == line_nr then
              if hl[4] == 'ExplorerConnector' then
                local line_content = vim.api.nvim_get_current_line()
                local tree_list = {"Views", "Indexes", "Triggers"}

                if cursor_line_0 == 0 then
                  api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerConnectorActive', line_nr, hl[2], hl[3])
                  api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerConnectorActive', 1, hl[2], hl[3])
                elseif cursor_line_0 == 2 then
                  api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerConnectorActive', line_nr, hl[2]+1, hl[3])
                else
                  for _, item in ipairs(tree_list) do
                    if cursor_line_text:find(item, 1, true) then
                        api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerConnectorActive', line_nr, hl[2]+1, hl[3])
                        break -- Stop looking once we find one match
                    end
                  end

                  api.nvim_buf_add_highlight(ovr_buf, state.overlay_ns, 'ExplorerConnectorActive', line_nr, hl[2]+6, hl[3])
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
        local left_text  = 'Connect: <enter> | New: ^n | Edit: ^e | Close: ^c | Delete: ^d | Refresh: ^f | Exit: <esc>'
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
    results.apply_table_highlights(buf, false)

    -- offset row index by 1 when search bar is taking line 0
    local data_row_idx = filter.search_state.active and (cursor[1] - 1) or cursor[1]
    if data_row_idx < 1 then data_row_idx = 1 end

    local row_idx = data_row_idx
    local offsets = (state.row_col_offsets and state.row_col_offsets[row_idx])
      or state.table_cols
    local col_idx = 1
    for i, offset in ipairs(offsets) do
      if cursor[2] >= offset then
        col_idx = i
      end
    end

    local start_col  = offsets[col_idx]
    local next_offset = offsets[col_idx + 1] or -1
    api.nvim_win_set_cursor(r_ovr_win, { cursor[1], start_col })
    api.nvim_buf_add_highlight(buf, state.ns, state.hl_cell_cursor, cursor[1] - 1, start_col, next_offset)
  end

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
          left_text  = 'Normal: <esc> | Execute: <enter> | AutoComplete: <tab> | Next: ^n | Previous: ^p | History: ^h '
        else
          left_text = 'Insert: i | Execute: <enter> | History: <BS> | Exit: <esc>'
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
        local left_text = 'Exit: <esc> | Edit: ^u | Delete: ^x | Copy: ^y | Filter: ^/' .. set_indicator

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
      results.apply_table_highlights(r_ovr_buf)
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
        local view = api.nvim_win_call(r_ovr_win, function()
          return vim.fn.winsaveview()
        end)
        api.nvim_win_call(id, function()
          vim.fn.winrestview({ leftcol = view.leftcol })
        end)
      end
    end
  end

  if copy_menu_win and api.nvim_win_is_valid(copy_menu_win) then
    local curr_check = api.nvim_get_current_win()
    local r_ovr_win_check = nil
    for id, name in pairs(state.wins) do
      if name == 'r_overlay' then r_ovr_win_check = id; break end
    end
    if curr_check ~= r_ovr_win_check then
      results.close_copy_menu()
    end
  end

  -- ─── Bottom bar key-hint highlights ─────────────────────────────────────────
  local ns = api.nvim_create_namespace 'my_dynamic_highlights'
  api.nvim_buf_clear_namespace(b_buf, ns, 0, -1)

  local lines = api.nvim_buf_get_lines(b_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local line_idx = i - 1

    local labels = { 'Connect:', 'New:', 'Edit:', 'Exit:', 'AutoComplete:', 'Next:', 'Copy:', 'Filter:', 'Previous:', 'Leader:', 'Refresh:', 'Help:', 'Delete:', 'Execute:', 'History:', 'Close:', 'Insert:', 'Normal:' }
    for _, word in ipairs(labels) do
      local s, e = line:find(word)
      if s then
        api.nvim_buf_add_highlight(b_buf, ns, 'SoftRedLabel', line_idx, s - 1, e)
      end
    end

    local orange_patterns = { '<enter>', ' ^n ', '<BS>', '<space>', '<tab>', ' ^? ', ' ^r ', ' ^p ', ' ^u ', ' ^y ', ' ^/ ', ' ^x ', ' ^e ', ' ^c ', ' ^d ', ' i ', ' ^h ', '<esc>' }
    for _, pat in ipairs(orange_patterns) do
      local s, e = line:find(pat)
      if s then
        api.nvim_buf_add_highlight(b_buf, ns, 'SoftOrangeKey', line_idx, s - 1, e)
      end
    end
  end
end

M.open_db_float = function()
  highlight.setup_highlight_groups()

  local ui = api.nvim_list_uis()[1]
  local w, h = math.floor(ui.width * 1), math.floor(ui.height * 0.9)
  local c, r = math.floor((ui.width - w) / 2) - 1, math.floor((ui.height - h) / 2) - 2

  local main_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_option(main_buf, 'bufhidden', 'wipe') -- Auto-delete buffer on close
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
  })] = 'overlay_scroll'

  -- Initially only show the DB name, closed
  state.open_nodes = { ['MyLocalDB'] = false }

  -- Call the new render function instead of setting lines manually
  explorer.render_explorer_tree(ovr_buf)

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
  api.nvim_win_set_option(q_ovr_win, 'wrap', false)

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

  results.render_results_table(r_ovr_buf, {
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
  api.nvim_buf_set_option(ovr_buf, 'modifiable', false)

  api.nvim_win_set_option(r_win, 'cursorline', false)
  api.nvim_win_set_option(r_ovr_win, 'cursorline', false)

  state.wins[api.nvim_open_win(
    api.nvim_create_buf(false, true),
    false,
    { relative = 'win', win = state.parent_win_id, width = w - 2, height = bottom_h, col = 0, row = h - bottom_h, border = 'rounded' }
  )] = 'bottom_bar'

  -- Events
  api.nvim_create_augroup('DbViewEvents', { clear = true })
  api.nvim_create_autocmd({ 'WinEnter', 'CursorMoved', 'ModeChanged', 'InsertEnter', 'WinScrolled' }, { group = 'DbViewEvents', callback = M.update_ui_state })
  
  api.nvim_create_autocmd('TextChangedI', {
    group = 'DbViewEvents',
    buffer = q_ovr_buf,          -- only fire for the query buffer, not globally
    callback = function()
      query.suggest_update(q_ovr_win)
    end,
  })

  -- close suggestions when leaving insert mode
  api.nvim_create_autocmd({ 'InsertLeave', 'BufLeave' }, {
    group  = 'DbViewEvents',
    buffer = q_ovr_buf,
    callback = function()
      query.suggest_close()
    end,
  })
  --api.nvim_create_autocmd('WinEnter', { group='DbViewEvents', callback=function() if api.nvim_get_current_win() == q_win then vim.cmd('startinsert') end end })

  -- Cell Navigation Maps
  for _, k in ipairs { 'h', 'l', '<Left>', '<Right>' } do
    vim.keymap.set('n', k, function()
      results.move_cell(k == 'h' or k == '<Left>' and -1 or 1)
    end, { buffer = r_ovr_buf })
  end

  -- Keymaps
  for id, name in pairs(state.wins) do
    if not name:find 'scroll' and name ~= 'bottom_bar' then
      local b = api.nvim_win_get_buf(id)
      vim.keymap.set('n', 'e', function()
        M.switch_to_win 'overlay'
      end, { buffer = b })
      vim.keymap.set('n', 'q', function()
        M.switch_to_win 'query'
      end, { buffer = b })
      vim.keymap.set('n', 'r', function()
        M.switch_to_win 'results'
      end, { buffer = b })
      vim.keymap.set('n', '<BS>', function()
        query.open_history(q_ovr_win, q_ovr_buf)
      end, { buffer = q_ovr_buf, desc = 'Query history' })
      -- in the keymaps loop where you register for all windows
      vim.keymap.set('n', '<C-r>', function()
        explorer.refresh_explorer_tree()
      end, { buffer = ovr_buf, desc = 'Refresh explorer tree' })
      vim.keymap.set('n', '<C-u>', results.edit_cell, { buffer = r_ovr_buf, desc = 'Edit cell value' })
      vim.keymap.set('n', '<C-x>', results.delete_row, { buffer = r_ovr_buf, desc = 'Delete row' })
      vim.keymap.set('n', '<C-y>', results.open_copy_menu, { buffer = r_ovr_buf, desc = 'Open copy menu' })
      vim.keymap.set('n', '<C-/>', function()
        local r_ovr_win_local, r_ovr_buf_local = nil, nil
        for id, name in pairs(state.wins) do
          if name == 'r_overlay' then
            r_ovr_win_local = id
            r_ovr_buf_local = api.nvim_win_get_buf(id)
          end
        end
        if r_ovr_win_local then filter.open_search(r_ovr_win_local, r_ovr_buf_local) end
      end, { buffer = r_ovr_buf, desc = 'Search results' })
      if name == 'overlay' then
        vim.keymap.set('n', '<C-n>', function()
          connection.render_connection_ui()
        end, { buffer = b, noremap = true, silent = true })

        vim.keymap.set('n', '<C-e>', function()
          connection.edit_db()
        end, { buffer = b, noremap = true, silent = true, desc = 'Edit selected DB connection' })
      end
      vim.keymap.set('n', '<C-c>', function()
        connection.disconnect_db()
      end, { buffer = ovr_buf, desc = "Close DB Tree and return to list" })
      vim.keymap.set('n', '<C-d>', function()
        connection.delete_db()
      end, { buffer = ovr_buf, desc = "Delete DB Connection and return to list" })
      vim.keymap.set('n', '<Esc>', M.close_all_windows, { buffer = b })
      if name == 'overlay' then
        api.nvim_buf_set_keymap(ovr_buf, 'n', '<CR>', [[<cmd>lua require'vault.explorer'.toggle_node()<CR>]], { noremap = true, silent = true })
      end
      if name == 'query' then
        vim.keymap.set('i', '<Tab>', function()
          local confirmed = query.suggest_confirm(q_ovr_win)
          if not confirmed then
            api.nvim_feedkeys(
              api.nvim_replace_termcodes('<Tab>', true, false, true),
              'n', false
            )
          end
        end, { buffer = q_ovr_buf })        -- ← q_ovr_buf, not b
      
        vim.keymap.set('i', '<C-n>', function()
          query.suggest_move(1)
        end, { buffer = q_ovr_buf })        -- ← q_ovr_buf, not b
      
        vim.keymap.set('i', '<C-p>', function()
          query.suggest_move(-1)
        end, { buffer = q_ovr_buf })        -- ← q_ovr_buf, not b
      
        vim.keymap.set('i', '<Esc>', function()
          if query.suggest_is_open() then
            query.suggest_close()
            vim.cmd 'stopinsert'
          else
            vim.cmd 'stopinsert'
          end
        end, { buffer = q_ovr_buf })        -- ← q_ovr_buf, not b
      end
      if name == 'q_overlay' then
        -- Execute query on Enter in Normal mode
        vim.keymap.set('n', '<CR>', query.execute_query, { buffer = b, desc = 'Execute SQL Query' })
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
          results.render_results_table(r_ovr_buf_local, state.result_sets[state.result_set_index])
        end
        M.update_ui_state()
      end, { buffer = r_ovr_buf })
    end
  end

  M.update_ui_state()
end

return M
