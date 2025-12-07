---@class HotlinesConfig
---@field file string Path to JSON file containing coverage data
---@field ignored string[] List of Lua patterns; files matching these will be ignored
---@field color string Hex color for sign and highlights

---@class HotlinesState
---@field enabled boolean Whether the plugin is currently enabled
---@field watcher uv_fs_event_t File system watcher for coverage JSON changes
---@field initialized boolean Whether the plugin has been initialized

---@alias MarkReason "hit"|"continuation"|"closer"

local uv = vim.loop

local M = {}

-- =============================================================================
-- 1. CONFIGURATION
-- =============================================================================

---@type HotlinesConfig
local Config = {
  file = vim.fn.getcwd() .. '/tmp/hotlines.json',
  ignored = {},
  color = "#a6e3a1",
}

---@type HotlinesState
local State = {
  enabled = true,
  watcher = uv.new_fs_event(),
  initialized = false,
}

-- =============================================================================
-- 2. HELPERS
-- =============================================================================

---Reads and parses coverage JSON
---@return table<string, {lines: table<string, number>}>|nil
local function load_data()
  local fd = io.open(Config.file, "r")
  if not fd then return nil end
  local content = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, content)
  return ok and data or nil
end

-- =============================================================================
-- 3. CORE LOGIC
-- =============================================================================

---Checks if line continues a previous statement (chains, multi-line)
---@param line string
---@return boolean
local function is_continuation(line)
  local trimmed = line:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then return false end
  if trimmed:sub(1, 1) == "." or trimmed:sub(1, 2) == "&." then return true end
  if trimmed:match("^[%]%}%)]") then return true end
  return false
end

---Checks if line ends with character indicating statement continues
---@param line string
---@return boolean
local function is_open_statement(line)
  local trimmed = line:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then return false end
  local last = trimmed:sub(-1)
  return last == "(" or last == "[" or last == "{" or last == "," or last == "\\"
end

---Checks if line is standalone block closer (end, }, ], ))
---@param line string
---@return boolean
local function is_block_closer(line)
  local trimmed = line:match("^%s*(.-)%s*$")
  if not trimmed then return false end
  return trimmed == "end" or trimmed:match("^end%s")
      or trimmed == "}" or trimmed == "]" or trimmed == ")"
end

---Main algorithm: determines which lines to mark as covered
---@param buf_lines string[]
---@param file_coverage table<string, number>
---@return table<integer, MarkReason> marks
---@return table<integer, number|nil> raw_hits
function M.get_lines_to_mark(buf_lines, file_coverage)
  local marks = {}
  local raw_hits = {}

  -- PASS 1: Mark lines with explicit hits in coverage data
  for i, _ in ipairs(buf_lines) do
    local lnum = tostring(i)
    local hit = file_coverage[lnum]
    raw_hits[i] = hit

    if type(hit) == 'number' and hit > 0 then
      marks[i] = "hit"
    end
  end

  -- PASS 2: Mark continuation lines following hit lines
  local in_continuation = false
  for i, line in ipairs(buf_lines) do
    local trimmed = line:match("^%s*(.-)%s*$")

    if trimmed == "" then
      in_continuation = false
    elseif marks[i] then
      in_continuation = is_open_statement(line)
    elseif in_continuation or is_continuation(line) then
      if marks[i - 1] or in_continuation then
        marks[i] = "continuation"
        in_continuation = is_open_statement(line)
      end
    else
      in_continuation = false
    end
  end

  -- PASS 3: Mark block closers between covered lines
  for i, line in ipairs(buf_lines) do
    if not marks[i] and is_block_closer(line) then
      local prev_marked = false
      local next_marked = false

      for j = i - 1, 1, -1 do
        local prev_trimmed = buf_lines[j]:match("^%s*(.-)%s*$")
        if prev_trimmed and prev_trimmed ~= "" then
          prev_marked = marks[j] ~= nil
          break
        end
      end

      for j = i + 1, #buf_lines do
        local next_trimmed = buf_lines[j]:match("^%s*(.-)%s*$")
        if next_trimmed and next_trimmed ~= "" then
          next_marked = marks[j] ~= nil
          break
        end
      end

      if prev_marked and next_marked then
        marks[i] = "closer"
      end
    end
  end

  return marks, raw_hits
