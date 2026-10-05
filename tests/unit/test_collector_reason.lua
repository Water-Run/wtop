-- The assertion every collector test delegates to is itself under test.
--
-- Extracting three copies of the same pairing check into one shared helper
-- bought maintainability and bought no safety: measured on the increment that
-- did the extraction, the mutation that replaces the helper's body with
-- `if true then return result.reason end` passes every collector test, because
-- none of them looks at what the helper returns.  Three separate copies would
-- each have been mutated the same way with the same silence, so the honest
-- statement is that the extraction removed a duplication and left the coverage
-- exactly where it was.
--
-- So each direction the helper is supposed to catch is fed to it here with a
-- deliberately wrong input, and the test is the assertion that it complains.
-- A direction with no case above is a direction this file cannot claim to
-- cover, which is the same rule the reason guard applies to its own scans.
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;" .. package.path

local Reason = require("support.collector_reason")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message,
      tostring(expected), tostring(actual)), 2)
  end
end

-- What the helper returns is what the collector tests' fixtures ignore, so the
-- return value is asserted here rather than nowhere.
equal(Reason.assert_reason({ quality = "gap", reason = "probe_gap" },
  { gap = "probe_gap" }, "the matching case"),
  "probe_gap", "a matching reason is returned to the caller")

-- 1. The right code for the wrong quality: the swap every collector mutation
--    performs, and the one no inventory clause can see.
local function must_complain(label, result, expected)
  local ok, message = pcall(Reason.assert_reason, result, expected, label)
  if ok then
    error("the shared assertion accepted " .. label, 2)
  end
  return message
end
local wrong = must_complain("a reason naming the wrong cause",
  { quality = "gap", reason = "probe_partial" },
  { gap = "probe_gap", partial = "probe_partial" })
assert(type(wrong) == "string" and wrong:find("probe_gap", 1, true)
  and wrong:find("gap", 1, true),
  "and the complaint names both the quality and the code it should have carried, "
    .. "so the failure says which pairing broke rather than only that one did")

-- 2. A fresh reading that names a cause.  This is the shape of a reason written
--    as an independent second guess, and it is the one a mutated pairing table
--    makes most easily.
must_complain("a fresh reading that names a cause",
  { quality = "fresh", reason = "probe_gap" }, { gap = "probe_gap", fresh = false })

-- 3. A quality nobody has decided a sentence for.  The helper must refuse
--    rather than skip: a collector that grows a new degraded quality has to be
--    given a code at the moment it grows one, and skipping is how that is lost.
local undecided = must_complain("a quality with no decided reason",
  { quality = "reset", reason = nil }, { gap = "probe_gap", fresh = false })
assert(undecided:find("reset", 1, true),
  "and the complaint names the quality that has no sentence, or the reader "
    .. "cannot tell which one to decide")

-- 4. A missing reason on a degraded quality: the state every one of these
--    collectors shipped in until its own increment.
must_complain("a degraded reading with no reason at all",
  { quality = "partial", reason = nil }, { partial = "probe_partial" })

-- 5. `fresh = false` and `fresh = nil` mean the same thing, so a table written
--    either way is not quietly wrong: both demand no cause.
must_complain("a fresh reading with no cause, declared with a nil",
  { quality = "fresh", reason = "probe_gap" }, { gap = "probe_gap" })

print("ok: the collector reason assertion is itself asserted")
