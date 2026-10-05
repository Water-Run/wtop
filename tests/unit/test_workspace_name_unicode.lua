-- A workspace name a user can actually type.
--
-- The rule used to be a C-locale character class, so `工作区` was refused. That
-- was an open question in the plan for several increments, and the answer is not
-- to ask what a "letter" is -- that needs Unicode tables this project has no
-- reason to depend on for a user-chosen label -- but to state the rule as what
-- has to stay out: control characters, the structural ASCII a name could be
-- confused with, and any byte that is not part of a well-formed UTF-8 sequence.
--
-- The reason the two halves of this file matter equally is that the rule has
-- two callers, and a name accepted by one and rejected by the other loses the
-- user's whole layout: a layout file fails on an unusable key rather than
-- dropping the entry. So the first half proves the rule as a predicate, and the
-- second half proves the two call sites are one rule by exercising the round
-- trip that a disagreement would break.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Layout = require("wtop.model.layout")
local LayoutStore = require("wtop.layout_store")
local Workspace = require("wtop.workspace")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label or "values differ",
      tostring(expected), tostring(actual)), 2)
  end
end

-- 1. The rule itself.  ASCII is unchanged, non-ASCII is admitted, and the
-- rejections are the ones with a reason behind them.
local accepted = {
  { "triage", "the historical set still works" },
  { "my qx", "a space inside a name is an ordinary thing to type" },
  { "a.b-c_d", "and the structural characters the rule has always allowed" },
  { "9lives", "a name may start with a digit" },
  { "_x", "or an underscore" },
  { "工作区", "a zh-CN user names a workspace the way they talk about it" },
  { "日本語", "as does a ja-JP user" },
  { "Ünïcödé", "and so does anyone with a Latin diacritic" },
  { "🛠 build", "a name outside the basic plane, with a space" },
  { "工 作区", "CJK with an interior space" },
  { string.rep("x", 64), "64 bytes is the bound" },
  { string.rep("工", 21), "21 CJK characters is 63 bytes, which is inside it" },
}
for _, case in ipairs(accepted) do
  equal(Layout.workspace_name_ok(case[1]), true, "accepted: " .. case[2])
end

local rejected = {
  { "", "an empty name" },
  { " leading", "a leading space, which the editor can never produce" },
  { "trailing ", "and a trailing one" },
  { ".hidden", "a leading dot reads as a marker" },
  { "-dash", "and a leading dash" },
  { "a\tb", "a tab" },
  { "a\nb", "a newline, which is a line of its own in a file" },
  { "a\27[31mb", "an escape sequence, which a terminal would act on" },
  { "\x7f", "the delete control character" },
  { "a:b", "a colon, which reads as a key/value separator" },
  { "a/b", "a path separator" },
  { { "a\"b" }, "a double quote" },
  { "a\\b", "a backslash" },
  { "a#b", "a comment character" },
  { "a*b", "and the others YAML gives a meaning to" },
  { "a?b", "" },
  { "a|b", "" },
  { "a{b", "" },
  { string.rep("x", 65), "65 bytes is past the bound" },
  { string.rep("工", 22), "and 22 CJK characters is 66 bytes" },
  { "\x9b", "a bare CSI, which a terminal honours as an escape" },
  { "\xed\xa0\x80", "a UTF-16 surrogate, which is not a character" },
  { "\xc0\xaf", "an overlong encoding of a slash" },
  { "\xf5\x80\x80\x80", "a code point past U+10FFFF" },
  { "\xff", "a byte that is never valid in UTF-8" },
  { "\xe5\xb7", "a truncated three-byte sequence" },
}
for _, case in ipairs(rejected) do
  local value = case[1]
  if type(value) == "table" then value = value[1] end
  equal(Layout.workspace_name_ok(value), false, "rejected: " .. case[2])
end
equal(Layout.workspace_name_ok(nil), false, "rejected: a name that is not text")
equal(Layout.workspace_name_ok(42), false, "rejected: a name that is a number")

-- The 8-bit control case deserves its own note, because it is the one the
-- relaxation could have got wrong.  "Accept every byte above ASCII" would admit
-- 0x9b, and a name carrying one is drawn on a terminal that treats it as CSI.
-- Accepting whole *sequences* is what excludes it, because 0x9b can then only
-- ever be the interior of a multi-byte character.
equal(Layout.workspace_name_ok("工"), true,
  "a three-byte sequence is a name")
equal(Layout.workspace_name_ok("\xe5\x9b\x80"), true,
  "a sequence carrying 0x9b as its interior byte is a name")
equal(Layout.workspace_name_ok("\x9b"), false,
  "but the same byte on its own is a terminal control character")
