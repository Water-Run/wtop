-- A byte initializer per payload byte exhausts the address space of a 32-bit
-- compiler on large bundles. Fixed-width octal string literals retain the
-- exact bytes with much less compiler bookkeeping. The backing terminator is
-- excluded by the original file size in the payload table, including empties.
return function(files)
    local lines = {}
    for index, file in ipairs(files) do
        local content = file.content
        lines[#lines + 1] = string.format("static const unsigned char luai_file_%d[%d] =", index, #content + 1)
        if #content == 0 then
            lines[#lines + 1] = '    ""'
        else
            for offset = 1, #content, 256 do
                local escaped = content:sub(offset, offset + 255):gsub(".", function(byte)
                    return string.format("\\%03o", byte:byte())
                end)
                lines[#lines + 1] = '    "' .. escaped .. '"'
            end
        end
        lines[#lines + 1] = ";"
    end
    return table.concat(lines, "\n")
end
