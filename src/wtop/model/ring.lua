local Ring = {}
Ring.__index = Ring

function Ring.new(capacity)
  if type(capacity) ~= "number" or capacity ~= capacity
      or capacity == math.huge or capacity == -math.huge
      or capacity < 1 or capacity > 1000000 or capacity % 1 ~= 0 then
    error("ring capacity must be a positive integer", 2)
  end
  return setmetatable({
    capacity = capacity,
    size = 0,
    head = 0,
    items = {},
  }, Ring)
end

function Ring:len()
  return self.size
end

function Ring:is_full()
  return self.size == self.capacity
end

function Ring:push(value)
  self.head = (self.head % self.capacity) + 1
  local replaced = self.items[self.head]
  self.items[self.head] = value
  if self.size < self.capacity then
    self.size = self.size + 1
    replaced = nil
  end
  return replaced
end

-- Logical indexes are oldest-first and one-based.
function Ring:get(index)
  if type(index) ~= "number" or index < 1 or index > self.size or index % 1 ~= 0 then
    return nil
  end
  local oldest = ((self.head - self.size) % self.capacity) + 1
  local physical = ((oldest + index - 2) % self.capacity) + 1
  return self.items[physical]
end

function Ring:oldest()
  return self:get(1)
end

function Ring:newest()
  if self.size == 0 then
    return nil
  end
  return self.items[self.head]
end

function Ring:iter()
  local index = 0
  return function()
    index = index + 1
    if index <= self.size then
      return index, self:get(index)
    end
  end
end

function Ring:values()
  local values = {}
  for index = 1, self.size do
    values[index] = self:get(index)
  end
  return values
end

function Ring:clear()
  self.items = {}
  self.size = 0
  self.head = 0
end

function Ring:resize(capacity)
  if type(capacity) ~= "number" or capacity ~= capacity
      or capacity == math.huge or capacity == -math.huge
      or capacity < 1 or capacity > 1000000 or capacity % 1 ~= 0 then
    error("ring capacity must be a positive integer", 2)
  end
  local keep = math.min(self.size, capacity)
  local values = {}
  for index = self.size - keep + 1, self.size do
    values[#values + 1] = self:get(index)
  end
  self.capacity = capacity
  self:clear()
  for _, value in ipairs(values) do
    self:push(value)
  end
  return self
end

return Ring
