package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Privilege = require("wtop.privilege")

local function environment(values)
    return function(name) return values[name] end
end

local user = Privilege.identity({
    native = { uid = function() return 1000, 1000 end },
    getenv = environment({ SUDO_UID = "0" }),
})
assert(user.mode == "user" and not user.root and not user.elevated)
assert(not user.via_sudo and user.original_uid == nil,
    "unprivileged processes must not trust a spoofed SUDO_UID")

local sudo_root = Privilege.identity({
    native = { uid = function() return 0, 0 end },
    getenv = environment({ SUDO_UID = "1000" }),
})
assert(sudo_root.mode == "root" and sudo_root.root and sudo_root.elevated)
assert(sudo_root.via_sudo and sudo_root.original_uid == 1000)

local direct_root = Privilege.identity({
    native = { uid = function() return 0, 0 end },
    getenv = environment({}),
})
assert(direct_root.root and not direct_root.via_sudo and direct_root.original_uid == nil)

local fallback_root = Privilege.identity({
    native = {},
    read_status = function()
        return "Name:\twtop\nUid:\t1000\t0\t0\t0\n"
    end,
    getenv = environment({ SUDO_UID = "1000" }),
})
assert(fallback_root.root and fallback_root.uid == 1000 and fallback_root.effective_uid == 0)
assert(fallback_root.via_sudo and fallback_root.mode == "root")
local partial_native_identity = Privilege.identity({
    native = { uid = function() return -1, 0 end },
    read_status = function() return "Uid:\t1234\t1234\t1234\t1234\n" end,
    getenv = environment({}),
})
assert(partial_native_identity.uid == 1234 and partial_native_identity.effective_uid == 0,
    "a valid native UID field must be retained while the invalid field uses /proc fallback")

local throwing_native_identity = Privilege.identity({
    native = { uid = function() error("injected uid failure") end },
    read_status = function() return "Name:\twtop\nUid:\t2000\t2001\t2001\t2001\n" end,
    getenv = environment({}),
})
assert(throwing_native_identity.uid == 2000 and throwing_native_identity.effective_uid == 2001)
assert(throwing_native_identity.mode == "user" and not throwing_native_identity.root)

local unknown_identity = Privilege.identity({
    native = { uid = function() return 0 / 0, math.huge end },
    read_status = function() error("injected status failure") end,
    getenv = environment({ SUDO_UID = "1000" }),
})
assert(unknown_identity.mode == "unknown" and unknown_identity.uid == nil)
assert(unknown_identity.effective_uid == nil and not unknown_identity.via_sudo)

assert(Privilege.parse_status_uids("Uid:\t4294967296\t0\t0\t0\n") == nil)
local maximum_uid, effective_zero = Privilege.parse_status_uids(
    "Name:\twtop\nUid:\t4294967295\t0\t0\t0\n")
assert(maximum_uid == 4294967295 and effective_zero == 0)
assert(Privilege.parse_status_uids("Uid:\t-1\t0\t0\t0\n") == nil)
assert(Privilege.parse_status_uids("Uid:\t1.5\t0\t0\t0\n") == nil)
assert(Privilege.parse_status_uids(string.rep("x", 256 * 1024 + 1)) == nil)
for _, spoofed_uid in ipairs({ "-1", "+1", "1.0", "4294967296", "1\0ignored",
    string.rep("1", 33) }) do
    local identity = Privilege.identity({
        native = { uid = function() return 0, 0 end },
        getenv = environment({ SUDO_UID = spoofed_uid }),
    })
    assert(not identity.via_sudo and identity.original_uid == nil)
end

local parsed = assert(Privilege.parse_proc_cmdline(
    "/usr/bin/lua\0-e\0loader code\0/app/wtop.lua\0--sudo\0a;b 'c' 中文\0"))
