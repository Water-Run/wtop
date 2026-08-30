local Diff = require("wtop.ui.renderer.diff")

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(backend, options)
  assert(type(backend) == "table" and type(backend.present) == "function",
    "renderer backend must implement present(runs)")
  assert(options == nil or type(options) == "table", "renderer options must be a table")
  return setmetatable({
    backend = backend,
    previous = nil,
    options = options or {},
    frames = 0,
    skipped = 0,
    written_cells = 0,
  }, Renderer)
end

function Renderer:invalidate()
  self.previous = nil
end

function Renderer:present(grid, force)
  if type(grid) ~= "table" or type(grid.get) ~= "function"
      or type(grid.clone) ~= "function" or type(grid.mark_clean) ~= "function" then
    return nil, "renderer requires a valid grid"
  end
  if force ~= nil and type(force) ~= "boolean" then
    return nil, "renderer force must be a boolean"
  end
  local runs, metadata = Diff.runs(self.previous, grid, {force = force})
  if #runs > 0 then
    local presented, reason = self.backend.present(runs, metadata)
    if presented == false or (presented == nil and reason ~= nil) then
      -- Keep the last known-good frame. Advancing `previous` after a partial
      -- or failed terminal write makes the missing cells permanent because a
      -- later diff incorrectly assumes that they are already on screen.
      return nil, reason or "renderer backend failed to present frame"
    end
    self.frames = self.frames + 1
    self.written_cells = self.written_cells + metadata.changed_cells
  else
    self.skipped = self.skipped + 1
  end
  self.previous = grid:clone()
  grid:mark_clean()
  return runs, metadata
end

function Renderer:stats()
  return {
    frames = self.frames,
    skipped = self.skipped,
    written_cells = self.written_cells,
  }
end

Renderer.Grid = require("wtop.ui.renderer.grid")
Renderer.Diff = Diff
Renderer.Width = require("wtop.ui.renderer.width")
Renderer.Ansi = require("wtop.ui.renderer.ansi")

return Renderer
