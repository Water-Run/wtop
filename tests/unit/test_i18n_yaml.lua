local source = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
local root = source:match("^(.*)/tests/unit/[^/]+$") or "."
if root == "" then
  root = "."
end
package.path = root .. "/src/?.lua;" .. root .. "/src/?/init.lua;" .. package.path

local Yaml = require("wtop.i18n.yaml_profile")

local function equal(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %q, got %q", label or "value", tostring(expected), tostring(actual)), 2)
  end
end

local function contains(value, fragment, label)
  if type(value) ~= "string" or not value:find(fragment, 1, true) then
    error(string.format("%s: expected %q to contain %q", label or "value", tostring(value), fragment), 2)
  end
end

local document = table.concat({
  "---",
  "name: \"catalog # one\" # real comment",
  "single: 'it''s # data' # comment",
  "enabled: true",
  "disabled: false",
  "nothing: null",
  "count: -42",
  "empty: []",
  "items:",
  "  - id: \"first\"",
  "    label: \"A\\u4E2D\"",
  "  - id: \"second\"",
  "    label: plain value",
  "...",
  "",
}, "\r\n")

local parsed, info = Yaml.parse(document, { source = "valid.yml" })
assert(parsed, info)
equal(parsed.name, "catalog # one", "double quote/comment")
equal(parsed.single, "it's # data", "single quote")
equal(parsed.enabled, true, "boolean true")
equal(parsed.disabled, false, "boolean false")
equal(parsed.nothing, Yaml.null, "explicit null")
equal(parsed.count, -42, "integer")
equal(#parsed.empty, 0, "empty sequence")
equal(info.kinds["/empty"], "sequence", "empty sequence kind")
equal(#parsed.items, 2, "sequence length")
equal(parsed.items[1].id, "first", "inline sequence mapping")
equal(parsed.items[1].label, "A中", "Unicode escape")
equal(parsed.items[2].label, "plain value", "plain scalar")

local duplicate, duplicate_err = Yaml.parse("root:\n  key: one\n  key: two\n", { source = "duplicate.yml" })
equal(duplicate, nil, "duplicate rejected")
contains(duplicate_err, "duplicate.yml:3:3", "duplicate location")
contains(duplicate_err, "duplicate key", "duplicate reason")

local forbidden_documents = {
  { "alias.yml", "value: *shared\n", "anchors, aliases and tags are forbidden" },
  { "anchor.yml", "value: &shared item\n", "anchors, aliases and tags are forbidden" },
  { "tag.yml", "value: !!str item\n", "anchors, aliases and tags are forbidden" },
  { "merge.yml", "<<: value\n", "mapping key" },
  { "flow.yml", "value: [one, two]\n", "flow collections are not supported" },
  { "block.yml", "value: |\n", "block scalars are not supported" },
  { "multi.yml", "a: one\n---\nb: two\n", "multiple YAML documents are forbidden" },
  { "tab.yml", "root:\n\tkey: value\n", "tabs are forbidden in indentation" },
}
for _, example in ipairs(forbidden_documents) do
  local value, err = Yaml.parse(example[2], { source = example[1] })
  equal(value, nil, example[1] .. " rejected")
  contains(err, example[3], example[1] .. " reason")
end

local invalid_utf8, utf8_err = Yaml.parse("line: ok\nbad: \255\n", { source = "utf8.yml" })
equal(invalid_utf8, nil, "invalid UTF-8 rejected")
contains(utf8_err, "utf8.yml:2:6", "invalid UTF-8 location")

local too_large, size_err = Yaml.parse("value: abc\n", { source = "large.yml", max_bytes = 4 })
equal(too_large, nil, "size limit")
contains(size_err, "size limit", "size limit reason")

local leading_zero, integer_err = Yaml.parse("value: 012\n", { source = "integer.yml" })
equal(leading_zero, nil, "leading zero rejected")
contains(integer_err, "leading zeroes", "integer reason")

local token_limited, token_error = Yaml.parse("first: one\nsecond: two\n", {
  source = "tokens.yml", max_tokens = 1,
})
equal(token_limited, nil, "token limit")
contains(token_error, "token limit", "token limit reason")
assert(Yaml.parse_file("/dev/null") == nil, "YAML file reader must reject special files")
assert(Yaml.parse("value: ok\n", {max_nodes = "many"}) == nil,
  "invalid YAML limits must be rejected without a type error")

return true
