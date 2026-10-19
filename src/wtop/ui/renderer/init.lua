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

local function present(self, grid, force, take_ownership)
  if type(grid) ~= "table" or type(grid.get) ~= "function"
      or type(grid.clone) ~= "function" or type(grid.mark_clean) ~= "function" then
    return nil, "renderer requires a valid grid"
  end
  if force ~= nil and type(force) ~= "boolean" then
    return nil, "renderer force must be a boolean"
  end
  if take_ownership and grid == self.previous then
    return nil, "renderer already owns this grid"
  end
  local runs, metadata = Diff.runs(self.previous, grid, {force = force})
  if #runs > 0 then
    local presented, reason = self.backend.present(runs, metadata)
    if presented == false or (presented == nil and reason ~= nil) then
      -- Keep the last known-good frame. Advancing `previous` after a partial
      -- or failed terminal write makes the missing cells permanent because a
      -- later diff incorrectly assumes that they are already on screen.
      if take_ownership then
        return nil, reason or "renderer backend failed to present frame", grid
      end
      return nil, reason or "renderer backend failed to present frame"
    end
    self.frames = self.frames + 1
    self.written_cells = self.written_cells + metadata.changed_cells
  else
    self.skipped = self.skipped + 1
  end
  local released
  if take_ownership then
    released, self.previous = self.previous, grid
  else
    self.previous = grid:clone()
  end
  grid:mark_clean()
  if take_ownership then return runs, metadata, released end
  return runs, metadata
end

function Renderer:present(grid, force)
  return present(self, grid, force, false)
end

-- The caller transfers this grid and can reuse only the released prior frame.
-- Failed writes keep the displayed frame and return the input to its caller.
function Renderer:present_owned(grid, force)
  return present(self, grid, force, true)
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
