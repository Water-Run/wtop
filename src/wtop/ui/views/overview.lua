local Layout = require("wtop.ui.layout")
local Page = require("wtop.ui.views.page")

local M = {}

function M.new(options)
  options = options or {}
  local widgets = {
    Layout.widget({id = "cpu", kind = "metric", priority = 100, min_width = 28, min_height = 7}),
    Layout.widget({id = "memory", kind = "metric", priority = 90, min_width = 28, min_height = 7}),
    Layout.widget({id = "pressure", kind = "metric", priority = 80, min_width = 28, min_height = 7}),
  }
  return Page.new({
    id = "overview",
    brand = options.brand,
    theme = options.theme,
    tabs = options.tabs or {
      {id = "overview", label_id = "tabs.overview", label = "Overview"},
      {id = "processes", label_id = "tabs.processes", label = "Processes"},
      {id = "compute", label_id = "tabs.compute", label = "Compute"},
      {id = "storage", label_id = "tabs.storage", label = "I/O"},
      {id = "network", label_id = "tabs.network", label = "Network"},
      {id = "gpu", label_id = "tabs.gpu", label = "GPU"},
      {id = "workloads", label_id = "tabs.workloads", label = "Workloads"},
      {id = "insights", label_id = "tabs.insights", label = "Insights"},
    },
    layout = Layout.flow(widgets, {gap = 1}),
    widgets = options.widgets or {
      cpu = {label_id = "metrics.cpu", label = "CPU", unit = "%", value = 0, history = {}},
      memory = {label_id = "metrics.memory", label = "Memory", unit = "%", value = 0, history = {}},
      pressure = {label_id = "metrics.pressure", label = "PSI", unit = "%", value = 0, history = {}},
    },
    registry = options.registry,
  })
end

return M
