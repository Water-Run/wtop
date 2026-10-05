package.path = "./src/?.lua;./src/?/init.lua;./tools/?.lua;./tests/?.lua;" .. package.path

-- A published contract that nothing applies.
--
-- docs/agent-v1.schema.json is what a script or an LLM reads to know the shape
-- of `--agent`.  Until this file existed, the only automated check on it was
-- `json.load(...)` in `make check`, which proves the schema is JSON -- a
-- statement about the schema, not about anything wtop emits.  So the contract
-- was kept by hand, and the shape that has to be kept in step is duplicated:
-- the three collection limits in `export.lua` and the three `maxItems` here are
-- the same numbers written down twice, with a comment beside the first three
-- claiming they "are part of agent-v1.schema.json".  Only a check can hold that
-- claim.
--
-- This file is the check, and it is deliberately the larger half.  A validator
-- that is only ever shown a conforming document is a validator nobody has run,
-- which is the defect this project removed from `--version` when it first
-- compared two values that happened to agree.  So most of what follows is the
-- validator being shown documents it must reject, one per keyword the schema
-- uses: const, enum, type, required, maxItems, minLength, maxLength, minimum,
-- $ref and additionalProperties.  If a rule stops rejecting, this file fails
-- and the rule is reported as satisfied when it is not.
--
-- The clause that is easy to leave out and hardest to lose is the last one: a
-- schema using a keyword the validator does not implement is a FAILURE, not a
-- pass.  A validator that quietly ignores what it does not understand is the
-- same defect one level up -- a tool reporting that a document is valid when it
-- validated part of it -- and it would arrive the first time somebody added
-- `oneOf` or an external `$ref` to a contract nobody re-reads.

local Validator = require("agent_schema")
local JSON = require("wtop.core.json")
local Makefile = require("support.makefile")

local function read_file(path)
  local handle = assert(io.open(path, "rb"), "cannot read " .. path)
  local body = handle:read("*a")
  handle:close()
  return body
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local schema = assert(JSON.decode(read_file("docs/agent-v1.schema.json")),
  "docs/agent-v1.schema.json no longer decodes")
assert(type(schema) == "table", "the agent schema is not an object")

-- A document that conforms, so that every rejection below is a rejection of
-- something rather than a rejection of a broken starting point.  It is built
-- from the schema's own required list, which is the minimum a conforming
-- document can be -- if this stops conforming, the schema and this file have
-- drifted apart and that is the finding.
local function minimal_document()
  local document = { schema = "dev.waterrun.wtop.agent/v1" }
  for _, name in ipairs(schema.required) do
    if document[name] == nil then document[name] = {} end
  end
  document.sequence = 0
  document.captured_unix_ns = 1
  document.captured_monotonic_ns = 1
  document.producer = { name = "wtop", version = "0.1.0" }
  document.privilege = { mode = "user", uid = 1000, root = false }
  document.overall = { state = "ok", signal_count = 0 }
  document.metrics = {}
  for _, name in ipairs({ "cpu", "memory", "pressure", "storage", "network",
                          "gpu", "power", "sensors", "processes" }) do
    document.metrics[name] = {}
  end
  document.signals = {}
  document.top = { processes = {}, disks = {}, interfaces = {},
                   workloads = {}, gpus = {}, sensors = {} }
  document.data_quality = {}
  document.unavailable_sources = {}
  document.privacy = { remote_addresses = "omitted", process_commands = "omitted" }
  return document
end

local baseline = assert(Validator.validate(minimal_document(), schema))
assert(#baseline == 0,
    "a document built to the schema's own required list does not conform, so "
        .. "every rejection below would be measuring the wrong thing:\n"
        .. table.concat(baseline, "\n"))

-- ---------------------------------------------------------------------------
-- Every keyword the schema uses, shown a document it must reject.

local function rejected(what, mutate, expect_in_message)
  local document = minimal_document()
  mutate(document)
  local errors = Validator.validate(document, schema)
  assert(#errors > 0,
    "the validator accepted a document that breaks " .. what ..
        ".  A validator that only ever says yes is not a validator: it is the "
        .. "defect this file exists to remove, wearing the shape of a check.")
  if expect_in_message then
    local joined = table.concat(errors, "\n")
    assert(joined:find(expect_in_message, 1, true) ~= nil,
      "the document that breaks " .. what .. " was rejected, but not for that: "
        .. "the message does not mention " .. expect_in_message .. "\n" .. joined)
  end
  return errors
end

rejected("the schema constant", function(d) d.schema = "dev.waterrun.wtop.agent/v2" end,
  "expected the constant")
rejected("a required property", function(d) d.privacy = nil end,
  "required property")
rejected("an enum", function(d) d.overall.state = "catastrophe" end,
  "not one of the allowed values")
rejected("a type", function(d) d.sequence = "zero" end,
  "expected integer")
