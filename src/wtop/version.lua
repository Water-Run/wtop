-- The build revision is written by `make build-id` into build/build_id.lua
-- next to this module's search path; source checkouts without it simply have
-- no revision to report.
local ok, build_id = pcall(require, "wtop.build_id")

return {
    name = "wtop",
    version = "0.1.0",
    revision = ok and type(build_id) == "table" and build_id.revision or nil,
    description = "WaterRun's top — a deep Linux observability TUI",
}
