local version = require("wtop.version")
local I18n = require("wtop.i18n")
local Platform = require("wtop.platform")
local Privilege = require("wtop.privilege")
local Theme = require("wtop.ui.theme")

local M = {}

local HELP = [[
Usage: wtop [OPTIONS]

WaterRun's top: a responsive system monitor.

Options:
  -h, --help             Show this help
  -V, --version          Show version
      --export-layout F  Write the current layout to F as schema-v2 YAML
      --import-layout F  Validate F and install it as the persisted layout
      --migrate-layout   Rewrite the persisted layout in the current schema
      --diagnose         Print capability diagnostics and exit
      --snapshot         Print one machine-readable snapshot and exit
      --stream           Print snapshots as JSON Lines until stopped
      --record           Write a replay recording to redirected stdout
      --replay FILE      Open a recording in the offline interactive viewer
      --replay-frame N   Start at frame N; also works with --snapshot/--agent/--report
      --record-limit-mib N
                         With --record: size limit (1..16384, default 256 MiB)
      --count N          With --stream or --record: stop after N records (1..1000000)
      --report           Print a readable hardware report in Markdown
      --memory-bandwidth Print one on-demand memory bandwidth measurement as JSON
      --memory-pmu NAME  With --memory-bandwidth: select a PMU, or list available PMUs
      --unmask-remote-addresses
                         With --snapshot, --stream or --record: keep full remote socket addresses
      --agent            Print compact LLM/agent context JSON and exit
      --sudo             Restart through sudo on Linux
      --elevate          Alias for --sudo
      --lang LOCALE      Select UI locale (for example zh-CN or en-US)
      --theme NAME       Select theme
      --interval MS      Sampling interval (100..10000, default 1000)
      --safe-mode        Disable optional external helper commands
      --no-color         Disable terminal colors

Interactive defaults: F1 help, 1..0 tabs, f update rate, Tab/Shift-Tab focus, q quit.
]]

local function option_value(argv, index, name)
    local value = argv[index + 1]
    if type(value) ~= "string" or value:sub(1, 1) == "-" then
        return nil, index, name .. " requires a value"
    end
    return value, index + 1
end

local function normalize_theme(value)
    for _, name in ipairs(Theme.available()) do
        if value == name then return value end
    end
    return nil, "--theme must be one of: " .. table.concat(Theme.available(), ", ")
end

