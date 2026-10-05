#!/usr/bin/env .tools/lua-5.5.1/bin/lua
-- Apply docs/agent-v1.schema.json to a document wtop produced.
--
-- Usage: tools/check_agent_schema.lua [--schema PATH] [--document PATH]
--
-- With no --document the document is produced here, by running `--agent`
-- against this host.  That is the point: a schema checked only against a
-- fixture proves the fixture conforms, and the contract this file exists to
-- hold is between the schema and what a real host emits.  Pass --document to
-- check a specific capture instead, which is what the unit test does.
--
-- The exit status is the verdict and the message is the reason.  A schema that
-- has grown a keyword this validator does not implement is a failure too, not a
-- pass: see tools/agent_schema.lua for why that is the rule rather than a
-- limitation.

package.path = "./src/?.lua;./src/?/init.lua;./tools/?.lua;" .. package.path

local Validator = require("agent_schema")

local schema_path = "docs/agent-v1.schema.json"
local document_path = nil
local index = 1
while index <= #arg do
  local item = arg[index]
  if item == "--schema" then
    schema_path = arg[index + 1] or ""
    index = index + 2
  elseif item == "--document" then
    document_path = arg[index + 1] or ""
    index = index + 2
  else
    io.stderr:write("check_agent_schema: unknown argument " .. tostring(item) .. "\n")
    os.exit(2)
  end
end

if not document_path then
  -- Generated where the suite already keeps its scratch files, so a failed run
  -- leaves something a person can read rather than a pipe that has gone.
  document_path = "build/native/.wtop-agent-capture.json"
  os.execute("mkdir -p build/native")
  local lua = os.getenv("WTOP_LUA")
  if not lua or lua == "" then lua = ".tools/lua-5.5.1/bin/lua" end
  local native_dir = os.getenv("WTOP_NATIVE_DIR")
  if not native_dir or native_dir == "" then native_dir = "./build/native" end
  local command = table.concat({
    "LUA_PATH='./src/?.lua;./src/?/init.lua;;'",
    "LUA_CPATH='" .. native_dir .. "/?.so;;'",
    "'" .. lua .. "' src/wtop.lua --agent",
  }, " ")
  local ok = os.execute(command .. " > " .. document_path)
  if ok ~= true and ok ~= 0 then
    io.stderr:write("check_agent_schema: --agent produced no document, so the "
      .. "schema was not applied to anything.\n")
    os.exit(1)
  end
end

local errors, failure = Validator.validate_files(schema_path, document_path)
if not errors then
  io.stderr:write("check_agent_schema: " .. tostring(failure) .. "\n")
  os.exit(1)
end

if #errors == 0 then
  io.write("wtop: --agent output conforms to ")
  io.write(schema_path)
  io.write("\n")
  os.exit(0)
end

io.stderr:write("wtop: --agent output does not conform to " .. schema_path .. ":\n")
for _, message in ipairs(errors) do
  io.stderr:write("  " .. message .. "\n")
end
io.stderr:write("  The schema is a published contract for anything reading --agent.\n")
io.stderr:write("  Fix whichever of the two is wrong; do not loosen the schema to\n")
io.stderr:write("  match a document nobody checked until now.\n")
os.exit(1)
