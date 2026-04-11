local api = vim.api
local db = require('vault.db')

local M = {}

M.state = {
  wins = {},
  sys_db = db.init(),
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
  -- DB tree icons
  icons = {
    db = '⌘',
    folder_open = '▼',
    folder_closed = '▶',
    table = '',
    field = '',
  },
}

return M