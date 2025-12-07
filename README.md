# hotlines.nvim

Real-time code coverage for development, not tests.

https://github.com/user-attachments/assets/a8f143f2-ef58-48e7-9cd6-7e6db6d609b7

## Features

- Marks executed lines in real-time as you interact with your app
- Works with any language (tested with Rails)

## Use cases

- Debug without print statements - see which `if`/`else` branch ran
- Find code that never runs
- Manual testing coverage - when you don't have automated tests, see which files and lines your manual testing actually covers

## Limitations

- **Client-side code** - JavaScript running in browser isn't tracked
- **Empty methods** - `def` and `end` always register hits even if the method body is empty
- **Hybrid files** - Templates like ERB or HTML have inconsistent results, better to ignore them
- **Already handled code** - Code guarded by `if true` or conditions already evaluated won't show as executed

## How it works

1. First, you need to set up your framework to capture which lines run and write them to a JSON file (e.g. `tmp/hotlines.json`). See the [Rails example](#example-setup-with-ruby-on-rails) below.
2. The plugin watches that file and marks executed lines
3. As you interact with your app, markers update in real-time

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "tednguyendev/hotlines.nvim", opts = {} }
```

Detailed config:

```lua
require("hotlines").setup({
  -- Path to the coverage JSON file
  file = vim.fn.getcwd() .. '/tmp/hotlines.json',

  -- File patterns to ignore (empty by default)
  ignored = { "%.erb$", "%.html$" },

  -- Highlight color
  color = "#a6e3a1",
})
```

## Example setup with Ruby on Rails

Below is an example of how to generate coverage data for a Rails application. You can adapt this approach for other frameworks.

<details>
<summary>Click to expand Rails setup</summary>

### Step 1: Create the tracer module

Create `lib/hotlines.rb`:

```ruby
require "json"

module Hotlines
  OUTPUT_PATH = Rails.root.join("tmp", "hotlines.json")
  TRACEPOINT_EVENTS = [:line, :class, :end, :call, :return, :b_call, :b_return].freeze

  def self.trace(root_path)
    trace_data = Hash.new { |h, k| h[k] = { "lines" => {} } }

    trace = TracePoint.new(*TRACEPOINT_EVENTS) do |tp|
      if tp.path&.start_with?(root_path) && !tp.path.include?("/vendor/")
        trace_data[tp.path]["lines"][tp.lineno] = (trace_data[tp.path]["lines"][tp.lineno] || 0) + 1
      end
    end

    trace.enable
    begin
      yield
    ensure
      trace.disable
      save(trace_data) if trace_data.any?
    end
  end

  def self.save(new_data)
    File.open(OUTPUT_PATH, File::RDWR | File::CREAT, 0644) do |f|
      f.flock(File::LOCK_EX)

      content = f.read
      existing_data = content.empty? ? {} : JSON.parse(content)

      new_data.each do |filepath, file_data|
        if existing_data.key?(filepath)
          old_lines = existing_data[filepath]["lines"]
          file_data["lines"].each do |lineno, count|
            old_lines[lineno.to_s] = (old_lines[lineno.to_s] || 0) + count
          end
        else
          file_data["lines"] = file_data["lines"].transform_keys(&:to_s)
          existing_data[filepath] = file_data
        end
      end

      f.rewind
      f.write(existing_data.to_json)
      f.truncate(f.pos)
      f.flock(File::LOCK_UN)
    end
  rescue => e
  end
end
```

This outputs a JSON file with the following structure:

```json
{
  "/absolute/path/to/file.rb": {
    "lines": {
      "1": 1,
      "2": 0,
      "3": 5
    }
  }
}
```

### Step 2: Create the middleware

Create `lib/middleware/hotlines.rb`:

```ruby
require_relative "../hotlines"

module Middleware
  class Hotlines
    IGNORE_PATHS = ["/cable", "/assets", "/rails/active_storage", "/favicon.ico"].freeze

    def initialize(app)
      @app = app
      @root_path = Rails.root.to_s
    end

    def call(env)
      req = Rack::Request.new(env)

      if IGNORE_PATHS.any? { |path| req.path.start_with?(path) }
        return @app.call(env)
      end

      ::Hotlines.trace(@root_path) { @app.call(env) }
    end
  end
end
```

### Step 3: Register the middleware

Add to `config/environments/development.rb`:

```ruby
require Rails.root.join("lib/middleware/hotlines")

Rails.application.configure do
  config.middleware.use Middleware::Hotlines
end
```

### Step 4 (Optional): Track background jobs

Create `config/initializers/hotlines_jobs.rb`:

```ruby
if Rails.env.development? || Rails.env.test?
  require Rails.root.join("lib/hotlines")

  module HotlinesJob
    extend ActiveSupport::Concern

    included do
      around_perform :track_coverage
    end

    private

    def track_coverage(&block)
      Hotlines.trace(Rails.root.to_s, &block)
    end
  end

  ActiveSupport.on_load(:active_job) do
    include HotlinesJob
  end
end
```

</details>

## Commands

| Command | Description |
|---------|-------------|
| `:Hotlines enable` | Enable coverage display |
| `:Hotlines disable` | Disable coverage display |
| `:Hotlines reset` | Clear all highlights and reset coverage file |
| `:Hotlines log` | Generate debug log for current file |

Tab completion is available for all subcommands.

## Running Tests

```bash
nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/"
```

## License

MIT
