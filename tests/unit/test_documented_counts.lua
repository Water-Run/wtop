package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

-- How many test files the suite has, as the documents state it.
--
-- This number has been wrong three times in this project's history -- 47, then
-- 50, then 57, then 75, then 82 -- and each time it was fixed by hand and then
-- drifted again on the next increment that added a file.  A count that is
-- corrected by hand and re-broken by the next change is not documentation, it
-- is a recurring chore, so the count is pinned here instead.
--
-- The claims are enumerated rather than discovered by scanning prose.  A scan
-- would have to tell a current claim from a historical one, and the documents
-- are full of deliberately historical counts -- "50 files at the time of that
-- run", "the 73 unit tests that asserted the table's shape before this
-- feature" -- that are correct as written and must not be rewritten to match
-- today.  Enumerating the current claims keeps that distinction explicit, at
-- the cost of a new phrasing not being covered; a wrong number in a phrase
-- this test does not know about is still caught the next time someone re-reads
-- the sentence.

local function read_file(path)
    local handle = assert(io.open(path, "rb"), "cannot read " .. path)
    local body = handle:read("*a")
    handle:close()
    return body
end

local function count_test_files()
    local pipe = assert(io.popen(
        "ls tests/unit/test_*.lua tests/integration/test_*.lua 2>/dev/null | wc -l", "r"))
    local body = pipe:read("*a")
    pipe:close()
    return tonumber(body:match("^%s*(%d+)%s*$"))
end

local total = assert(count_test_files(), "could not count the test files")
assert(total > 0, "the test file count came back empty, so the guard would pass vacuously")

-- The suite this runs as part of has to agree with the Makefile's own glob.
local makefile = read_file("Makefile")
assert(makefile:find("tests/unit/test_*.lua", 1, true) ~= nil
    and makefile:find("tests/integration/test_*.lua", 1, true) ~= nil,
    "the Makefile no longer globs the same test tree this file counted")

local claims = {
    { "docs/ARCHITECTURE.md", "现有的 " .. total .. " 个 Lua 单元/夹具测试文件覆盖" },
    { "docs/CROSS_PLATFORM.md", "当前源码套件包含 " .. total .. " 个 Lua 测试文件" },
    { "docs/PACKAGING.md", "运行这 " .. total .. " 个 Lua 文件" },
    { "docs/PACKAGING.md", total .. " 个 Lua 5.5 单元与夹具测试文件" },
    { "docs/PACKAGING.md", "用系统 Lua 5.4 运行同样的 " .. total .. " 个文件" },
    { "docs/PACKAGING.md", "通过 " .. total .. " 个夹具文件并不是形式化证明" },
    -- These two carried a stale count for two increments.  They were not in this
    -- list, which is the point: the guard is built from an enumeration, and an
    -- enumeration nobody extends does not cover the sentence written next
    -- increment.  Both state the count of the current suite in the same
    -- "currently contains / runs N files" form, so both are pinned here.
    { "docs/PLAN.md", "目前包含 " .. total .. " 个 Lua 5.5 单元/夹具测试文件" },
    { "docs/UI.md", "运行 " .. total .. " 个 Lua 单元/夹具测试文件" },
    -- And this one sat in the *same table* as the row above, one line under a
    -- number this list already covered, carrying 89 while the container was
    -- passing 100.  It read as a current claim -- "the full 89-file Lua test
    -- suite", present tense, no qualifier -- so unlike the aarch64 row below it
    -- it was neither in this list nor in `historical`.  That is the sharpest
    -- statement this file can make about an enumeration: the miss was not in a
    -- document nobody had looked at, it was in a sentence two lines from a
    -- sentence it already guarded.  The run is current, so the count is current
    -- and is pinned here rather than qualified.
    { "docs/CROSS_PLATFORM.md", total .. " 个 Lua 测试文件" },
}

for _, claim in ipairs(claims) do
    local path, phrase = claim[1], claim[2]
    assert(read_file(path):find(phrase, 1, true) ~= nil,
        path .. " no longer states the current test count; expected to find: " .. phrase)
end

-- Historical counts are not drift.  They describe a run that happened, and
-- rewriting them to match today's suite would falsify that record.  Each is
-- pinned with the phrase that makes it historical, so that a future edit which
-- strips the qualification is caught rather than silently making the number
-- look current.
local historical = {
    { "docs/CROSS_PLATFORM.md", "`6702c31` 当时的 139 个 Lua 文件" },
    { "docs/CROSS_PLATFORM.md", "当时运行时为 50 个文件" },
    { "docs/MONITORING.md", "在此功能之前断言表格形状的 73 个单元测试" },
    { "docs/PACKAGING.md", "2026-10-02 那次在 glibc 2.17 上 **通过 120 个测试文件**" },
    -- The count this section used to carry.  It is correct as written, and
    -- rewriting it to match the current suite would falsify the record of a run
    -- that really did stop at 89 and then pass at 90.
    { "docs/PACKAGING.md", "这段话上次写 90 时它不是 89" },
}
for _, entry in ipairs(historical) do
    assert(read_file(entry[1]):find(entry[2], 1, true) ~= nil,
        entry[1] .. " lost a historical count that is correct as written: " .. entry[2])
end

-- The table the miss happened in gets a clause of its own, because an
-- enumeration can only guard the numbers it was told about.  Every suite-size
-- claim anywhere in the validation matrix has to be either one of the current
-- counts pinned above or a count carrying its historical qualifier -- so a
-- number added to that table later is checked against the rule rather than
-- against this file's memory of it.  A dev-host row, a container row and an
-- aarch64 row are three claims written by three people over several increments,
-- and two of the three were correct for different reasons.
local platform_doc = read_file("docs/CROSS_PLATFORM.md")
local matrix = platform_doc:match("## 验证矩阵(.-)\n## ")
    or platform_doc:match("## 验证矩阵(.-)$")
