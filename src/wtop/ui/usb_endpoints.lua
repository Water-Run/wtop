local Public = require("wtop.format.usb_endpoints")
local Technical = require("wtop.i18n.technical")
local M = {}
local TYPE_LABELS = {
  control = { "inventory.usb_type_control", "Control" },
  isochronous = { "inventory.usb_type_isochronous", "Isochronous" },
  bulk = { "inventory.usb_type_bulk", "Bulk" },
  interrupt = { "inventory.usb_type_interrupt", "Interrupt" },
}
local DIRECTION_LABELS = {
  ["in"] = { "inventory.usb_direction_in", "To host" },
  out = { "inventory.usb_direction_out", "To device" },
  both = { "inventory.usb_direction_both", "Both directions" },
}
local function translated(i18n, label)
  if not label then return nil end
  local text = i18n and i18n:t(label[1])
  return text and text ~= label[1] and text or label[2]
end
function M.append(value, add, lines, i18n, current)
  local detail = Public.public(value, not current, 30)
  if not detail then return end
  lines[#lines + 1] = ""
  add("inventory.usb_endpoint_observation", "Endpoint observation", Technical.state(i18n, detail.quality))
  add("metrics.source", "Source", detail.source)
  if detail.list then
    add("inventory.usb_endpoints_read", "Endpoints read", tostring(#detail.list) .. " / " .. tostring(detail.total or "?"))
    for _, row in ipairs(detail.list) do
      add("inventory.usb_endpoint", "Endpoint", row.address and string.format("0x%02X", row.address) or row.id)
      add("inventory.usb_transfer_type", "Transfer type", translated(i18n, TYPE_LABELS[row.transfer_type]))
      add("inventory.usb_direction", "Direction", translated(i18n, DIRECTION_LABELS[row.direction]))
      add("inventory.usb_max_packet", "Maximum packet (bytes)", row.max_packet_bytes)
      add("inventory.usb_interval_code", "Descriptor interval code", row.interval_code)
      add("inventory.usb_interval_us", "Reported interval (us)", row.interval_microseconds)
      add("inspector.quality", "Quality", Technical.state(i18n, row.quality))
      for _, issue in ipairs(row.issues) do
        add("inspector.reason", "Reason", issue.field .. ": " .. tostring(Technical.state(i18n, issue.status)))
      end
      add("metrics.source", "Source", row.source)
    end
  end
  for _, issue in ipairs(detail.issues) do
    add("inspector.reason", "Reason", issue.field .. ": " .. tostring(Technical.state(i18n, issue.status)))
  end
  if detail.truncated then
    add("inspector.quality", "Quality", Technical.state(i18n, "truncated"))
  end
  lines[#lines + 1] = translated(i18n, { "inventory.usb_endpoint_note",
    "Cached endpoint settings; packet size and interval are declared parameters." })
end
return M
