package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tools/?.lua;;" .. package.path

-- The release-readiness checklist, checked against the build.
--
-- `docs/PACKAGING.md` §10 is a list of boxes, and a box someone has ticked is a
-- claim that the thing is done.  Nothing was comparing those claims to anything.
-- The first item this file caught says, in one line:
--
--   [x] Rerun `make checksums` and `make sbom` on the final candidate, and
--       separately produce signatures and a complete build-provenance record.
--
-- and then, four sentences later, in the same bullet: "but it says nothing
-- about signatures, which no target produces".  So the box is ticked, the body
-- says the second half is not done, and `docs/PLAN.md` §10 lists "Signatures and
-- a full build-provenance record for formal releases" among its open decisions.
-- Two documents in one repository disagree about whether the release is signed,
-- and the disagreement is arranged so that the optimistic reading is the one a
-- reader gets by scanning the list.
--
-- That is this project's recurring shape -- a claim nobody checked -- and it is
-- the first one found in a checklist rather than in a document.  A checklist is
-- where it is most dangerous, because a checklist is read for the boxes.
--
-- The check is derived in both directions, which is what makes it more than a
-- lint.  While the plan lists a capability as open, no box may claim it; and
-- once the plan closes it, the build has to invoke whatever doing it would
-- require.  The second half is the part that earns the first: without it, the
-- guard would only forbid the claim, and the way to make the claim disappear
-- would be to edit this file.
--
-- The limit is stated rather than hidden.  This asks about capabilities that can
-- be asked of the build -- "does anything invoke a signer" is a question about
-- text, and it is answered from text.  It cannot tell whether the signer was
-- ever run with a real key, which is exactly the part a machine cannot see.

local function read_file(path)
    local handle = assert(io.open(path, "rb"), "cannot read " .. path)
    local body = handle:read("*a")
    handle:close()
    return body
end

local plan = read_file("docs/PLAN.md")
local packaging = read_file("docs/PACKAGING.md")
local makefile = read_file("Makefile")

-- ---------------------------------------------------------------------------
-- The plan's open-decisions section, and whether a given subject is still in it.

local SECTION = "待决问题与缺失证据:"
local section_start = plan:find(SECTION, 1, true)
assert(section_start ~= nil,
    "docs/PLAN.md no longer has a section headed " .. SECTION .. ", so this "
        .. "file cannot tell an open question from a closed one")
local section = plan:sub(section_start)