rejected("maxItems", function(d)
  for index = 1, 11 do
    d.top.processes[index] = { pid = index }
  end
end, "exceeds maxItems")
rejected("minLength", function(d)
  d.signals = { { resource = "", code = "c", severity = "warning", message = "m" } }
end, "shorter than minLength")
rejected("maxLength", function(d)
  d.signals = { { resource = string.rep("x", 257), code = "c",
                  severity = "warning", message = "m" } }
end, "longer than maxLength")
rejected("minimum", function(d) d.captured_unix_ns = -1 end, "below the minimum")
rejected("items", function(d) d.signals = "a string where a list belongs" end,
  "expected array")
rejected("a $ref, through the bounded string it points at", function(d)
  d.unavailable_sources = { { id = 42 } }
end, "expected string")
rejected("the privacy constants, which are the last thing standing between a "
        .. "schema and a document that names a remote address",
  function(d) d.privacy.remote_addresses = "203.0.113.7" end,
  "expected the constant")

-- additionalProperties is false nowhere in this schema, so the keyword cannot
-- be exercised by mutating a document.  It is exercised by mutating the
-- schema, which is the direction a future edit would go wrong in.
local closed = copy(schema)
closed.additionalProperties = false
closed.properties.host = { type = "object", additionalProperties = false,
                           properties = { name = { type = "string" } } }
local stray = minimal_document()
stray.host = { name = "box", nickname = "the box" }
local closed_errors = Validator.validate(stray, closed)
assert(#closed_errors > 0,
  "a document with a property the schema forbids was accepted; "
      .. "additionalProperties: false is the clause that keeps an emitted "
      .. "field from becoming a promised one, and it does not work")

-- A type name the validator does not know is a rule it cannot honour, and the
-- refusal has to name it.  Asserting only that the document was rejected is
-- what let this clause pass while it was unreachable: a made-up type is also an
-- unsatisfiable one, so the document was refused as a plain type mismatch --
-- the right verdict, the wrong reason, and no evidence the keyword check ran.
local exotic = copy(schema)
exotic.properties.privilege.properties.mode = { type = "bigint" }
local exotic_errors = Validator.validate(minimal_document(), exotic)
assert(#exotic_errors > 0,
  "a schema asking for a type this validator does not implement was accepted; "
      .. "validating a rule you cannot test is not validating it")
assert(table.concat(exotic_errors, "\n"):find("type:bigint", 1, true) ~= nil,
  "the schema asked for a type this validator cannot test, and the refusal did "
      .. "not say so.  A plain type mismatch would satisfy the line above while "
      .. "proving nothing about the keyword check:\n"
      .. table.concat(exotic_errors, "\n"))

-- ---------------------------------------------------------------------------
-- The refusals themselves.  A schema that has outgrown the validator stops the
-- check with a message naming what, because the alternative -- validating the
-- parts that happen to be understood -- is a pass that means less every time
-- the schema grows.

local function refused(what, mutate_schema, expect)
  local mutated = copy(schema)
  mutate_schema(mutated)
  local errors = Validator.validate(minimal_document(), mutated)
  assert(#errors > 0,
    "a schema using " .. what .. " was accepted, so the validator reported a "
        .. "document conforming to rules it never applied")
  assert(table.concat(errors, "\n"):find(expect, 1, true) ~= nil,
    "the refusal for " .. what .. " does not name it:\n"
        .. table.concat(errors, "\n"))
end

refused("pattern", function(s) s.properties.host.pattern = "^x" end, "pattern")
refused("patternProperties", function(s)
  s.properties.host.patternProperties = { ["^x"] = { type = "string" } }
end, "patternProperties")
refused("oneOf", function(s) s.properties.schema.oneOf = {} end, "oneOf")
refused("$ref to another document", function(s)
  s.properties.schema["$ref"] = "https://example.com/elsewhere.json"
end, "outside this document")
refused("$ref that does not resolve", function(s)
  s.properties.schema["$ref"] = "#/$defs/thereIsNoSuchDefinition"
end, "does not resolve")

-- ---------------------------------------------------------------------------
-- The check is wired to something.  A validator nothing runs is a module.

local makefile = read_file("Makefile")
assert(makefile:find("check_agent_schema.lua", 1, true) ~= nil,
  "no Makefile target runs tools/check_agent_schema.lua, so the schema is still "
      .. "only parsed and never applied to a document")
local check_body = Makefile.recipe_of(makefile, "check")
assert(check_body ~= nil and check_body:find("check_agent_schema", 1, true) ~= nil,
  "the `check` target does not run the schema check:\n" .. tostring(check_body))
