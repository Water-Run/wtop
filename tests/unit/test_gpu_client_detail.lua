-- What a GPU process row aggregates.  One host PID can hold several DRM
-- clients, and the table sums them; the drill-down shows the clients, the
-- engine that did the work and the memory region the bytes sit in, because a
-- single percentage cannot say which of those is responsible.
package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local TUI = require("wtop.tui")
local I18n = require("wtop.i18n")

local function equal(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      message, tostring(expected), tostring(actual)), 0)
  end
end

local translator = assert(I18n.new({ locale = "en-US" }))
-- What `i` opens.  A process holding one client goes straight to its detail, so
-- the common case reads the same as it always did; several clients get the
-- list, which is the level this change added.
local function render(process)
  return table.concat(TUI.gpu_client_lines({ process = process, index = 1 },
    translator, true), "\n")
end
-- One client's whole picture, which is what the list leads to.
local function detail(client)
  return table.concat(TUI.gpu_client_detail_lines(client, translator), "\n")
end

local DOCKER = "8a1bcccc1234567890abcdef0123456789abcdef0123456789abcdef01234567"

-- One client, the common case: a browser holding a single render node.  The
-- collector records descriptor numbers, so the overlay must name them as such
-- rather than printing a bare number or inventing a device path.
local render_node = render({
  pid = 1234, name = "firefox",
  clients = {
    {
      id = "gpu0:firefox:1", client_id = "7", name = "firefox", driver = "i915",
      pci_bdf = "0000:00:02.0", mapping_quality = "fresh", fd_count = 2,
      fds = { 19, 20 },
      engines = {
        render = { capacity = 1, utilization_percent = 42.1,
          current_frequency_hz = 1200000000, rate_quality = "fresh" },
        copy = { capacity = 1, utilization_percent = 0, rate_quality = "fresh" },
      },
      memory = {
        total = { system = 2147483648 },
        resident = { system = 1073741824 },
        shared = { system = 268435456 },
        active = { system = 536870912 },
        purgeable = { system = 134217728 },
      },
    },
  },
})
equal(render_node:find("GPU clients", 1, true) ~= nil, true, "the overlay is titled")
equal(render_node:find("Client", 1, true) ~= nil, true, "the client is headed")
equal(render_node:find("firefox", 1, true) ~= nil, true, "the client keeps its name")
equal(render_node:find("i915", 1, true) ~= nil, true, "the driver is shown")
equal(render_node:find("0000:00:02.0", 1, true) ~= nil, true, "the PCI address is shown")
equal(render_node:find("fd 19, fd 20", 1, true) ~= nil, true,
  "descriptors are named as descriptors: " .. render_node)
equal(render_node:find("Mapping", 1, true), nil,
  "a sound mapping is not worth a row: " .. render_node)
equal(render_node:find("42.1", 1, true) ~= nil, true, "engine utilization is shown")
equal(render_node:find("1.2 GHz", 1, true) ~= nil, true, "the engine frequency is shown")
equal(render_node:find("total 2 GiB", 1, true) ~= nil, true, "total memory is formatted as bytes")
equal(render_node:find("resident 1 GiB", 1, true) ~= nil, true,
  "resident memory is formatted as bytes")
equal(render_node:find("shared 256 MiB", 1, true) ~= nil, true,
  "shared memory is formatted as bytes")
equal(render_node:find("active 512 MiB", 1, true) ~= nil, true,
  "active memory is shown")
equal(render_node:find("purgeable 128 MiB", 1, true) ~= nil, true,
  "purgeable memory is shown")
equal(render_node:find("Engines", 1, true) ~= nil, true, "engines have a section")
equal(render_node:find("Memory regions", 1, true) ~= nil, true, "memory has a section")
equal(render_node:find("Esc/Enter closes", 1, true) ~= nil, true, "the overlay says how to close")

-- A resolved path, when one is available, wins over the descriptor number.
local resolved = render({
  pid = 1, name = "x",
  clients = { { id = "a", fds = { { path = "/dev/dri/renderD128" }, 7 } } },
})
equal(resolved:find("/dev/dri/renderD128", 1, true) ~= nil, true,
  "a resolved path is shown: " .. resolved)
equal(resolved:find("fd 7", 1, true) ~= nil, true,
  "a bare descriptor is still named as one: " .. resolved)

-- A process with several clients is the reason the drill-down exists: the row
-- is one number, the answer is a list.
local multi = render({
  pid = 77, name = "render",
  clients = {
    {
      id = "a", client_id = "1", name = "render", driver = "i915",
      fds = { { path = "/dev/dri/renderD128" } },
      engines = { render = { utilization_percent = 90 } },
      memory = { total = { local0 = 1048576 } },
    },
    {
      id = "b", client_id = "2", name = "render", driver = "i915",
      fds = { { path = "/dev/dri/card0" }, { path = "/dev/dri/renderD128" } },
      engines = { compute = { utilization_percent = 5, capacity = 2 } },
      memory = { total = { local0 = 2097152 }, resident = { local0 = 1048576 } },
    },
  },
})
-- Two clients behind one pid: the list is the only place the split is visible,
-- so both have to be named and the selected one marked.  The per-client figures
-- live a level down, which is the point of the list.
equal(multi:find("ID 1", 1, true) ~= nil, true, "the first client is listed")
equal(multi:find("ID 2", 1, true) ~= nil, true, "the second client is listed")
equal(multi:find("▸", 1, true) ~= nil, true, "the list marks the selected client")
local first_detail = detail({
  id = "a", client_id = "1", name = "render", driver = "i915",
  fds = { { path = "/dev/dri/renderD128" } },
  engines = { render = { utilization_percent = 90 } },
  memory = { total = { local0 = 1048576 } },
})
local second_detail = detail({
  id = "b", client_id = "2", name = "render", driver = "i915",
  fds = { { path = "/dev/dri/card0" }, { path = "/dev/dri/renderD128" } },
  engines = { compute = { utilization_percent = 5, capacity = 2 } },
  memory = { total = { local0 = 2097152 }, resident = { local0 = 1048576 } },
})
equal(first_detail:find("90", 1, true) ~= nil, true, "the first client's engine is shown")
equal(second_detail:find("compute", 1, true) ~= nil, true,
  "the second client's engine is shown")
