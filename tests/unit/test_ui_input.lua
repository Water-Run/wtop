package.path = "src/?.lua;src/?/init.lua;" .. package.path

local Decoder = require("wtop.ui.input.decoder")

local function equal(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected)
      .. ", got " .. tostring(actual), 2)
  end
end

local decoder = Decoder.new()
equal(#decoder:feed("\27["), 0, "partial CSI must remain buffered")
equal(decoder:pending(), 2)
local events = decoder:feed("A")
equal(#events, 1); equal(events[1].key, "up")

events = decoder:feed("\27[1;2Z")
equal(events[1].key, "tab"); assert(events[1].shift)
events = decoder:feed(string.char(11))
equal(events[1].key, "k"); assert(events[1].ctrl)

-- Split UTF-8 is decoded only when the whole character arrives.
equal(#decoder:feed("\228\184"), 0)
events = decoder:feed("\173")
equal(events[1].text, "中")

events = decoder:feed("\27x")
equal(events[1].key, "x"); assert(events[1].alt)
events = decoder:feed("\27[200~hello\n世界\27[201~")
equal(#events, 1); equal(events[1].type, "paste")
equal(events[1].text, "hello\n世界")

events = decoder:feed("\27[<0;12;7M\27[<0;12;7m\27[<65;12;7M")
equal(#events, 3)
equal(events[1].type, "mouse"); equal(events[1].action, "press")
equal(events[1].button, 1); equal(events[1].x, 12); equal(events[1].y, 7)
equal(events[2].action, "release")
equal(events[3].action, "scroll"); equal(events[3].direction, "down")

equal(#decoder:feed("\27"), 0, "lone escape waits for timeout/flush")
events = decoder:flush()
equal(events[1].key, "escape")
equal(decoder:pending(), 0)

events = Decoder.decode("aA 1\r\27OP\27[3~")
equal(events[1].key, "a")
equal(events[2].key, "A"); assert(events[2].shift)
equal(events[3].key, "space")
equal(events[4].key, "1")
equal(events[5].key, "enter")
equal(events[6].key, "f1")
equal(events[7].key, "delete")

local bounded = Decoder.new({max_buffer_bytes = 8})
equal(#bounded:feed("\27[200~"), 0)
events = bounded:feed("overflow")
equal(events[1].type, "error"); equal(events[1].reason, "input_buffer_limit")
equal(bounded:pending(), 0)
assert(not pcall(Decoder.new, {max_buffer_bytes = math.huge}))

local sequence_bounded = Decoder.new({max_sequence_bytes = 8})
events = sequence_bounded:feed("\27[" .. string.rep("1", 12))
equal(events[1].type, "error")
equal(events[1].reason, "input_sequence_limit")
events = Decoder.decode("\27[<999999;999999999;1M")
equal(events[1].type, "unknown", "oversized mouse coordinates must be ignored")

print("test_ui_input: ok")
