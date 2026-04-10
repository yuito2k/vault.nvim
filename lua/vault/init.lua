local ui = require('vault.ui')

local M = {}

function M.setup()
  -- nothing for now, reserved for user config
end

M.open_db_float      = ui.open_db_float
M.close_all_windows  = ui.close_all_windows
M.disconnect_db      = ui.disconnect_db
M.delete_db          = ui.delete_db
M.edit_db            = ui.edit_db

return M