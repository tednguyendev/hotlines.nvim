---@class Hotlines
---@field setup fun(opts: HotlinesConfig|nil) Configure and initialize the plugin
---@field get_lines_to_mark fun(buf_lines: string[], file_coverage: table<string, number>): table<integer, MarkReason>, table<integer, number|nil>
---@field _test table Test exports

local M = {}

---Configure the plugin (optional - can also use vim.g.hotlines)
---@param opts HotlinesConfig|nil
function M.setup(opts)
  require("hotlines.core").setup(opts)
end

---Main algorithm: determines which lines to mark as covered
---@param buf_lines string[]
---@param file_coverage table<string, number>
---@return table<integer, MarkReason> marks
---@return table<integer, number|nil> raw_hits
function M.get_lines_to_mark(buf_lines, file_coverage)
  return require("hotlines.core").get_lines_to_mark(buf_lines, file_coverage)
end

-- Lazy load test exports
setmetatable(M, {
  __index = function(_, key)
    if key == "_test" then
      return require("hotlines.core")._test
    end
  end,
})

return M
