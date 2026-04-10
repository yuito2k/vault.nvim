local api = vim.api
local state = require('vault.state').state

local M = {}

function M.setup_highlight_groups()
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

return M