--- The bullet for `subject`, and whether the plan calls it closed.
-- A bullet that does not say "Closed on" is open, which is the conservative
-- reading: an entry that never got a verdict is treated as unanswered rather
-- than as decided.
--
-- The bullet is collected line by line until the next top-level one, because
-- a greedy single-line match runs straight past the end of it.  That mistake
-- was made here on the first run: the pattern consumed the whole line, ate the
-- newline, and captured the *following* bullet -- which happened to be a closed
-- one -- so the subject below was read as decided.  A guard that answers a
-- question about one entry with another entry's verdict is worse than a guard
-- that finds nothing.
local function status_of(subject)
    local escaped = subject:gsub("(%W)", "%%%1")
    local lines, collecting = {}, false
    for line in section:gmatch("[^\n]*\n?") do
        if line:match("^%- ") then
            if collecting then break end
            collecting = line:match("^%- " .. escaped) ~= nil
        end
        if collecting and line:find("%S") then
            lines[#lines + 1] = line
        end
    end
    if #lines == 0 then return nil, nil end
    local bullet = table.concat(lines, " ")
    return bullet, bullet:find("已于 %d%d%d%d%-%d%d%-%d%d 关闭") ~= nil
end

-- ---------------------------------------------------------------------------
-- §10's boxes.

--- The checklist items, as { done = bool, text = string }.
-- An item is a "- [x] " or "- [ ] " line plus every continuation line until the
-- next box, because half of these items carry their whole history in the body
-- and a claim that lives in the third line of a bullet is still a claim.
local function checklist_items(text)
    local items, current = {}, nil
    for line in text:gmatch("[^\n]+") do
        local marker = line:match("^%- %[(.)%] (.*)$")
        if marker then
            -- `marker == "x" .. " " .. line` would parse as `marker == "x ..."`,
            -- because `..` binds tighter than `==`.  The whole line is kept as
            -- the text; the marker is only ever compared.
            current = { done = (marker == "x"), text = line }
            items[#items + 1] = current
        elseif current then
            current.text = current.text .. "\n" .. line
        end
    end
    return items
end

local items = checklist_items(packaging)
local done_count = 0
for _, item in ipairs(items) do
    if item.done then done_count = done_count + 1 end
end
assert(done_count > 0,
    "no ticked box was found in docs/PACKAGING.md, so every clause below is "
        .. "passing because it read nothing rather than because it agreed")

-- ---------------------------------------------------------------------------
-- Capabilities the plan tracks and the build can be asked about.

local CAPABILITIES = {
    {
        subject = "签名与完整构建溯源记录",
        -- The word a ticked box would use.  Case-insensitive: a checklist that
        -- says "signed" rather than "signature" is claiming the same thing, and
        -- a guard that only knows one spelling is a guard that can be stepped
        -- around by choosing another.
        claim = "签名",
        -- What the build would have to invoke for the claim to be earned.
        build = { "gpg", "minisign", "cosign", "sq sign", "openssl dgst" },
        -- Where the work is tracked while it is unfinished.
        tracked_in = "docs/PLAN.md §10",
    },
}

local function build_invokes(tokens)
    -- Only recipe lines count: a signing tool named in a comment, or in a
    -- variable, does not sign anything, and the project's own rule is that a
    -- backticked path is a claim about the tree.
    for line in makefile:gmatch("[^\n]+") do
        if line:match("^\t") then
            for _, token in ipairs(tokens) do
                if line:find(token, 1, true) then return token end
            end
        end
    end
    return nil
end

for _, capability in ipairs(CAPABILITIES) do
    local bullet, closed = status_of(capability.subject)
    assert(bullet ~= nil,
        "docs/PLAN.md §10 no longer has a bullet beginning \"" ..
            capability.subject .. "\", so this file can no longer tell whether "
            .. "that capability is still owed; add it to CAPABILITIES with a "
            .. "subject the plan actually uses, or delete the entry")

    local ticked = {}
    for _, item in ipairs(items) do
        if item.done and item.text:lower():find(capability.claim, 1, true) then
            ticked[#ticked + 1] = item
        end
    end

    if not closed then
        -- `assert(cond, message)` evaluates the message even when the condition
        -- holds, so a message that indexes the very array being asserted empty
        -- throws on the passing path.  The refusal is written as an explicit
        -- branch for that reason: the passing path must not touch `ticked`.
        if #ticked > 0 then
            local first = ticked[1]
            assert(false,
                "docs/PACKAGING.md §10 ticks a box for a capability "
                    .. capability.tracked_in .. " still lists as open: "
                    .. (first.text:match("^[^\n]+") or first.text)
                    .. "\n  The box is what a reader scanning the release "
                    .. "checklist sees, and the body of the same bullet says "
                    .. "otherwise: " .. bullet
                    .. "\n  Either tick it when the capability exists, or "
                    .. "untick it and let " .. capability.tracked_in
                    .. " carry the work.  A checklist that is optimistic where "
                    .. "the plan is pessimistic is worse than either, because "
                    .. "it is the one that gets read.")
        end
    else
        -- Forward half: closing the question has to mean the capability exists.
        local token = build_invokes(capability.build)
        assert(token ~= nil,
            capability.tracked_in .. " records this capability as closed, and no "
                .. "recipe in the Makefile invokes " ..
                table.concat(capability.build, ", ") .. ".  The claim is not "
                .. "earned by the record: a closed question and a build that "
                .. "cannot answer it are two different statements.")
    end
end

return true
