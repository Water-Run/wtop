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
    return tonumber(body:match("^(%d+)"))
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
    { "docs/CROSS_PLATFORM.md", total .. " 个 Lua 测试文件、Lua 5.4 子集" },
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
    -- The cross-libc section carried 90 for four increments after the suite
    -- passed 94, and the reason is the one this file exists to prevent: it is
    -- the same sentence as a current claim, in the same present tense, and it
    -- was not in the enumeration.  The container runs this same tree, so the
    -- number it reports is this number, and the phrase that qualifies it as the
    -- container's is what makes it a current claim rather than a historical one.
    { "docs/PACKAGING.md", "glibc 2.17 上 **通过 " .. total .. " 个测试文件**" },
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
    { "docs/CROSS_PLATFORM.md", "当时运行时为 50 个文件" },
    { "docs/MONITORING.md", "在此功能之前断言表格形状的 73 个单元测试" },
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
for line in (matrix .. "\n"):gmatch("[^\n]+") do
    -- Walked by position rather than with gmatch: a `(%d+)(.*)` pattern makes
    -- the second capture swallow the rest of the line, so gmatch would yield
    -- one number per row and examine whichever came first.  The Debian row
    -- carries "13" in its host column and a suite size in its acceptance one,
    -- and the first mutation proved that is exactly the one that gets missed.
    local pos = 1
    while true do
        local _, finish, number = line:find("(%d+)", pos)
        if not finish then break end
        pos = finish + 1
        -- A suite size is a number with "file" or "files" not far behind it, and
        -- "not far" is what the qualifier words are for: "89-file", "50 files",
        -- "100 Lua test files", "100 Lua unit/fixture test files".  Two words is
        -- the widest gap allowed, which is what separates those from the
        -- versions on the same rows -- "Fedora 44", "glibc 2.17", "macOS 26.5",
        -- "6.0.6003" -- none of which has a file anywhere near its number.
        local tail = line:sub(finish + 1)
        local stop = tail:find("文件")
        if stop then
            local between = tail:sub(1, stop - 1)
            local words = 0
            for _ in between:gmatch("%S+") do words = words + 1 end
            if words <= 2 then
                local guarded = number == tostring(total)
                    or line:find("当时运行时为 50 个文件", 1, true) ~= nil
                assert(guarded,
                    "the validation matrix states a suite size of " .. number ..
                        " files and nothing accounts for it: a size that is "
                        .. "neither the current count (" .. total .. ") nor a "
                        .. "count carrying its historical qualifier is read as "
                        .. "the current one, and the phrase list above only "
                        .. "guards the sentences this file was told about.  Row: "
                        .. line:sub(1, 120))
            end
        end
    end
end

return true
