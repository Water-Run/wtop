-- Public UI facade.  All components are pure Lua and terminal-independent.
local M = {
  Backend = require("wtop.ui.backend"),
  Theme = require("wtop.ui.theme"),
  Renderer = require("wtop.ui.renderer"),
  Layout = require("wtop.ui.layout"),
  Input = require("wtop.ui.input"),
  Widgets = require("wtop.ui.widgets"),
  Views = require("wtop.ui.views"),
}

M.Grid = M.Renderer.Grid
M.Page = M.Views.Page

return M
