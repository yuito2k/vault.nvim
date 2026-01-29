vim.api.nvim_create_user_command("DB", function()
	require("vault").open_db_float()
end, {})
