local Controller = {}
Controller.__index = Controller

local SORT_ORDER = {
  "cpu", "memory", "pid", "name", "time", "threads", "virtual",
  "state", "user", "io_read", "io_write",
}
local SORT_KEYS = {}
for index, key in ipairs(SORT_ORDER) do
  SORT_KEYS[key] = index
end

local DEFAULT_DESCENDING = {
  cpu = true,
  memory = true,
  pid = false,
  name = false,
  time = true,
  threads = true,
  virtual = true,
  state = false,
  user = false,
  io_read = true,
  io_write = true,
}

local DEFAULT_MAX_ROWS = 2048
local HARD_MAX_ROWS = 65536
local MAX_ID_BYTES = 128

local function bounded_integer(value, fallback, minimum, maximum)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then
    return fallback
  end
  value = math.floor(value)
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

local function normalize_query(value, maximum_bytes)
  if type(value) ~= "string" then
    value = ""
  end
  local truncated = #value > maximum_bytes
  if truncated then
    value = value:sub(1, maximum_bytes)
  end
  value = value:gsub("[%z\1-\31\127]", " ")
  local _, invalid_at = utf8.len(value)
  if invalid_at then
    value = value:sub(1, invalid_at - 1)
    truncated = true
  end
  value = value:match("^%s*(.-)%s*$") or ""
  return value, value:lower(), truncated
end

local function integer_string(value)
  if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
    and value >= 0 and value % 1 == 0
  then
    if math.type and math.type(value) == "integer" then
      return tostring(value)
    end
    return string.format("%.0f", value)
  end
  if type(value) == "string" and #value <= 32 and value:match("^%d+$") then
    return value
  end
  return nil
end

local function stable_id(process)
  if type(process) ~= "table" then
    return nil
  end
  local pid = integer_string(process.pid)
  local starttime = integer_string(process.starttime_ticks)
  if pid and starttime then
    return pid .. ":" .. starttime
  end
  if type(process.id) == "string" and #process.id >= 1 and #process.id <= MAX_ID_BYTES
      and process.id:match("^[A-Za-z0-9][A-Za-z0-9_.:%-]*$") then
    return process.id
  end
  return nil
end

local function finite_number(value)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
    return nil
  end
  return value
end

local function io_value(process, direction)
  local nested = type(process.io) == "table" and process.io or nil
  return finite_number(process["io_" .. direction])
    or finite_number(process[direction .. "_bytes"])
    or (nested and finite_number(nested[direction .. "_bytes"]))
    or (nested and finite_number(nested[direction .. "_bytes_per_second"]))
end

local function sort_value(record, key)
  local process = record.process
  if key == "cpu" then
    return finite_number(process.cpu_percent)
  elseif key == "memory" then
    return finite_number(process.resident_bytes)
  elseif key == "pid" then
    return finite_number(process.pid) or tonumber(process.pid)
  elseif key == "name" then
    local value = process.name or process.command
    return type(value) == "string" and value:lower() or nil
  elseif key == "time" then
    return finite_number(process.cpu_ticks)
  elseif key == "threads" then
    return finite_number(process.threads)
  elseif key == "virtual" then
    return finite_number(process.virtual_bytes)
  elseif key == "state" then
    return type(process.state) == "string" and process.state or nil
  elseif key == "user" then
    local value = process.user or (process.uid and tostring(process.uid))
    return type(value) == "string" and value:lower() or nil
  elseif key == "io_read" then
    return io_value(process, "read")
  elseif key == "io_write" then
    return io_value(process, "write")
  end
  return nil
end

local function stable_less(left, right)
  local left_pid = finite_number(left.process.pid) or tonumber(left.process.pid)
  local right_pid = finite_number(right.process.pid) or tonumber(right.process.pid)
  if left_pid ~= right_pid then
    if left_pid == nil then return false end
    if right_pid == nil then return true end
    return left_pid < right_pid
  end
  local left_start = finite_number(left.process.starttime_ticks) or tonumber(left.process.starttime_ticks)
  local right_start = finite_number(right.process.starttime_ticks) or tonumber(right.process.starttime_ticks)
  if left_start ~= right_start then
    if left_start == nil then return false end
    if right_start == nil then return true end
    return left_start < right_start
  end
  if left.id ~= right.id then
    return left.id < right.id
  end
  return left.input_index < right.input_index
end

