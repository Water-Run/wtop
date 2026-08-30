package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local Decoder = require("wtop.input")
local decoder = Decoder.new()

local plain = decoder:feed("q 1\t\3")
assert(plain[1].key == "q")
assert(plain[2].key == "space")
assert(plain[3].key == "1")
assert(plain[4].key == "tab")
assert(plain[5].key == "c" and plain[5].ctrl)

assert(#decoder:feed("\27[") == 0)
local arrow = decoder:feed("C")
assert(arrow[1].key == "right")
assert(decoder:feed("\27[1;5D")[1].key == "left")
assert(decoder:feed("\27[1;5D")[1].ctrl == true)
assert(decoder:feed("\27[Z")[1].key == "shift_tab")
assert(decoder:feed("\27OP")[1].key == "f1")

local mouse = decoder:feed("\27[<0;12;4M")[1]
assert(mouse.type == "mouse" and mouse.x == 12 and mouse.y == 4)

assert(#decoder:feed("\27[200~ignored\27[201~") == 0)
assert(#decoder:feed("\27") == 0)
assert(decoder:flush_escape()[1].key == "escape")

return true
