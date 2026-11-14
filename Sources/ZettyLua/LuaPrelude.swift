extension LuaRuntime {

    /// What Settings → Scripting → Create init.lua writes: one action, one
    /// binding, one handler. `d` is free in the default prefix table.
    public static let starterFile = #"""
    -- Zetty init.lua: runs at launch and whenever you save this file.
    -- Scripting is experimental; see "Scripting" in Zetty's README.

    -- An action: shows in ⌘K by its title, runs with `zetty do dev`.
    zetty.action{
      name = "dev",
      title = "Split for a Dev Server",
      run = function(ctx)
        local right = zetty.split{ pane = ctx.pane, direction = "right" }
        zetty.send{ pane = right, text = "echo start your dev server here", enter = true }
      end,
    }

    -- A key: the prefix (⌃B), then d.
    zetty.bind("prefix>d", "dev")

    -- An event: a banner when an agent is waiting on you.
    zetty.on("agent.status", function(e)
      if e.status == "needsAttention" then
        zetty.notify{ title = e.project, text = (e.agent or "An agent") .. " is waiting on you" }
      end
    end)
    """#

    /// Builds the `zetty` table. Arguments: raw(verb, arg), log(text), the
    /// config directory (for `require`).
    ///
    /// Returns the internals table Swift calls into (`run`, `emit`,
    /// `manifest`, `render`, `gc`). Swift keeps it in the registry, so a
    /// script that reassigns or nils the `zetty` global cannot break the app.
    /// Every function here refers to the local `Z`, never the global, for the
    /// same reason.
    static let prelude = #"""
    local raw, log, dir = ...

    -- Calls that wait for a command run outside the time budget and would
    -- freeze Zetty; os.exit would quit it with every pane inside.
    os.execute = function() error("os.execute blocks Zetty; use zetty.exec(cmd, callback)", 2) end
    io.popen = function() error("io.popen blocks Zetty; use zetty.exec(cmd, callback)", 2) end
    os.exit = function() error("os.exit would quit Zetty; it is disabled in init.lua", 2) end

    -- Plain .lua modules from the config directory only. C modules would need
    -- the app to drop library validation.
    package.cpath = ""
    package.loadlib = function() error("C modules are not supported in init.lua", 2) end
    package.path = dir and (dir .. "/?.lua;" .. dir .. "/?/init.lua") or ""

    local Z = { config_dir = dir }
    zetty = Z
    local actions, order, binds, handlers = {}, {}, {}, {}

    local function inspect(v, depth, seen)
      depth, seen = depth or 0, seen or {}
      local t = type(v)
      if t == "string" then return string.format("%q", v) end
      if t ~= "table" then return tostring(v) end
      if seen[v] then return "<cycle>" end
      if depth > 6 then return "{...}" end
      seen[v] = true
      local parts, n = {}, #v
      for i = 1, n do parts[#parts + 1] = inspect(v[i], depth + 1, seen) end
      local keys = {}
      for k in pairs(v) do
        if not (math.type(k) == "integer" and k >= 1 and k <= n) then keys[#keys + 1] = k end
      end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        local name = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k
          or "[" .. inspect(k, depth + 1, seen) .. "]"
        parts[#parts + 1] = name .. " = " .. inspect(v[k], depth + 1, seen)
      end
      seen[v] = nil
      if #parts == 0 then return "{}" end
      return "{ " .. table.concat(parts, ", ") .. " }"
    end
    Z.inspect = inspect

    function Z.log(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
      log(table.concat(parts, " "))
    end
    print = Z.log

    function Z.action(spec)
      if type(spec) ~= "table" then error("zetty.action expects a table", 2) end
      if type(spec.name) ~= "string" or spec.name == "" then error("zetty.action needs a name", 2) end
      if type(spec.run) ~= "function" then error("zetty.action needs a run function", 2) end
      if not actions[spec.name] then order[#order + 1] = spec.name end
      actions[spec.name] = { title = spec.title or spec.name, run = spec.run }
    end

    function Z.bind(chord, action)
      if type(chord) ~= "string" or type(action) ~= "string" then
        error("zetty.bind expects (chord, action-name)", 2)
      end
      binds[#binds + 1] = { chord = chord, action = action }
    end

    function Z.on(event, fn)
      if type(event) ~= "string" or type(fn) ~= "function" then
        error("zetty.on expects (event, function)", 2)
      end
      handlers[event] = handlers[event] or {}
      table.insert(handlers[event], fn)
    end

    for _, verb in ipairs({ "split", "send", "new_tab", "focus", "close", "notify", "status" }) do
      Z[verb] = function(arg)
        local result, err = raw(verb, arg)
        if err ~= nil then error("zetty." .. verb .. ": " .. err, 2) end
        return result
      end
    end

    local function run(name, ctx)
      local action = actions[name]
      if not action then error("no action named '" .. tostring(name) .. "'", 3) end
      return action.run(ctx)
    end

    -- From Lua: ctx.source says the action was started by another action.
    function Z.run(name, ctx)
      ctx = ctx or {}
      ctx.source = ctx.source or "lua"
      return run(name, ctx)
    end

    -- Timers: Swift owns the clock, Lua owns the callbacks.
    local callbacks = {}

    local function schedule(name, seconds, fn, repeats)
      local id, err = raw("_after", { seconds = seconds, repeats = repeats })
      if err ~= nil then error(name .. ": " .. err, 3) end
      callbacks[id] = { fn = fn, repeats = repeats }
      return {
        cancel = function()
          if callbacks[id] then
            callbacks[id] = nil
            raw("_cancel", id)
          end
        end,
      }
    end

    function Z.after(seconds, fn)
      if type(seconds) ~= "number" or seconds < 0 or type(fn) ~= "function" then
        error("zetty.after expects (seconds, function)", 2)
      end
      return schedule("zetty.after", seconds, fn, false)
    end

    function Z.every(seconds, fn)
      if type(seconds) ~= "number" or type(fn) ~= "function" then
        error("zetty.every expects (seconds, function)", 2)
      end
      if seconds < 1 then error("zetty.every: interval must be at least 1 second", 2) end
      return schedule("zetty.every", seconds, fn, true)
    end

    -- Shell commands run off the main thread; the callback runs when one ends.
    local pending = {}
    local badCommand = "zetty.exec expects a command string or an array of strings"

    function Z.exec(cmd, opts, fn)
      if fn == nil and type(opts) == "function" then opts, fn = nil, opts end
      if type(cmd) == "table" then
        if #cmd == 0 then error(badCommand, 2) end
        for _, part in ipairs(cmd) do
          if type(part) ~= "string" then error(badCommand, 2) end
        end
      elseif type(cmd) ~= "string" then
        error(badCommand, 2)
      end
      if opts ~= nil and type(opts) ~= "table" then error("zetty.exec: opts must be a table", 2) end
      if type(fn) ~= "function" then error("zetty.exec needs a callback function", 2) end
      opts = opts or {}
      if opts.cwd ~= nil and type(opts.cwd) ~= "string" then error("zetty.exec: cwd must be a string", 2) end
      if opts.timeout ~= nil and (type(opts.timeout) ~= "number" or opts.timeout <= 0) then
        error("zetty.exec: timeout must be a positive number of seconds", 2)
      end
      if opts.env ~= nil then
        if type(opts.env) ~= "table" then error("zetty.exec: env must be a table", 2) end
        for k, v in pairs(opts.env) do
          if type(k) ~= "string" or type(v) ~= "string" then error("zetty.exec: env keys and values must be strings", 2) end
        end
      end
      local id, err = raw("_exec", { cmd = cmd, cwd = opts.cwd, timeout = opts.timeout, env = opts.env })
      if err ~= nil then error("zetty.exec: " .. err, 2) end
      pending[id] = fn
      return {
        cancel = function()
          if pending[id] then
            pending[id] = nil
            raw("_cancel_exec", id)
          end
        end,
      }
    end

    local internals = {}

    -- Returns the callback's error, or nil.
    function internals.exec_done(id, result)
      local fn = pending[id]
      if not fn then return nil end
      pending[id] = nil
      local ok, err = pcall(fn, result)
      if not ok then return tostring(err) end
      return nil
    end

    -- Returns the callback's error, or nil.
    function internals.fire(id)
      local entry = callbacks[id]
      if not entry then return nil end
      if not entry.repeats then callbacks[id] = nil end
      local ok, err = pcall(entry.fn)
      if not ok then return tostring(err) end
      return nil
    end

    -- From Swift: ctx is passed through as given (it carries its own source).
    function internals.run(name, ctx) return run(name, ctx or {}) end

    -- One handler's error does not stop the others; the errors come back
    -- to Swift, which reports them.
    function internals.emit(event, payload)
      local failures = {}
      for _, fn in ipairs(handlers[event] or {}) do
        local ok, err = pcall(fn, payload)
        if not ok then failures[#failures + 1] = "zetty.on('" .. event .. "'): " .. tostring(err) end
      end
      return failures
    end

    function internals.manifest()
      local list = {}
      for _, name in ipairs(order) do list[#list + 1] = { name = name, title = actions[name].title } end
      return { actions = list, binds = binds }
    end

    function internals.render(v)
      if type(v) == "string" then return v end
      return inspect(v)
    end

    -- A C function, so calling it runs no Lua instructions and the count
    -- hook (which raises the memory error) cannot fire inside it.
    internals.gc = collectgarbage

    return internals
    """#
}