end

-- =============================================================================
-- 4. LOGGING HELPERS
-- =============================================================================

---Generates formatted debug report
---@param file_path string
---@param lines string[]
---@param marks table<integer, MarkReason>
---@param raw_hits table<integer, number|nil>
---@return string
local function format_report(file_path, lines, marks, raw_hits)
  local output = {}
  table.insert(output, "FILE: " .. file_path)
  table.insert(output, string.rep("-", 80))
  table.insert(output, string.format("%-5s | %-5s | %-5s | %-15s | %s",
    "LINE", "JSON", "MARK", "REASON", "CONTENT"))
  table.insert(output, string.rep("-", 80))

  for i, content in ipairs(lines) do
    local reason = marks[i] or ""
    local mark_char = reason ~= "" and "[x]" or "[ ]"
    local raw_val = raw_hits[i]
    local raw_str = (raw_val == vim.NIL or raw_val == nil) and "-"
        or tostring(raw_val)

    if content:match("%S") or raw_val ~= nil then
      table.insert(output, string.format("%-5d | %-5s | %-5s | %-15s | %s",
        i, raw_str, mark_char, reason, content))
    end
  end
  table.insert(output, "\n")
  return table.concat(output, "\n")
end

-- =============================================================================
-- 5. RENDER & SERVICE
-- =============================================================================

local SIGN_GROUP = 'Hotlines'
local SIGN_NAME  = 'HotlinesSign'
local HL_GROUP   = 'HotlinesHit'

---Creates highlight groups used by the plugin
local function define_highlights()
  vim.api.nvim_set_hl(0, HL_GROUP, { fg = Config.color, bg = nil })
end

---Defines the sign appearing in sign column for covered lines
local function define_sign()
  vim.fn.sign_define(SIGN_NAME, { text = '┃', texthl = HL_GROUP })
end

---Main rendering: places signs on covered lines in current buffer
local function render()
  if not State.enabled then return end
  local buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(buf)

  for _, pat in ipairs(Config.ignored) do
    if file_path:match(pat) then
      vim.fn.sign_unplace(SIGN_GROUP, { buffer = buf })
      return
    end
  end

  local data = load_data()
  vim.fn.sign_unplace(SIGN_GROUP, { buffer = buf })

  if data and data[file_path] then
    local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local marks = M.get_lines_to_mark(buf_lines, data[file_path].lines or {})
    for lnum, _ in pairs(marks) do
      vim.fn.sign_place(0, SIGN_GROUP, SIGN_NAME, buf, { lnum = lnum, priority = 10 })
    end
  end
end

---Starts file watching service for coverage file changes
local function start_service()
  if not State.enabled then return end

  if vim.fn.filereadable(Config.file) == 0 then
    local fd = io.open(Config.file, "w")
    if fd then fd:write("{}"); fd:close() end
  end

  render()
  State.watcher:start(Config.file, {}, vim.schedule_wrap(function()
    render()
    State.watcher:stop()
    start_service()
  end))
end

-- =============================================================================
-- 6. COMMANDS
-- =============================================================================

---Handler for log subcommand - generates debug file
local function generate_single_log()
  local buf = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(buf)
  local data = load_data()

  if not data then print("No coverage data file found."); return end
  local file_data = data[file_path] and data[file_path].lines or {}

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local marks, raw_hits = M.get_lines_to_mark(lines, file_data)

  local outfile = vim.fn.getcwd() .. "/cov_debug.txt"
  local f = io.open(outfile, "w")
  if not f then print("Error opening " .. outfile); return end

  f:write(format_report(file_path, lines, marks, raw_hits))
  f:close()
  print("Debug info saved to: " .. outfile)
  vim.cmd("edit " .. outfile)