-- Both the old parse and the new application are wanted.  The parse is a
-- statement about the file; dropping it would not be a simplification, it would
-- be removing the check that catches a schema that is not JSON at all.
assert(makefile:find('json.load(open("docs/agent-v1.schema.json"', 1, true) ~= nil,
  "the JSON parse of the schema is gone, so a schema that is not JSON would now "
      .. "fail somewhere less legible")

-- ---------------------------------------------------------------------------
-- The documented invocation cost, against the code that pays it.
--
--     `docs/AGENT.md` told a caller that "each invocation ... normally takes
--     about 250 ms".  Measured on the development host, `wtop --agent` takes
--     1.22-1.25 s at the default interval -- about five times that -- and
--     `wtop --snapshot`, which takes no delay at all, takes 1.26 s, so the
--     difference is not the agent's second sample: 250 ms was the cap on the
--     deliberate delay between the two samples, read as the whole cost.  The
--     number was written inline in the source as `min(options.interval_ms or
--     1000, 250)`, so there was nowhere for a document and a test to agree with
--     it and nothing that would have noticed it moving.
--
--     What is pinned here is the deterministic half: the delay is the lesser of
--     the interval and the cap, and the document states that cap.  The total is
--     not pinned, because a performance total is a property of a host and this
--     project has no calibrated budget -- `docs/PLAN.md` still carries "Measured
--     performance budgets and regression gates" as an open item, and a test that
--     asserted a wall-clock figure would be a flake wearing a guard's clothes.
--     What the document must not do is state the cap as a total, which is the
--     sentence that was wrong.
local Application = require("wtop.application")
assert(type(Application.AGENT_SAMPLE_DELAY_CAP_MS) == "number"
        and Application.AGENT_SAMPLE_DELAY_CAP_MS > 0,
  "the agent's sample-delay cap is not a named number, so `docs/AGENT.md` and "
      .. "this clause have to repeat a literal and neither notices it changing")
local cap = Application.AGENT_SAMPLE_DELAY_CAP_MS
local agent_doc = read_file("docs/AGENT.md")
local stated = agent_doc:match("min%(%-%-interval, (%d+) ms%)")
assert(stated == tostring(cap),
  "docs/AGENT.md states the agent's between-sample delay as " .. tostring(stated)
    .. " ms and the code caps it at " .. tostring(cap) .. " ms.  The document is "
    .. "read by callers budgeting their polling, and the cap is a number both "
    .. "sides have to agree on.")
assert(agent_doc:find("该延迟的上限,而不是整个调用的耗时", 1, true) ~= nil,
  "docs/AGENT.md no longer says the 250 ms is a cap on the between-sample delay "
    .. "rather than the cost of the invocation.  It said \"normally takes about "
    .. "250 ms\" for the whole thing, which is the cap read as a total and was "
    .. "wrong by about five times; the clarification is the fix, and without it "
    .. "the corrected number is just a new unqualified claim.")
-- A wall-clock figure quoted from a shared machine, with no sample count, is not
-- a measurement anybody can check.  The first correction to this document said
-- "1.22-1.25 s": 30 ms wide, measured on one load level, and two of the sixteen
-- invocations taken afterwards fell outside it (1.16 and 1.38).  A reader who
-- reproduced the number and got something else would have concluded the code
-- changed.  So the sample count is required wherever a duration is quoted, and
-- what is *not* required is the duration itself -- pinning seconds in a test on
-- a loaded host is a flake wearing a guard's clothes, which is why the figure is
-- documented and its provenance checked rather than its value.
assert(agent_doc:find("n=16", 1, true) ~= nil,
  "docs/AGENT.md quotes a wall-clock cost for `wtop --agent` without saying how "
    .. "many invocations it came from.  A band measured on a shared, load-varying "
    .. "host and presented as a range is a claim about a machine, not about the "
    .. "code, and it will not reproduce: this one was written 1.22-1.25 s and two "
    .. "of the next sixteen samples fell outside it.")
-- And the band has to keep saying whose property it is.  "1.16-1.38 s" with a
-- sample count still reads as a figure about wtop unless the sentence says the
-- host is shared and its load moves, which is the whole reason the band is wide
-- rather than the code being unclear about anything.
assert(agent_doc:find("共享的、负载波动宿主机的特性", 1, true) ~= nil,
  "docs/AGENT.md no longer says the wall-clock figures are properties of a "
    .. "shared, load-varying host.  With a sample count and no attribution, a "
    .. "band still reads as a measurement of wtop rather than of the machine it "
    .. "was taken on, and that is the same mistake as the original sentence: a "
    .. "number about the environment presented as a number about the code.")
-- And the two-sample structure is what buys the rates, so it is worth holding:
-- the invocation probes, samples, waits, samples again.  Measured, a rate in the
-- agent output is a real delta rather than a cached value.
assert(agent_doc:find("采样两次", 1, true) ~= nil,
  "the agent document no longer claims two samples, so the rates it publishes "
    .. "have no stated provenance")

return true