local function comparator(key, descending)
  return function(left, right)
    local left_value = sort_value(left, key)
    local right_value = sort_value(right, key)
    if left_value == nil or right_value == nil then
      if left_value == nil and right_value == nil then
        return stable_less(left, right)
      end
      -- Missing values are always last, including for ascending sorts.
      return left_value ~= nil
    end
    if left_value == right_value then
      return stable_less(left, right)
    end
    if descending then
      return left_value > right_value
    end
    return left_value < right_value
  end
end

local function shallow_row(record, depth, direct_match, included_children)
  local row = {}
  for key, value in pairs(record.process) do
    row[key] = value
  end
  row.id = record.id
  row.tree_depth = depth or 0
  row.tree_has_children = included_children and included_children > 0 or false
  row.tree_orphan = record.orphan == true
  row.tree_cycle = record.cycle == true
  row.filter_match = direct_match == true
  row.filter_ancestor = direct_match ~= true
  return row
end

-- Query grammar.  Whitespace separates terms and every term must match, so
-- adding a word narrows the result the way a search box is expected to.
--
--   root                bare substring, matched against every field
--   user:root           restrict a term to one field
--   !kernel             negate a term
--   /^systemd%-/        a Lua pattern (Lua patterns, not PCRE — `%` escapes)
--
-- A bare substring is still the common case, so a query with no colons,
-- exclamation marks or slashes behaves exactly as it did before.
local QUERY_FIELDS = {
  pid = "pid",
  ppid = "parent_pid",
  user = "user",
  state = "state",
  name = "name",
  cmd = "command",
  command = "command",
}

local MAX_QUERY_TERMS = 16

local function field_text(process, field)
  local value = process[field]
  if value == nil then return nil end
  return tostring(value):lower()
end

