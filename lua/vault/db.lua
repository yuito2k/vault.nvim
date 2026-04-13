-- lua/vault/db.lua
local M = {}

function M.get_path()
  local data_dir = vim.fn.stdpath('data') .. '/vault'
  -- create the directory if it doesn't exist
  vim.fn.mkdir(data_dir, 'p')
  return data_dir .. '/vault.db'
end

function M.init()
  local path = M.get_path()
  local db   = require('sqlite.db'):open(path)
  -- create the connections table if it doesn't exist
  db:eval([[
    CREATE TABLE IF NOT EXISTS database (
      id   TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      type TEXT NOT NULL,
      path TEXT NOT NULL
    );
  ]])
  db:eval([[
    CREATE TABLE IF NOT EXISTS query_history (
      id         TEXT PRIMARY KEY,
      db_id      TEXT NOT NULL,
      query      TEXT NOT NULL,
      starred    INTEGER DEFAULT 0,
      created_at TEXT DEFAULT (datetime('now'))
    );
  ]])
  db:close()
  return path
end

return M