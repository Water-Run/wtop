local M = {}

local style_attributes = {
  "bold", "dim", "italic", "underline", "blink", "reverse", "strikethrough",
  "fg_token", "bg_token",
}

local function colour_equal(first, second)
  if first == second then
    return true
  end
  if type(first) ~= "table" or type(second) ~= "table" then
    return false
  end
  return first.mode == second.mode and first.index == second.index
    and first.r == second.r and first.g == second.g and first.b == second.b
end

local function style_equal(first, second)
  if first == second then
    return true
  end
  if type(first) ~= "table" or type(second) ~= "table" then
    return false
  end
  if not colour_equal(first.fg, second.fg) or not colour_equal(first.bg, second.bg) then
    return false
  end
  for _, attribute in ipairs(style_attributes) do
    if first[attribute] ~= second[attribute] then
      return false
    end
  end
  return true
end

local function cell_equal(first, second, equal_style)
  if first == second then
    return true
  end
  if not first or not second then
    return false
  end
  return first.char == second.char and first.width == second.width
    and first.continuation == second.continuation and first.lead_x == second.lead_x
    and equal_style(first.style, second.style)
end

-- Produce backend-neutral cursor runs.  A run's text can contain wide glyphs;
-- `cells` records its terminal width and must be used instead of byte length.
function M.runs(previous, current, options)
  options = options or {}
  assert(current and current.width and current.height, "current grid is required")
  local full = options.force or not previous
    or previous.width ~= current.width or previous.height ~= current.height
  local runs, changed = {}, 0
  -- Styles repeat across many cells. Keep just the last pair for this frame;
  -- a later frame must observe mutations and needs a fresh comparison.
  local last_first, last_second, last_equal
  local function equal_style(first, second)
    if first == second then return true end
    if first == last_first and second == last_second then return last_equal end
    last_equal = style_equal(first, second)
    last_first, last_second = first, second
    return last_equal
  end

  for y = 1, current.height do
    local x = 1
    while x <= current.width do
      local cell = current:get(x, y)
      local old = not full and previous:get(x, y) or nil
      local is_changed = full or not cell_equal(old, cell, equal_style)
      if is_changed and not cell.continuation then
        local run = {x = x, y = y, text = "", cells = 0, style = cell.style}
        while x <= current.width do
          cell = current:get(x, y)
          old = not full and previous:get(x, y) or nil
          is_changed = full or not cell_equal(old, cell, equal_style)
          if not is_changed then
            break
          end
          if cell.continuation then
            -- The leading grapheme already advances across this cell.
            x = x + 1
          elseif not equal_style(run.style, cell.style) then
            break
          else
            run.text = run.text .. cell.char
            local span = cell.width or 1
            run.cells = run.cells + span
            changed = changed + span
            x = x + span
          end
        end
        if run.cells > 0 then
          runs[#runs + 1] = run
        end
      else
        x = x + 1
      end
    end
  end
  return runs, {full = full, changed_cells = changed}
end

M.style_equal = style_equal
M.cell_equal = function(first, second) return cell_equal(first, second, style_equal) end

return M