function M.parse(argv)
    if type(argv) ~= "table" then return nil, "argument vector must be a table" end
    local options = {
        command = "tui",
        interval_ms = 1000,
        color = true,
        safe_mode = false,
        explicit = {},
    }

    local command_option
    local elevation_option
    local function select_command(command, item)
        if command_option then
            return nil, "command options cannot be combined: " .. command_option .. " and " .. item
        end
        command_option = item
        options.command = command
        return true
    end

    local index = 1
    while index <= #argv do
        local item = argv[index]
        if type(item) ~= "string" then
            return nil, "argument " .. index .. " must be a string"
        end
        if item == "-h" or item == "--help" then
            local ok, command_error = select_command("help", item)
            if not ok then return nil, command_error end
        elseif item == "-V" or item == "--version" then
            local ok, command_error = select_command("version", item)
            if not ok then return nil, command_error end
        elseif item == "--diagnose" then
            local ok, command_error = select_command("diagnose", item)
            if not ok then return nil, command_error end
        elseif item == "--snapshot" then
            local ok, command_error = select_command("snapshot", item)
            if not ok then return nil, command_error end
        elseif item == "--stream" then
            local ok, command_error = select_command("stream", item)
            if not ok then return nil, command_error end
        elseif item == "--record" then
            local ok, command_error = select_command("record", item)
            if not ok then return nil, command_error end
        elseif item == "--replay" then
            if options.replay_path ~= nil then return nil, "--replay cannot be repeated" end
            local value, next_index, parse_error = option_value(argv, index, item)
            if parse_error then return nil, parse_error end
            if value == "" or value:find("\0", 1, true) then return nil, "invalid recording path" end
            options.replay_path, index = value, next_index
        elseif item == "--replay-frame" then
            if options.replay_frame ~= nil then return nil, "--replay-frame cannot be repeated" end
            local value, next_index, parse_error = option_value(argv, index, item)
            if parse_error then return nil, parse_error end
            local n = value:match("^%d+$") and tonumber(value)
            if not n or n % 1 ~= 0 or n < 1 or n > 1000000 then return nil, "--replay-frame must be an integer from 1 to 1000000" end
            options.replay_frame, index = n, next_index
        elseif item == "--record-limit-mib" then
            if options.record_limit_mib ~= nil then return nil, "--record-limit-mib cannot be repeated" end
            local value, next_index, parse_error = option_value(argv, index, item)
            if parse_error then return nil, parse_error end
            local n = value:match("^%d+$") and tonumber(value)
            if not n or n % 1 ~= 0 or n < 1 or n > 16384 then
                return nil, "--record-limit-mib must be an integer from 1 to 16384"
            end
            options.record_limit_mib, index = n, next_index
        elseif item == "--count" then
            if options.stream_count ~= nil then return nil, "--count cannot be repeated" end
            local value, next_index, parse_error = option_value(argv, index, item)
            if parse_error then return nil, parse_error end
            local count = value:match("^%d+$") and tonumber(value) or nil
            if not count or count % 1 ~= 0 or count < 1 or count > 1000000 then
                return nil, "--count must be an integer from 1 to 1000000"
            end
            options.stream_count = count
            index = next_index
        elseif item == "--report" then
            local ok, command_error = select_command("report", item)
            if not ok then return nil, command_error end
        elseif item == "--memory-bandwidth" then
            local ok, command_error = select_command("memory_bandwidth", item)
            if not ok then return nil, command_error end
        elseif item == "--memory-pmu" then
            if options.memory_pmu ~= nil then return nil, "--memory-pmu cannot be repeated" end
            local value, next_index, parse_error = option_value(argv, index, item)
            if parse_error then return nil, parse_error end
            if #value == 0 or #value > 255 or not value:match("^[A-Za-z0-9_][A-Za-z0-9_.%-]*$")
                or value == "." or value == ".." then
                return nil, "--memory-pmu must be a PMU name or list"
            end
            options.memory_pmu = value
            index = next_index
        elseif item == "--unmask-remote-addresses" then
            if options.include_remote_addresses then
                return nil, "--unmask-remote-addresses cannot be repeated"
            end
            options.include_remote_addresses = true
        elseif item == "--agent" then
            local ok, command_error = select_command("agent", item)
            if not ok then return nil, command_error end
        elseif item == "--export-layout" or item == "--import-layout" then
            local value, next_index, parse_error = option_value(argv, index, item)
            if parse_error then
                return nil, parse_error
            end
            local ok, command_error = select_command(
                item == "--export-layout" and "export_layout" or "import_layout",
                item)
            if not ok then return nil, command_error end
            options.layout_path = value
            index = next_index
        elseif item == "--migrate-layout" then
            local ok, command_error = select_command("migrate_layout", item)
            if not ok then return nil, command_error end
        elseif item == "--sudo" or item == "--elevate" then
            if elevation_option then
                return nil, "elevation options cannot be repeated or combined: "
                    .. elevation_option .. " and " .. item
            end
            elevation_option = item
            options.elevate = true
        elseif item == "--safe-mode" then
            options.safe_mode = true
            options.explicit.safe_mode = true
        elseif item == "--no-color" then
            options.color = false
            options.explicit.color = true
        elseif item == "--lang" or item == "--theme" or item == "--interval" then
            local value, next_index, parse_error = option_value(argv, index, item)
            if parse_error then
                return nil, parse_error
            end
            if item == "--lang" then
                local locale, locale_error = I18n.normalize_locale(value)
                if not locale then
                    return nil, "--lang: " .. tostring(locale_error)
                end
                options.locale = locale
                options.explicit.locale = true
            elseif item == "--theme" then
                local theme, theme_error = normalize_theme(value)
                if not theme then return nil, theme_error end
                options.theme = theme
                options.explicit.theme = true
            else
                local interval = value:match("^%d+$") and tonumber(value) or nil
                if not interval or interval % 1 ~= 0 or interval < 100 or interval > 10000 then
                    return nil, "--interval must be an integer from 100 to 10000"
                end
                options.interval_ms = interval
                options.explicit.interval_ms = true
            end
            index = next_index
        elseif item == "--" then
            if index < #argv then
                return nil, "positional arguments are not supported"
            end
        else
            return nil, "unknown option: " .. tostring(item)
        end
        index = index + 1
    end
    if options.include_remote_addresses
        and options.command ~= "snapshot" and options.command ~= "stream" and options.command ~= "record" then
        return nil, "--unmask-remote-addresses requires --snapshot, --stream or --record"
    end
    if options.stream_count and options.command ~= "stream" and options.command ~= "record" then
        return nil, "--count requires --stream or --record"
    end
    if options.record_limit_mib and options.command ~= "record" then return nil, "--record-limit-mib requires --record" end
    if options.replay_path then
        if options.elevate then return nil, "--replay does not use elevation" end
        if not ({ tui=true, snapshot=true, agent=true, report=true })[options.command] then
            return nil, "--replay supports interactive mode, --snapshot, --agent or --report"
        end
    elseif options.replay_frame then return nil, "--replay-frame requires --replay" end
    if options.memory_pmu and options.command ~= "memory_bandwidth" then
        return nil, "--memory-pmu requires --memory-bandwidth"
    end
    return options
end

local function run_diagnose(options)
    local diagnose = require("wtop.diagnose")
    return diagnose.run(options)
end

local function run_snapshot(options)
    local application = require("wtop.application")
    return application.snapshot(options)
end

local function run_stream(options)
    local application = require("wtop.application")
    return application.stream(options)
end

local function run_agent(options)
    local application = require("wtop.application")
    return application.agent(options)
end