assert(#parsed == 6 and parsed[6] == "a;b 'c' 中文")
local empty_argument = assert(Privilege.parse_proc_cmdline("/bin/wtop\0\0--snapshot\0"))
assert(#empty_argument == 3 and empty_argument[2] == "",
    "empty arguments are data and must survive the NUL-delimited parse")
assert(Privilege.parse_proc_cmdline("missing terminator") == nil)
assert(Privilege.parse_proc_cmdline("\0") == nil)
local maximum_original_arguments = assert(Privilege.parse_proc_cmdline(
    "/bin/wtop\0" .. string.rep("x\0", 508)))
assert(#maximum_original_arguments == 509,
    "509 original arguments plus the three sudo arguments fit the native 512-argument bound")
local too_many_arguments, too_many_error = Privilege.parse_proc_cmdline(
    "/bin/wtop\0" .. string.rep("x\0", 509))
assert(too_many_arguments == nil and too_many_error == "current command has too many arguments")
local command_byte_limit = 960 * 1024
local maximum_command = assert(Privilege.parse_proc_cmdline(
    "/" .. string.rep("x", command_byte_limit - 2) .. "\0"))
assert(#maximum_command == 1)
assert(Privilege.parse_proc_cmdline(
    "/" .. string.rep("x", command_byte_limit - 1) .. "\0") == nil)
assert(Privilege.parse_proc_cmdline(42) == nil)

local fake = {
    uid = function() return 1000, 1000 end,
    path_type = function(path, follow)
        assert(follow == true)
        return path == "/usr/bin/sudo" and "regular" or nil
    end,
    access = function(path, mode)
        return path == "/usr/bin/sudo" and mode == "x"
    end,
    readfile = function(path, limit)
        assert(path == "/proc/self/cmdline" and limit == 960 * 1024)
        return "lua\0-e\0package.path='trusted'\0/opt/wtop.lua\0--sudo\0--theme\0water-dark\0"
    end,
    readlink = function(path)
        assert(path == "/proc/self/exe")
        return "/usr/bin/lua5.5"
    end,
}

local command, clean_environment = assert(Privilege.elevation_command({
    native = fake,
    getenv = environment({
        TERM = "xterm-256color",
        COLORTERM = "truecolor",
        LANG = "zh_CN.UTF-8",
        LC_ALL = "C.UTF-8",
        LC_CTYPE = "zh_CN.UTF-8",
        NO_COLOR = "",
        LUA_PATH = "/tmp/attacker/?.lua",
        LD_PRELOAD = "/tmp/attacker.so",
        XDG_CONFIG_HOME = "/home/user/.config",
    }),
}))
assert(command[1] == "/usr/bin/sudo" and command[2] == "-H" and command[3] == "--")
assert(command[4] == "/usr/bin/lua5.5")
assert(command[5] == "-e" and command[6] == "package.path='trusted'")
assert(command[8] == "--sudo" and command[10] == "water-dark",
    "elevation must preserve the original argv without shell parsing")
local encoded_environment = table.concat(clean_environment, "\n")
assert(encoded_environment:find("PATH=" .. Privilege.SAFE_PATH, 1, true))
assert(encoded_environment:find("TERM=xterm-256color", 1, true))
assert(encoded_environment:find("LANG=zh_CN.UTF-8", 1, true))
assert(encoded_environment:find("COLORTERM=truecolor", 1, true))
assert(encoded_environment:find("LC_ALL=C.UTF-8", 1, true))
assert(encoded_environment:find("LC_CTYPE=zh_CN.UTF-8", 1, true))
assert(encoded_environment:find("NO_COLOR=", 1, true))
for _, forbidden in ipairs({ "LUA_PATH", "LD_PRELOAD", "XDG_CONFIG_HOME" }) do
    assert(not encoded_environment:find(forbidden, 1, true),
        "elevation environment leaked " .. forbidden)
end

local hostile_environment_command, filtered_environment = assert(Privilege.elevation_command({
    native = fake,
    getenv = function(name)
        if name == "TERM" then return "xterm\0LD_PRELOAD=bad" end
        if name == "LANG" then return string.rep("x", 4097) end
        if name == "LC_ALL" then error("injected getenv failure") end
        return nil
    end,
}))
assert(hostile_environment_command[1] == "/usr/bin/sudo")
assert(#filtered_environment == 1 and filtered_environment[1] == "PATH=" .. Privilege.SAFE_PATH,
    "invalid inherited environment values must be dropped, not truncated")

local checked_candidates = {}
local nix_fake = {}
for key, value in pairs(fake) do nix_fake[key] = value end
nix_fake.path_type = function(path, follow)
    assert(follow == true)
    checked_candidates[#checked_candidates + 1] = path
    return path == "/run/wrappers/bin/sudo" and "regular" or "missing"
end
nix_fake.access = function(path, mode)
    assert(mode == "x")
    return path == "/run/wrappers/bin/sudo"
end
local nix_command = assert(Privilege.elevation_command({
    native = nix_fake,
    getenv = environment({ PATH = "/tmp/attacker" }),
}))
assert(nix_command[1] == "/run/wrappers/bin/sudo")
assert(table.concat(checked_candidates, ",")
    == "/usr/bin/sudo,/bin/sudo,/run/wrappers/bin/sudo")

local path_only_sudo = Privilege.elevation_command({
    native = {
        path_type = function(path)
            return path == "/tmp/attacker/sudo" and "regular" or "missing"
        end,
        access = function(path) return path == "/tmp/attacker/sudo" end,
    },
    getenv = environment({ PATH = "/tmp/attacker" }),
})
assert(path_only_sudo == nil,
    "privilege elevation must never search a caller-controlled PATH for sudo")

local executed_command, executed_environment
local elevated, elevation_error = Privilege.elevate({
    native = fake,
    getenv = environment({ TERM = "xterm" }),
    execve = function(argv, env)
        executed_command, executed_environment = argv, env
        return nil, "injected exec failure"
    end,
})
assert(elevated == nil and elevation_error == "injected exec failure")
assert(executed_command[1] == "/usr/bin/sudo" and executed_environment[1]:match("^PATH="))

local unavailable_exec, unavailable_exec_error = Privilege.elevate({
    native = fake,
    getenv = environment({}),
})
assert(unavailable_exec == nil and unavailable_exec_error == "native execve is unavailable")

local throwing_exec, throwing_exec_error = Privilege.elevate({
    native = fake,
    getenv = environment({}),
    execve = function() error("injected exec exception") end,
})
assert(throwing_exec == nil and throwing_exec_error:find("injected exec exception", 1, true))

local returned_exec, returned_exec_error = Privilege.elevate({
    native = fake,
    getenv = environment({}),
    execve = function() return true end,
})
assert(returned_exec == nil
    and returned_exec_error == "sudo exec returned without replacing the process")

local root_exec_called = false
local already_root, root_reason = Privilege.elevate({
    native = { uid = function() return 0, 0 end },
    getenv = environment({}),
    execve = function() root_exec_called = true end,
})
assert(already_root and root_reason == "already_root" and not root_exec_called)

local missing_sudo = Privilege.elevation_command({
    native = {
        path_type = function() return "missing" end,
        access = function() return false end,
    },
    getenv = environment({}),
})
assert(missing_sudo == nil)

local invalid_cmdline_backend = {}
for key, value in pairs(fake) do invalid_cmdline_backend[key] = value end
invalid_cmdline_backend.readfile = function() return "lua without terminator" end
local invalid_cmdline, _, invalid_cmdline_error = Privilege.elevation_command({
    native = invalid_cmdline_backend, getenv = environment({}),
})
assert(invalid_cmdline == nil and invalid_cmdline_error == "invalid /proc/self/cmdline")

local invalid_executable_backend = {}
for key, value in pairs(fake) do invalid_executable_backend[key] = value end
invalid_executable_backend.readlink = function() return "relative/lua" end
local invalid_executable, _, invalid_executable_error = Privilege.elevation_command({
    native = invalid_executable_backend, getenv = environment({}),
})
assert(invalid_executable == nil
    and invalid_executable_error:find("cannot resolve current executable", 1, true))

local throwing_read_backend = {}
for key, value in pairs(fake) do throwing_read_backend[key] = value end
throwing_read_backend.readfile = function() error("injected cmdline failure") end
local unreadable_command, _, unreadable_error = Privilege.elevation_command({
    native = throwing_read_backend, getenv = environment({}),
})
assert(unreadable_command == nil
    and unreadable_error:find("injected cmdline failure", 1, true))

assert(not pcall(Privilege.identity, "invalid"))
assert(not pcall(Privilege.identity, { native = {}, read_status = "invalid" }))
assert(not pcall(Privilege.elevation_command, "invalid"))
assert(not pcall(Privilege.elevate, "invalid"))

return true