equal(first_detail:find("local0", 1, true) ~= nil, true, "the memory region is named")
-- A second engine on the same device is a capacity, not a percentage: showing
-- "5.0" alone would read as half idle when it is a fifth of two engines.
equal(second_detail:find("/ 2", 1, true) ~= nil, true,
  "a capacity above one is shown next to the utilization: " .. second_detail)

-- Regions are listed even when only one category was reported, and a region
-- with no numbers at all is not invented.
local sparse = render({
  pid = 5, name = "x",
  clients = {
    {
      id = "c", engines = {},
      memory = { total = { vram = 1048576 } },
    },
  },
})
equal(sparse:find("vram", 1, true) ~= nil, true, "a sparse region is still listed")
equal(sparse:find("resident", 1, true), nil,
  "a category the kernel did not report is not shown: " .. sparse)
equal(sparse:find("Engines", 1, true), nil, "a client with no engines skips the section")

-- Rate quality travels with the number, because a held reading is not the
-- same fact as a fresh one.  The assertion used to be `find("held")`, which
-- the en-US label still contains -- so it would have kept passing after the
-- word stopped being what the user sees, which is the defect this increment
-- fixed.  It now asks for the label as the renderer produces it, which is the
-- word `status.held` carries in this catalogue, and then checks a language
-- whose script the code cannot occur in.
local held = render({
  pid = 6, name = "y",
  clients = {
    {
      id = "d", engines = { render = { utilization_percent = 10, rate_quality = "held" } },
    },
  },
})
local held_line
for line in held:gmatch("[^\n]+") do
  if line:find("render", 1, true) then held_line = line end
end
equal(held_line ~= nil and held_line:find("%sHeld$") ~= nil, true,
  "a held engine reading is labelled, not spelled as a code: " .. held)
equal(held:find("estimated", 1, true), nil, "fresh readings are not marked")

local held_ja = table.concat(TUI.gpu_client_detail_lines({
  id = "d", engines = { render = { utilization_percent = 10, rate_quality = "held" } },
}, assert(I18n.new({ locale = "ja-JP" }))), "\n")
equal(held_ja:find("held", 1, true), nil,
  "an unlabelled value falls back to its raw spelling, which is English in "
  .. "every language: " .. held_ja)

-- A mapping wtop only guessed at says so next to the client's identity.
local mapped = render({
  pid = 8, name = "z",
  clients = { { id = "e", mapping_quality = "estimated" } },
})
equal(mapped:find("Mapping", 1, true) ~= nil, true, "a guessed mapping is labelled")
equal(mapped:find("Estimated", 1, true) ~= nil, true, "and it names the guess")
for _, good in ipairs({ "exact", "fresh" }) do
  local line = render({ pid = 8, name = "z", clients = { { id = "e", mapping_quality = good } } })
  equal(line:find("Mapping", 1, true), nil,
    "a " .. good .. " mapping is not shown: " .. line)
end

-- Degenerate inputs read as "nothing to show" rather than an empty overlay.
local gone = render(nil)
equal(gone:find("gone", 1, true) ~= nil, true, "a vanished process says so: " .. gone)
local empty = render({ pid = 9, name = "q", clients = {} })
equal(empty:find("No DRM client is open", 1, true) ~= nil, true,
  "a process with no open client says so: " .. empty)
local bare = render({ pid = 10 })
equal(bare:find("No DRM client is open", 1, true) ~= nil, true,
  "a process with no client list at all says so: " .. bare)
for _, text in ipairs({ gone, empty, bare }) do
  equal(text:find("Esc/Enter closes", 1, true) ~= nil, true,
    "every overlay says how to close it")
end

-- Long file lists are bounded, because one process can hold dozens of fds and
-- the overlay is a fixed-height panel.
local many = {}
for index = 1, 40 do many[index] = { path = "/dev/dri/fd" .. index } end
local crowded = render({
  pid = 11, name = "f",
  clients = { { id = "f", fds = many } },
})
equal(crowded:find("/dev/dri/fd1", 1, true) ~= nil, true, "the first file is shown")
equal(crowded:find("/dev/dri/fd40", 1, true), nil, "the list is bounded: " .. crowded)
equal(crowded:find("+36", 1, true) ~= nil, true, "the remainder is counted: " .. crowded)

-- The overlay is read-only: it must not mutate the collector's records, which
-- are shared with the table row, the exporter and the next sample.
local shared = {
  pid = 12, name = "s",
  clients = { { id = "g", engines = { render = { utilization_percent = 3 } },
    memory = { total = { system = 1 } } } },
}
render(shared)
equal(shared.clients[1].engines.render.utilization_percent, 3, "engines are untouched")
equal(shared.clients[1].memory.total.system, 1, "memory is untouched")
equal(shared.clients[1].engines.render.capacity, nil, "no field is invented")

print("ok: GPU client, engine and memory-region drill-down")