local function run_report(options)
    local application = require("wtop.application")
    return application.report(options)
end

local function run_tui(options)
    local application = require("wtop.application")
    return application.run(options)
end

function M.requires_elevation(options, identity)
    return type(options) == "table" and options.elevate == true
        and options.command ~= "help" and options.command ~= "version"
        and type(identity) == "table" and identity.root ~= true
end

function M.run(argv, dependencies)
    dependencies = dependencies or {}
    if type(dependencies) ~= "table" then error("CLI dependencies must be a table", 2) end
    local options, parse_error = M.parse(argv)
    if not options then
        io.stderr:write("wtop: ", parse_error, "\nTry 'wtop --help'.\n")
        return 2
    end

    local platform = dependencies.platform or Platform
    local privilege_module = dependencies.privilege or Privilege
    local require_platform = platform.require_supported or platform.require_linux
    local detected_platform, platform_error = require_platform()
    if platform_error then
        io.stderr:write("wtop: ", platform_error, "\n")
        return 1
    end

    local identity = privilege_module.identity()
    if type(identity) ~= "table" then
        io.stderr:write("wtop: cannot determine process privilege\n")
        return 1
    end
    identity.requested = options.elevate == true
    options.privilege = identity

    if M.requires_elevation(options, identity)
        and type(detected_platform) == "table"
        and detected_platform.sysname ~= "Linux" then
        io.stderr:write("wtop: --sudo is available only on Linux in this build\n")
        return 1
    end

    if M.requires_elevation(options, identity) then
        local elevated, elevation_error = privilege_module.elevate()
        if elevated then return 0 end
        io.stderr:write("wtop: cannot elevate: ", tostring(elevation_error), "\n")
        return 1
    end

    if options.command == "help" then
        io.write(HELP)
        return 0
    elseif options.command == "version" then
        io.write(version.name, " ", version.version)
        if version.revision then io.write(" (rev ", version.revision, ")") end
        -- The native module carries its own source revision and its own version,
        -- both compiled in from the same generator that produces the Lua tree's.
        -- Printing both every time would be noise; printing neither would leave a
        -- version line that reads normally while the binary and the Lua tree
        -- inside it came from different trees.  So only a disagreement is
        -- reported, and the version command is the one place a packager is
        -- guaranteed to look.
        --
        -- The version half of this used to be missing, and the two answers were
        -- printed by two different commands: `--version` took the Lua tree's and
        -- `--diagnose` took the module's, so a release that bumped one and not
        -- the other stated two different versions and neither said so.  Both now
        -- come out of one VERSION file, so a disagreement should be impossible --
        -- and a guard that cannot fire is a guard nobody has tested, which is why
        -- this reports one rather than assuming there is none.
        local native = require("wtop.native")
        if type(native.system_constants) == "function" then
            local called, constants = pcall(native.system_constants)
            local compiled = called and type(constants) == "table"
                and constants.build_revision or nil
            if type(compiled) == "string" and compiled ~= ""
                and compiled ~= version.revision then
                io.write(" [native module rev ", compiled, "]")
            end
        end
        local compiled_version = type(native.VERSION) == "string" and native.VERSION or nil
        if type(compiled_version) == "string" and compiled_version ~= ""
            and compiled_version ~= version.version then
            io.write(" [native module version ", compiled_version, "]")
        end
        io.write("\n")
        return 0
    elseif options.replay_path and options.command ~= "tui" then
        return require("wtop.application").replay(options)
    elseif options.command == "diagnose" then
        return run_diagnose(options)
    elseif options.command == "snapshot" then
        return run_snapshot(options)
    elseif options.command == "stream" then
        return run_stream(options)
    elseif options.command == "record" then
        return require("wtop.application").record(options)
    elseif options.command == "report" then
        return run_report(options)
    elseif options.command == "memory_bandwidth" then
        return require("wtop.application").memory_bandwidth(options)
    elseif options.command == "agent" then
        return run_agent(options)
    elseif options.command == "export_layout" then
        local LayoutCommands = require("wtop.layout_commands")
        local exported, result = LayoutCommands.export(options.layout_path)
        if not exported then
            io.stderr:write("wtop: ", tostring(result), "\n")
            return 1
        end
        io.write("wtop: exported layout to ", tostring(result), "\n")
        return 0
    elseif options.command == "import_layout" then
        local LayoutCommands = require("wtop.layout_commands")
        local imported, result = LayoutCommands.import(options.layout_path)
        if not imported then
            io.stderr:write("wtop: ", tostring(result), "\n")
            return 1
        end
        io.write("wtop: installed layout; the previous file is kept as .bak (",
            tostring(result), ")\n")
        return 0
    elseif options.command == "migrate_layout" then
        local LayoutCommands = require("wtop.layout_commands")
        local migrated, result = LayoutCommands.migrate()
        if not migrated then
            io.stderr:write("wtop: ", tostring(result), "\n")
            return 1
        end
        io.write("wtop: ", tostring(result), "\n")
        return 0
    end
    return run_tui(options)
end

return M
