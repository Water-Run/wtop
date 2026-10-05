-- Missing build artifacts: refusal, or a stated skip for the one run that
-- builds nothing.
--
-- A test that exercises the native module, the packaged interpreter or a
-- release document must fail when its subject is missing: every suite that
-- runs such a test builds the subject first (test-55 has `native locales` as
-- prerequisites, test-all builds bundles), so a missing subject there means
-- the build broke and the gate must say so.
--
-- The pure-Lua 5.4 job is the exception by design: it proves the Lua tree
-- parses and runs on the system interpreter, it builds nothing, and its value
-- for an artifact-driven file is that the file still compiles under 5.4 --
-- tests/run.lua loads the whole chunk before running it.  That job opts in
-- through WTOP_TESTS_WITHOUT_ARTIFACTS=1 (set by the test-54 recipe, nowhere
-- else), and only there does a missing artifact become a printed skip rather
-- than a failure.
--
-- The skip is written mid-line on the runner's own result row (the runner
-- prints the padded path first and its verdict after), so a skipped file is
-- visible in the log instead of being counted away silently.

local Artifacts = {}

local function allowed_to_skip()
    return os.getenv("WTOP_TESTS_WITHOUT_ARTIFACTS") == "1"
end

-- Returns true when the file is present.  When it is not, fails with
-- `how_to_build` -- unless this run declared it builds nothing, in which case
-- it prints what is missing and returns false.
function Artifacts.require_file(path, what, how_to_build)
    local handle = io.open(path, "rb")
    if handle then
        handle:close()
        return true
    end
    if allowed_to_skip() then
        io.write("[skipped: " .. what .. " missing (" .. how_to_build .. ")] ")
        return false
    end
    error(what .. " is missing (" .. path .. "); " .. how_to_build, 0)
end

-- Same contract for conditions that are not one file, such as "the native
-- module actually loaded" -- the wrapper in src/wtop/native.lua answers
-- `available = false` for every function when the .so cannot be required.
function Artifacts.require_condition(condition, what, how_to_build)
    if condition then
        return true
    end
    if allowed_to_skip() then
        io.write("[skipped: " .. what .. " (" .. how_to_build .. ")] ")
        return false
    end
    error(what .. "; " .. how_to_build, 0)
end

return Artifacts
