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
      --diagnose         Print capability diagnostics and exit
      --snapshot         Print one machine-readable snapshot and exit
      --agent            Print compact LLM/agent context JSON and exit
      --sudo             Restart through sudo on Linux
      --elevate          Alias for --sudo
      --lang LOCALE      Select UI locale (for example zh-CN or en-US)
      --theme NAME       Select theme
      --interval MS      Sampling interval (100..10000, default 1000)
      --safe-mode        Disable optional external helper commands
      --no-color         Disable terminal colors

Interactive defaults: F1 help, 1..8 tabs, f update rate, Tab/Shift-Tab focus, q quit.
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
        elseif item == "--agent" then
            local ok, command_error = select_command("agent", item)
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

local function run_agent(options)
    local application = require("wtop.application")
    return application.agent(options)
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
        io.write(version.name, " ", version.version, "\n")
        return 0
    elseif options.command == "diagnose" then
        return run_diagnose(options)
    elseif options.command == "snapshot" then
        return run_snapshot(options)
    elseif options.command == "agent" then
        return run_agent(options)
    end
    return run_tui(options)
end

return M