local function compile_query(normalized_query)
  if normalized_query == "" then return nil end
  local terms = {}
  for raw in normalized_query:gmatch("%S+") do
    if #terms >= MAX_QUERY_TERMS then break end
    -- Lua 5.5 makes the generic-for variable const, so the term is edited
    -- through a local copy.
    local word = raw
    local term = { negate = false }
    if word:sub(1, 1) == "!" then
      term.negate = true
      word = word:sub(2)
    end
    if word ~= "" then
      local field, rest = word:match("^([a-z]+):(.*)$")
      if field and QUERY_FIELDS[field] then
        term.field = QUERY_FIELDS[field]
        word = rest
      end
      local pattern = word:match("^/(.*)/$") or (#word > 1 and word:sub(1, 1) == "/"
        and word:sub(2) or nil)
      if pattern and pattern ~= "" then
        -- A malformed pattern must narrow nothing rather than raise inside the
        -- render loop, so it is validated once here and demoted to a literal.
        local ok = pcall(string.find, "", pattern)
        if ok then
          term.pattern = pattern
        else
          term.text = word:lower()
        end
      elseif word ~= "" then
        term.text = word
      end
      if term.text or term.pattern then terms[#terms + 1] = term end
    end
  end
  if #terms == 0 then return nil end
  return terms
end

local function term_matches(process, term)
  local fields
  if term.field then
    fields = { field_text(process, term.field) }
  else
    fields = {
      field_text(process, "pid"), field_text(process, "name"),
      field_text(process, "command"), field_text(process, "user"),
      field_text(process, "state"),
    }
  end
  for _, value in ipairs(fields) do
    if value then
      if term.pattern then
        local ok, found = pcall(string.find, value, term.pattern)
        if ok and found then return true end
      elseif value:find(term.text, 1, true) then
        return true
      end
    end
  end
  return false
end

local function process_matches(process, compiled)
  if compiled == nil then return true end
  for _, term in ipairs(compiled) do
    if term_matches(process, term) == term.negate then return false end
  end
  return true
end

local function build_records(process_list)
  local records = {}
  local by_id = {}
  local invalid = 0
  local duplicates = 0
  if type(process_list) ~= "table" then
    process_list = {}
  end
  for index, process in ipairs(process_list) do
    local id = stable_id(process)
    if not id then
      invalid = invalid + 1
    elseif by_id[id] then
      duplicates = duplicates + 1
    else
      local record = {
        id = id,
        process = process,
        input_index = index,
      }
      records[#records + 1] = record
      by_id[id] = record
    end
  end
  return records, by_id, invalid, duplicates
end

-- Retain only the rows that can ever reach the viewport.  `better(a, b)` is
-- the final ordering predicate; the heap deliberately keeps the worst retained
-- record at its root so a better candidate can replace it in O(log limit).
local function bounded_best(records, limit, better, matches)
  local heap = {}
  local matched = 0

  local function worse(left, right)
    return better(right, left)
  end

  local function sift_up(index)
    while index > 1 do
      local parent = math.floor(index / 2)
      if not worse(heap[index], heap[parent]) then break end
      heap[index], heap[parent] = heap[parent], heap[index]
      index = parent
    end
  end

  local function sift_down(index)
    while true do
      local left = index * 2
      if left > #heap then break end
      local right = left + 1
      local child = right <= #heap and worse(heap[right], heap[left]) and right or left
      if not worse(heap[child], heap[index]) then break end
      heap[index], heap[child] = heap[child], heap[index]
      index = child
    end
  end

  for _, record in ipairs(records) do
    if not matches or matches(record) then
      matched = matched + 1
      if #heap < limit then
        heap[#heap + 1] = record
        sift_up(#heap)
      elseif better(record, heap[1]) then
        heap[1] = record
        sift_down(1)
      end
    end
  end
  table.sort(heap, better)
  return heap, matched
end

local function attach_parents(records)
  local by_pid = {}
  local duplicate_pids = 0
  for _, record in ipairs(records) do
    local pid = finite_number(record.process.pid) or tonumber(record.process.pid)
    if pid and pid > 0 and pid % 1 == 0 then
      local existing = by_pid[pid]
      if not existing then
        by_pid[pid] = record
      else
        duplicate_pids = duplicate_pids + 1
        if stable_less(record, existing) then
          by_pid[pid] = record
        end
      end
    end
  end

  local orphans = 0
  for _, record in ipairs(records) do
    local parent_pid = finite_number(record.process.parent_pid) or tonumber(record.process.parent_pid)
    if parent_pid and parent_pid > 0 and parent_pid % 1 == 0 then
      record.parent = by_pid[parent_pid]
      if not record.parent then
        record.orphan = true
        orphans = orphans + 1
      end
    end
  end

  -- A process has at most one parent, so following parent pointers turns
  -- cycle detection into a bounded functional-graph walk. Break one stable
  -- edge per cycle before constructing children.
  local ordered = {}
  for index, record in ipairs(records) do ordered[index] = record end
  table.sort(ordered, stable_less)
  local done = {}
  local cycles = 0
  for _, start in ipairs(ordered) do
    if not done[start] then
      local path = {}
      local position = {}
      local current = start
      while current and not done[current] and not position[current] do
        position[current] = #path + 1
        path[#path + 1] = current
        current = current.parent
      end
      if current and position[current] then
        local breaker = path[position[current]]
        for index = position[current] + 1, #path do
          if stable_less(path[index], breaker) then
            breaker = path[index]
          end
        end
        breaker.parent = nil
        breaker.cycle = true
        cycles = cycles + 1
      end
      for _, record in ipairs(path) do done[record] = true end
    end
  end

  for _, record in ipairs(records) do
    record.children = {}
  end
  for _, record in ipairs(records) do
    if record.parent then
      record.parent.children[#record.parent.children + 1] = record
    end
  end
  return orphans, cycles, duplicate_pids
end

function Controller.new(options)
  if options ~= nil and type(options) ~= "table" then
    error("process table options must be a table", 2)
  end
  options = options or {}
  local sort_key = SORT_KEYS[options.sort_key] and options.sort_key or "cpu"
  local descending = type(options.descending) == "boolean"
    and options.descending or DEFAULT_DESCENDING[sort_key]
  local maximum_query_bytes = bounded_integer(options.max_query_bytes, 256, 1, 4096)
  local query, normalized_query, query_truncated = normalize_query(options.query, maximum_query_bytes)
  local self = setmetatable({
    _sort_key = sort_key,
    _descending = descending,
    _query = query,
    _normalized_query = normalized_query,
    _compiled_query = compile_query(normalized_query),
    _query_truncated = query_truncated,
    _tree = options.tree == true,
    _max_query_bytes = maximum_query_bytes,
    _max_tree_depth = bounded_integer(options.max_tree_depth, 64, 1, 256),
    _max_rows = bounded_integer(options.max_rows, DEFAULT_MAX_ROWS, 1, HARD_MAX_ROWS),
    _processes = {},
    _records = {},
    _record_by_id = {},
    _rows = {},
    _selected_id = nil,
    _selected_index = 0,
    _revision = 0,
    _stats = {},
  }, Controller)
  self:update({})
  return self
end

function Controller:_rebuild(preferred_id, preferred_index)
  local records, by_id, invalid, duplicates = build_records(self._processes)
  local orphans, cycles, duplicate_pids = 0, 0, 0
  if self._tree then
    orphans, cycles, duplicate_pids = attach_parents(records)
  end
  self._records = records
  self._record_by_id = by_id

  local compare = comparator(self._sort_key, self._descending)
  local rows = {}
  local depth_limited = 0
  local matched, included = 0, 0
  if self._tree then
    local direct = {}
    for _, record in ipairs(records) do
      if process_matches(record.process, self._compiled_query) then
        direct[record] = true
        matched = matched + 1
      end
    end

    local include = {}
    if self._normalized_query ~= "" then
      for record in pairs(direct) do
        local current = record
        while current and not include[current] do
          include[current] = true
          included = included + 1
          current = current.parent
        end
      end
    else
      for record in pairs(direct) do
        include[record] = true
        included = included + 1
      end
    end

    local roots = {}
    for _, record in ipairs(records) do
      if include[record] and not record.parent then
        roots[#roots + 1] = record
      end
      table.sort(record.children, compare)
    end
    table.sort(roots, compare)

    local stack = {}
    for index = #roots, 1, -1 do
      stack[#stack + 1] = { record = roots[index], depth = 0 }
    end
    local emitted = {}
    while #stack > 0 and #rows < self._max_rows do
      local item = stack[#stack]
      stack[#stack] = nil
      local record = item.record
      if not emitted[record] then
        emitted[record] = true
        local visible_children = {}
        for _, child in ipairs(record.children) do
          if include[child] then visible_children[#visible_children + 1] = child end
        end
        rows[#rows + 1] = shallow_row(record, item.depth, direct[record], #visible_children)
        for index = #visible_children, 1, -1 do
          local depth = item.depth + 1
          if depth > self._max_tree_depth then
            depth = self._max_tree_depth
            depth_limited = depth_limited + 1
          end
          stack[#stack + 1] = { record = visible_children[index], depth = depth }
        end
      end
    end
    -- Defensive fallback: a malformed parent graph must never hide a row.
    local remaining = {}
    for _, record in ipairs(records) do
      if #rows + #remaining >= self._max_rows then break end
      if include[record] and not emitted[record] then remaining[#remaining + 1] = record end
    end
    table.sort(remaining, compare)
    for _, record in ipairs(remaining) do
      rows[#rows + 1] = shallow_row(record, 0, direct[record], 0)
    end
  else
    local visible
    visible, matched = bounded_best(records, self._max_rows, compare, function(record)
      return process_matches(record.process, self._compiled_query)
    end)
    included = matched

    -- Keep the user's current identity visible across a sort change even when
    -- it falls just outside the bounded top set. Search can still reach every
    -- collected process because matching happens before the heap limit.
    local preferred = preferred_id and by_id[preferred_id] or nil
    if preferred and process_matches(preferred.process, self._compiled_query) then
      local found = false
      for _, record in ipairs(visible) do
        if record == preferred then found = true; break end
      end
      if not found and #visible > 0 then
        visible[#visible] = preferred
        table.sort(visible, compare)
      end
    end
    for _, record in ipairs(visible) do
      rows[#rows + 1] = shallow_row(record, 0, true, 0)
    end
  end

  self._rows = rows
  self._selected_id = nil
  self._selected_index = 0
  if #rows > 0 then
    if preferred_id then
      for index, row in ipairs(rows) do
        if row.id == preferred_id then
          self._selected_id = row.id
          self._selected_index = index
          break
        end
      end
    end
    if not self._selected_id then
      local index = bounded_integer(preferred_index, 1, 1, #rows)
      self._selected_index = index
      self._selected_id = rows[index].id
    end
  end
  self._stats = {
    total = #records,
    visible = #rows,
    matched = matched,
    included = included,
    truncated = included > #rows,
    invalid = invalid,
    duplicates = duplicates,
    duplicate_pids = duplicate_pids,
    orphans = orphans,
    cycles = cycles,
    depth_limited = depth_limited,
  }
  self._revision = self._revision + 1
end

function Controller:update(process_list)
  local preferred_id = self._selected_id
  local preferred_index = self._selected_index
  self._processes = type(process_list) == "table" and process_list or {}
  self:_rebuild(preferred_id, preferred_index)
  return self
end

-- Snapshots preserve an unchanged process list by reference between process
-- collector ticks. Views that repaint for faster CPU/network samples can skip
-- the high-cardinality tree/sort rebuild without weakening update() semantics.
function Controller:update_if_changed(process_list)
  process_list = type(process_list) == "table" and process_list or {}
  if self._processes ~= process_list then
    self:update(process_list)
    return true
  end
  return false
end

function Controller:rows()
  return self._rows
end

function Controller:selected()
  return self._rows[self._selected_index]
end

function Controller:selected_id()
  return self._selected_id
end

function Controller:move(delta)
  if #self._rows == 0 then
    return nil
  end
  delta = tonumber(delta)
  if not delta or delta ~= delta or delta == math.huge or delta == -math.huge then
    return self:selected()
  end
  delta = delta < 0 and math.ceil(delta) or math.floor(delta)
  local index = math.max(1, math.min(#self._rows, self._selected_index + delta))
  self._selected_index = index
  self._selected_id = self._rows[index].id
  return self._rows[index]
end

--- Select by row position, clamped to the visible set.
-- Mouse clicks and Home/End address rows by index rather than by identity.
function Controller:select_index(index)
  if #self._rows == 0 then
    return false
  end
  index = tonumber(index)
  if not index or index ~= index or index == math.huge or index == -math.huge then
    return false
  end
  index = math.max(1, math.min(#self._rows, math.floor(index)))
  self._selected_index = index
  self._selected_id = self._rows[index].id
  return true, self._rows[index]
end

function Controller:select_id(id)
  if id == nil then
    return false
  end
  id = tostring(id)
  for index, row in ipairs(self._rows) do
    if row.id == id then
      self._selected_index = index
      self._selected_id = id
      return true, row
    end
  end
  return false
end

function Controller:set_query(query)
  local preferred_id = self._selected_id
  local preferred_index = self._selected_index
  self._query, self._normalized_query, self._query_truncated = normalize_query(query, self._max_query_bytes)
  self._compiled_query = compile_query(self._normalized_query)
  self:_rebuild(preferred_id, preferred_index)
  return self._query, self._query_truncated
end

function Controller:set_sort(key, descending)
  if not SORT_KEYS[key] then
    return false, "invalid_sort_key"
  end
  if descending ~= nil and type(descending) ~= "boolean" then
    return false, "descending_must_be_boolean"
  end
  local preferred_id = self._selected_id
  local preferred_index = self._selected_index
  self._sort_key = key
  self._descending = descending == nil and DEFAULT_DESCENDING[key] or descending
  self:_rebuild(preferred_id, preferred_index)
  return true
end

function Controller:cycle_sort()
  local index = SORT_KEYS[self._sort_key] or 1
  local key = SORT_ORDER[(index % #SORT_ORDER) + 1]
  self:set_sort(key, DEFAULT_DESCENDING[key])
  return key, self._descending
end

--- Flip the current sort direction without changing the column.
-- The UI previously exposed only a forward cycle through the sort keys, so a
-- user who wanted "smallest first" had no way to ask for it even though the
-- model always supported both directions.
function Controller:toggle_direction()
  self:set_sort(self._sort_key, not self._descending)
  return self._descending
end

--- Show full executable paths in place of bare command names.
function Controller:toggle_paths()
  self._show_paths = not self._show_paths
  -- The rendered name changes, so consumers keyed on the revision must
  -- rebuild even though the underlying set did not change.
  self._revision = self._revision + 1
  return self._show_paths
end

function Controller:toggle_tree()
  local preferred_id = self._selected_id
  local preferred_index = self._selected_index
  self._tree = not self._tree
  self:_rebuild(preferred_id, preferred_index)
  return self._tree
end

function Controller:status()
  local status = {
    total = self._stats.total or 0,
    visible = self._stats.visible or 0,
    invalid = self._stats.invalid or 0,
    duplicates = self._stats.duplicates or 0,
    duplicate_pids = self._stats.duplicate_pids or 0,
    orphans = self._stats.orphans or 0,
    cycles = self._stats.cycles or 0,
    depth_limited = self._stats.depth_limited or 0,
    matched = self._stats.matched or 0,
    included = self._stats.included or 0,
    truncated = self._stats.truncated == true,
    selected_index = self._selected_index,
    selected_id = self._selected_id,
    sort_key = self._sort_key,
    descending = self._descending,
    query = self._query,
    query_highlights = (function()
      local result = {}
      for _, term in ipairs(self._compiled_query or {}) do
        if term.text and not term.negate and #term.text > 0 then
          result[#result + 1] = term.text
        end
      end
      return result
    end)(),
    query_bytes = #self._query,
    query_truncated = self._query_truncated,
    max_query_bytes = self._max_query_bytes,
    tree = self._tree,
    show_paths = self._show_paths == true,
    max_tree_depth = self._max_tree_depth,
    max_rows = self._max_rows,
    revision = self._revision,
  }
  return status
end

Controller.sort_order = SORT_ORDER
Controller.stable_id = stable_id
Controller.MAX_ID_BYTES = MAX_ID_BYTES

return Controller