assert(matrix ~= nil, "docs/CROSS_PLATFORM.md no longer has a validation matrix, so "
    .. "this clause has no table to read and would pass by examining nothing")
assert(matrix:find("2026-10-09 核对", 1, true),
    "the older matrix counts need their dated validation context")
local historical_matrix_rows = {
    ["Linux x86_64，CI"] = "120",
    ["Linux aarch64，CI"] = "120",
    ["Linux x86_64，2026-10-09 本地"] = "120",
    ["Linux x86_64"] = "120",
    ["Linux x86_64,旧 libc"] = "120",
    ["Linux x86_64，2026-10-11 sshd 配置"] = "132",
    ["Linux x86_64，2026-10-11 日志摘要"] = "131",
    ["Linux x86_64，2026-10-11 logind"] = "130",
    ["Linux x86_64，2026-10-11 unit journal"] = "129",
    ["Linux x86_64，2026-10-11 systemd unit"] = "128",
    ["Linux x86_64，2026-10-11 本地"] = "126",
}
local function commit_count(line, number)
    local commit, count = line:match("`([%da-f]+)` 当时的 (%d+) 个 Lua 文件")
    return commit ~= nil and #commit >= 7 and #commit <= 40 and count == number
end
assert(commit_count("`6702c31` 当时的 139 个 Lua 文件", "139"))
assert(not commit_count("当前的 139 个 Lua 文件", "139"))
assert(not commit_count("`main` 当时的 139 个 Lua 文件", "139"))
assert(not commit_count("`6702c31` 当时的 139 个 Lua 文件", "165"))
-- Recognize the file-count phrase itself. Counting whitespace-separated words
-- in arbitrary prose treated "Server 2008 各八个共享 Lua 文件" as 2008 tests,
-- and would then treat its 787 repository files as another suite size.
local suite_qualifiers = {
    [""] = true, Lua = true, ["测试"] = true, ["Lua测试"] = true,
    ["单元测试"] = true, ["夹具"] = true, ["夹具测试"] = true,
    ["单元/夹具测试"] = true, ["单元与夹具测试"] = true,
    ["Lua单元/夹具测试"] = true, ["Lua单元与夹具测试"] = true,
}
local function count_claims(line)
    local result, pos = {}, 1
    while true do
        local first, finish, number = line:find("(%d+)", pos)
        if not finish then break end
        pos = finish + 1
        local before, after = line:sub(first - 1, first - 1), line:sub(finish + 1, finish + 1)
        -- Digits inside a version, identifier or date are not a file count.
        if not before:match("[%w_.%-]") and after ~= "." then
            local tail = line:sub(finish + 1)
            local stop = tail:find("文件", 1, true)
            if stop then
                local qualifier = tail:sub(1, stop - 1):gsub("%s+", "")
                    :gsub("^个", ""):gsub("Lua%d+%.%d+", "Lua")
                if suite_qualifiers[qualifier] then result[#result + 1] = number end
            end
        end
    end
    return result
end
local function accepted_count(line, number)
    local row = line:match("^|%s*(.-)%s*|")
    if historical_matrix_rows[row] then return number == historical_matrix_rows[row] end
    return number == tostring(total)
        or (number == "50" and line:find("当时运行时为 50 个文件", 1, true) ~= nil)
        or commit_count(line, number)
end
local function extracted(line, expected)
    assert(table.concat(count_claims(line), ",") == expected, "wrong file-count interpretation: " .. line)
end
extracted("Server 2008 各八个共享 Lua 文件通过，传输 ZIP 的 787 个仓库文件与冻结源码", "")
extracted("Windows Server 2008 下运行 " .. total .. " 个 Lua 测试文件", tostring(total))
extracted("Ubuntu 24.04 | " .. total .. " 个 Lua 文件", tostring(total))
extracted("Lua 5.4 / 5.5 各 " .. total .. " 个测试文件", tostring(total))
extracted("完整 " .. total .. " 个 Lua 5.4 单元/夹具测试文件", tostring(total))
extracted("10 个相关文件和 788 个仓库文件", "")
extracted("`6702c31` 当时的 139 个 Lua 文件", "139")
local wrong = tostring(total + 1)
extracted("Server 2008 下运行 " .. wrong .. " 个 Lua 测试文件", wrong)
assert(not accepted_count("Server 2008 下运行 " .. wrong .. " 个 Lua 测试文件", wrong))
assert(not accepted_count("当前 " .. wrong .. " 个文件，当时运行时为 50 个文件", wrong))
assert(accepted_count("当时运行时为 50 个文件", "50"))
assert(accepted_count("| Linux x86_64，2026-10-11 sshd 配置 | 132 个 Lua 测试文件", "132"))
assert(not accepted_count("| Linux x86_64，2026-10-11 sshd 配置 | 131 个 Lua 测试文件", "131"))
assert(not accepted_count("| Linux x86_64，2026-10-11 sshd 配置 | " .. total .. " 个 Lua 测试文件", tostring(total)))
for line in (matrix .. "\n"):gmatch("[^\n]+") do
    for _, number in ipairs(count_claims(line)) do
        assert(accepted_count(line, number),
            "the validation matrix states a suite size of " .. number ..
                " files and nothing accounts for it: a size that is "
                .. "neither the current count (" .. total .. ") nor a "
                .. "count carrying its historical qualifier is read as "
                .. "the current one. Row: " .. line:sub(1, 160))
    end
end

return true