end

---Helper to reset coverage file to empty JSON
local function reset_coverage_file()
  local fd = io.open(Config.file, "w")
  if fd then fd:write("{}"); fd:close() end
end

---@type table<string, fun()>
local subcommands = {
  enable = function()
    if not State.enabled then
      State.enabled = true
      reset_coverage_file()
      start_service()
    end
  end,
  disable = function()
    State.enabled = false
    State.watcher:stop()
    vim.fn.sign_unplace(SIGN_GROUP)
    reset_coverage_file()
  end,
  reset = function()
    vim.fn.sign_unplace(SIGN_GROUP)
    reset_coverage_file()
  end,
  log = generate_single_log,
}

---Returns list of available subcommands for completion
---@param arg_lead string
---@return string[]
local function complete_subcommands(arg_lead)
  local completions = {}
  for cmd, _ in pairs(subcommands) do
    if cmd:find("^" .. arg_lead) then
      table.insert(completions, cmd)
    end
  end
  table.sort(completions)
  return completions
end

---Handles the :Hotlines command with subcommands
---@param opts {args: string}
local function handle_command(opts)
  local subcmd = opts.args:match("^%s*(%S+)")
  if not subcmd or subcmd == "" then
    print("Usage: :Hotlines <enable|disable|reset|log>")
    return
  end

  local handler = subcommands[subcmd]
  if handler then
    handler()
  else
    print("Unknown subcommand: " .. subcmd .. ". Available: enable, disable, reset, log")
  end
end

local AUGROUP = vim.api.nvim_create_augroup('Hotlines', { clear = true })

---Creates user command and autocmds
local function create_commands()
  vim.api.nvim_clear_autocmds({ group = AUGROUP })
  vim.api.nvim_create_autocmd("BufEnter", { group = AUGROUP, callback = render })

  vim.api.nvim_create_user_command('Hotlines', handle_command, {
    nargs = 1,
    complete = function(arg_lead, _, _)
      return complete_subcommands(arg_lead)
    end,
  })
end

-- =============================================================================
-- 7. INITIALIZATION
-- =============================================================================

---Reads configuration from vim.g.hotlines if available
---@return HotlinesConfig
local function read_vim_g_config()
  local g_config = vim.g.hotlines
  if type(g_config) == "table" then
    return vim.tbl_deep_extend("force", Config, g_config)
  end
  return Config
end

---Initializes the plugin (called automatically or via setup)
function M.init()
  if State.initialized then return end
  State.initialized = true

  Config = read_vim_g_config()
  define_highlights()
  define_sign()
  create_commands()
  start_service()
end

---Configure the plugin (optional - can also use vim.g.hotlines)
---@param opts HotlinesConfig|nil
function M.setup(opts)
  if opts then
    Config = vim.tbl_deep_extend("force", Config, opts)
  end
  M.init()
end

-- =============================================================================
-- 8. TEST EXPORTS (internal functions exposed for testing)
-- =============================================================================

M._test = {
  is_continuation = is_continuation,
  is_open_statement = is_open_statement,
  is_block_closer = is_block_closer,
  format_report = format_report,
  load_data = load_data,
  render = render,
  start_service = start_service,
  define_highlights = define_highlights,
  define_sign = define_sign,
  create_commands = create_commands,
  handle_command = handle_command,
  subcommands = subcommands,
  get_config = function() return Config end,
  get_state = function() return State end,
  set_config = function(c) Config = c end,
  set_state = function(s) State = s end,
  reset_state = function()
    State.initialized = false
    State.enabled = true
  end,
  SIGN_GROUP = SIGN_GROUP,
  SIGN_NAME = SIGN_NAME,
  HL_GROUP = HL_GROUP,
}

return M
