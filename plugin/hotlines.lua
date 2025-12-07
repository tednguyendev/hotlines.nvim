-- Plugin entry point for hotlines.nvim
-- This file is loaded automatically by Neovim and provides lazy initialization

-- Prevent double-loading
if vim.g.loaded_hotlines then
  return
end
vim.g.loaded_hotlines = true

-- Create the :Hotlines command that lazy-loads the plugin
vim.api.nvim_create_user_command('Hotlines', function(opts)
  -- Lazy require the core module only when command is invoked
  require('hotlines.core').init()
  require('hotlines.core')._test.handle_command(opts)
end, {
  nargs = 1,
  complete = function(arg_lead)
    -- Provide completion without loading the full module
    local subcommands = { 'enable', 'disable', 'reset', 'log' }
    local completions = {}
    for _, cmd in ipairs(subcommands) do
      if cmd:find("^" .. arg_lead) then
        table.insert(completions, cmd)
      end
    end
    return completions
  end,
})

-- Auto-initialize on first BufEnter if vim.g.hotlines config exists
-- This allows zero-config usage with vim.g.hotlines = { ... }
vim.api.nvim_create_autocmd('BufEnter', {
  group = vim.api.nvim_create_augroup('HotlinesLazyInit', { clear = true }),
  once = true,
  callback = function()
    -- Only auto-init if user has configured vim.g.hotlines
    if vim.g.hotlines then
      require('hotlines.core').init()
    end
  end,
})