equal(Layout.workspace_name_ok("\xe5\x9b"), false,
  "and a sequence cut short before its third byte is not a character")

-- 2. The two callers are one rule.  Saving accepts, and the file that comes out
-- reads back with the same names in it.
local defaults = {
  overview = { "cpu", "memory", "disk" },
  processes = { "table" },
}
local function trees()
  return {
    overview = assert(Layout.split("horizontal", 0.6, {
      assert(Layout.split("vertical", 0.4, {
        assert(Layout.leaf("cpu")), assert(Layout.leaf("memory")),
      }, { gap = 1 })),
      assert(Layout.leaf("disk")),
    }, { gap = 1 })),
    processes = assert(Layout.leaf("table")),
  }
end
local names = { "工作区", "日本語", "my qx", "🛠 build", "triage" }
local workspaces = {}
for _, name in ipairs(names) do workspaces[name] = trees() end
local encoded = assert(LayoutStore.encode(defaults, trees(), workspaces, "工作区"),
  "a layout with non-ASCII workspace names encodes")
-- The names are keys, so the file has to quote them; a bare CJK key would parse
-- back as something else, or not at all, and the whole file would be lost.
assert(encoded:find('"工作区"', 1, true),
  "the CJK name is written as a quoted key:\n" .. encoded)
-- Parsed into locals before being asserted on.  A call in a non-final argument
-- position is truncated to a single value, so `assert(parse(...), message)`
-- would hand `assert` only the first return and then bind the *message* to the
-- third local -- which fails in a way that reads as "the workspaces are missing"
-- rather than as a mistake in the test.
local read_orders, read_trees, read_workspaces, read_active =
  LayoutStore.parse(encoded, defaults)
assert(read_orders and read_trees, "a layout with non-ASCII workspace names reads back")
assert(type(read_workspaces) == "table", "the workspaces come back")
equal(read_active, "工作区", "the active workspace is the CJK one that was saved")
equal(read_workspaces["工作区"] ~= nil, true, "the CJK workspace is there under its own name")
equal(read_workspaces["🛠 build"] ~= nil, true, "and so is the one outside the basic plane")
for _, name in ipairs(names) do
  equal(read_workspaces[name] ~= nil, true,
    "every name survives the round trip: " .. name)
  equal(read_workspaces[name].overview.axis, "horizontal",
    "with its own layout intact: " .. name)
end

-- 3. A hand-edited file cannot smuggle in a name the editor could not produce,
-- and the failure names the key rather than dropping the entry silently.  The
-- rejected name is one the YAML reader can express -- a colon inside a quoted
-- key -- so what is being tested is the name rule and not the file syntax.
local hostile = encoded:gsub('"my qx":', '"a:b":', 1)
assert(hostile ~= encoded, "the hostile layout really was rewritten")
local refused, reason = LayoutStore.parse(hostile, defaults)
assert(refused == nil, "a workspace key with a structural character is refused")
assert(type(reason) == "string" and reason:find("workspace name", 1, true) ~= nil,
  "the reason is about the workspace name, not the file: " .. tostring(reason))
assert(reason:find("a:b", 1, true) ~= nil,
  "and it names the offending key, so the user knows which one to fix: "
    .. tostring(reason))
-- The whole file is refused rather than the one entry, which is why a rule that
-- disagrees between save and load costs an arrangement rather than a workspace.
assert(reason:find("workspace", 1, true) ~= nil,
  "the refusal is a whole-file verdict, as a layout load always is")

-- 4. The live session path agrees with the file path, which is the property the
-- single implementation exists to provide.  Trimming happens here and not in the
-- store, so a name the user typed with stray spaces still lands on the same key
-- the file will accept.
local workspace = Workspace.new({
  layout_trees = assert(Layout.leaf("cpu")),
  widget_orders = defaults,
})
for _, name in ipairs({ "工作区", "my qx", "🛠 build" }) do
  local ok, err = workspace:save_workspace(name)
  equal(ok, true, "the session accepts " .. name .. ": " .. tostring(err))
end
local padded = assert(workspace:save_workspace("  padded  "))
equal(padded, true, "a padded name is accepted and trimmed")
assert(workspace.workspaces["padded"] ~= nil,
  "and stored under the trimmed key, which is the one the file will accept")
equal(workspace:save_workspace("bad:name"), false,
  "a structural character is still refused at save time")
local _, colon_error = workspace:save_workspace("bad:name")
equal(colon_error, "invalid_workspace_name", "with the reason the interface localizes")

print("ok: workspace names accept a well-formed UTF-8 sequence (rule, round trip, callers)")
