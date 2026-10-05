-- The Makefile readers, over Makefiles this project does not have.
--
-- `tests/support/makefile.lua` is depended on by four test files, and until
-- this file existed it had no test of its own -- which is the shape this project
-- has now hit four times, in two different files.  A reader that has only ever
-- been exercised through a caller is a reader that only knows the sentences its
-- callers happen to use, and the cost is not hypothetical: two of the four
-- functions here had already been wrong once before this file was written, and
-- one of them was wrong at the moment it was written, in a way that was holding
-- a live clause up.
--
-- The defects this file pins, all measured before being fixed:
--
--   * `recipe_of` returned a continued prerequisite list as a recipe.  `make
--     test-all` is an aggregate with no recipe at all, and this function handed
--     back 118 bytes of its second and third prerequisite lines.  A clause in
--     `test_release_evidence.lua` was asking whether `test-all` runs
--     `test-release-notices` -- a question about prerequisites -- of this
--     function, so it passed on a misreading that happened to contain the right
--     word.  **Two defects cancelling into a correct-looking pass**, which is
--     worse than either alone: fixing only the reader breaks the clause, and
--     fixing only the clause would have left the reader wrong.
--   * `expanded` discarded make's exit status.  A malformed expression makes
--     make exit non-zero and the caller got the empty string, which is also what
--     a legitimately empty variable returns.  Every caller of this function is
--     asking what a release contains, where "nothing" and "I could not find out"
--     are different answers.
--   * `expanded` passed the expression through a single-quoted shell argument,
--     so the shell removed the quotes from any expression containing one.  A
--     perfectly valid `$(shell echo 'a  b')` made make fail, and -- because the
--     exit status was thrown away -- that failure arrived as "" as well.  Both
--     defects were needed for it to be silent.
--
-- The fixtures below are synthetic on purpose, and every one of them contains a
-- shape the project's own Makefile does not have.  That is the point: the
-- project's Makefile is why the bugs are dormant, so a fixture drawn from it
-- would only prove the readers still work on the input that hides the bugs.
--
-- One reader has a limit that is *recorded here rather than fixed*:
-- `variable_of` does not see an `export FOO := bar` line, because its pattern
-- anchors on the variable name at the start of the line.  The Makefile declares
-- no `export`, so changing that would be a rule written for a shape nothing
-- needs -- and a reader that grows untested branches is how the other three
-- got here.

package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;;" .. package.path
local makefile_api = require("support.makefile")

-- ---------------------------------------------------------------------------
-- The fixture.  Read it before the assertions: every shape it contains is named
-- in one of them.

local FIXTURE = table.concat({
    -- A plain single-line prerequisite list.
    "PLAIN: alpha beta",
    "\t@echo plain",
    "",
    -- A prerequisite list continued onto two more lines, ending without a
    -- backslash.  This is `make test-all`'s shape, and the third line is the
    -- only place `gamma` appears.
    "CONTINUED: alpha beta \\",
    "\tgamma \\",
    "\tdelta",
    "\t@echo continued",
    "",
    -- A recipe whose first line ends in a backslash, so the next tab-indented
    -- line is another recipe line rather than a continuation of anything.
    -- `test-sanitized`'s shell `for` loop has this shape.
    "SHELL_CONT: alpha",
    "\t@for x in a b; do \\",
    "\t\techo $$x; \\",
    "\tdone",
    "",
    -- Two targets, the second of which merely shares a prefix with the first.
    "PREFIX:",
    "\t@echo prefix",
    "PREFIX-EXTRA:",
    "\t@echo prefix-extra",
    "",
    -- A `:=` assignment, a `?=` assignment and a two-line one.
    "SIMPLE := one",
    "OVERRIDABLE ?= two",
    "WRAPPED := start \\",
    "\tend",
    "",
    -- A target with no recipe at all, which is what an aggregate looks like.
    "AGGREGATE: PLAIN CONTINUED",
    "",
    -- An `export` line, the shape `variable_of` is recorded as not seeing.
    "export EXPORTED := exported-value",
    "",
}, "\n")

-- ---------------------------------------------------------------------------
-- 1. recipe_of: a recipe, and only a recipe.

local function lines_of(text)
    local out = {}
    for line in text:gmatch("[^\n]+") do out[#out + 1] = line end
    return out
end

assert(makefile_api.recipe_of(FIXTURE, "PLAIN") == "\t@echo plain",
    "a one-line prerequisite list was misread: a rule with a plain single-line "
        .. "prerequisite list should hand back its recipe and nothing else")
assert(makefile_api.recipe_of(FIXTURE, "CONTINUED") == "\t@echo continued",
    "a continued prerequisite list came back as the recipe.  The second and "
        .. "third prerequisite lines are tab-indented, exactly like a recipe "
        .. "line, and the only thing that tells them apart is that the line "
        .. "before them ended in a backslash.  Read: ["
        .. makefile_api.recipe_of(FIXTURE, "CONTINUED") .. "]")
-- The strongest form of the same clause, on the real target: `make test-all` is
-- an aggregate and has no recipe, so anything non-empty here is a
-- prerequisite line that has been promoted into one.
local real = assert(io.open("Makefile", "r"))
local real_text = real:read("*a")
real:close()
assert(makefile_api.recipe_of(real_text, "test-all") == "",
    "`make test-all` is an aggregate with no recipe, but recipe_of returned ["
        .. makefile_api.recipe_of(real_text, "test-all")
        .. "].  A clause in test_release_evidence.lua asks whether test-all runs "
        .. "a gate -- a question about prerequisites -- and was asking it of "
        .. "this function, so it was reading the answer out of the wrong kind of "
        .. "line and passing by accident.")
-- A recipe whose first line ends in a backslash keeps all of it.  This is the
-- half of the flag's job that the real Makefile depends on: `test-sanitized`
-- opens with a shell `for ... do \` and three more lines follow it, and a reader
-- that re-arms the continuation flag from a recipe line throws the rest away.
-- Asserted on the *last* line rather than the first, because the first is
-- collected either way and an assertion about it passes against the bug.
assert(makefile_api.recipe_of(FIXTURE, "SHELL_CONT")
        == "\t@for x in a b; do \\\n\t\techo $$x; \\\n\tdone",
    "a recipe that opens with a shell continuation was truncated: ["
        .. makefile_api.recipe_of(FIXTURE, "SHELL_CONT") .. "]")
assert(makefile_api.recipe_of(real_text, "test-sanitized")
        :find("SANITIZER_EXCLUDED", 1, true) ~= nil,
    "recipe_of lost the end of `test-sanitized`'s recipe.  Its shell `for` loop "
        .. "spans four tab-indented lines, and the last one names the test files "
        .. "the sanitizer is allowed to run.  A reader that treats a recipe line "
        .. "ending in a backslash as a prerequisite continuation stops at the "
        .. "first of them, so an assertion about the first line passes against "
        .. "exactly that.")
-- A target whose name is a prefix of another is not that other target.
assert(makefile_api.recipe_of(FIXTURE, "PREFIX") == "\t@echo prefix",
    "reading PREFIX returned the recipe of PREFIX-EXTRA; the search anchors on "
        .. "the target name followed by a colon, which a longer name does not have")
assert(makefile_api.recipe_of(FIXTURE, "PREFIX-EXTRA") == "\t@echo prefix-extra",
    "PREFIX-EXTRA's own recipe was not read")
assert(makefile_api.recipe_of(FIXTURE, "no-such-target") == "",
    "a target that does not exist should read as an empty recipe rather than "
        .. "the recipe of whatever rule the scan reached next")

-- ---------------------------------------------------------------------------
-- 2. variable_of: an assignment, and only an assignment.

assert(makefile_api.variable_of(FIXTURE, "SIMPLE") == "one",
    "a `:=` assignment was not read")
assert(makefile_api.variable_of(FIXTURE, "OVERRIDABLE") == "two",
    "a `?=` assignment was not read.  These are the defaults that let a caller "
        .. "name an output -- `BASELINE_OUTPUT ?= dist/BASELINE.txt` -- and a "
        .. "reader that only knows `:=` reports \"no such variable\" about one "
        .. "that is right there, which is the dangerous kind of answer: it "
        .. "reads as an absence in the Makefile rather than an absence in the "
        .. "reader.")
-- A wrapped assignment comes back joined with a *double* space, because the
-- first part keeps the space that sat before its trailing backslash and the
-- join adds one of its own.  That is the real Makefile's behaviour too --
-- `RELEASE_ELFS` reads back with a double space before `$(CURDIR)`.  It is
-- pinned here rather than tidied away, because every caller either matches
-- non-space runs (`NATIVE_SOURCES` is scanned with `native/%S+%.c`) or compares
-- whole values, and a reader that silently re-spaced a path would be a change
-- nobody measured.  It is also a loud failure rather than a quiet one: a value
-- with a stray space is a filename that does not exist, and the clauses that
-- consume these values fail when they cannot find it.
assert(makefile_api.variable_of(FIXTURE, "WRAPPED") == "start  end",
    "a two-line assignment did not come back joined the way it always has: ["
        .. makefile_api.variable_of(FIXTURE, "WRAPPED")
        .. "].  If this changed deliberately, the double space at a "
        .. "continuation join is what the note above is describing.")
-- The off-by-one this helper had: a single-line variable used to pick up the
-- line after it, which for a Makefile variable is the next variable or the next
-- target -- a file path with a target's prerequisites glued onto it.
assert(makefile_api.variable_of(FIXTURE, "SIMPLE") ~= "one SIMPLE:",
    "the value picked up the line that follows it, which is how a single-line "
        .. "variable came back as \"dist/BASELINE.txt baseline: native toolchain\"")
-- The recorded limit.  This is the shape `variable_of` does not read, kept as a
-- test so that "it does not see `export`" stays a fact about this reader rather
-- than something a future reader has to rediscover.
assert(makefile_api.variable_of(FIXTURE, "EXPORTED") == "",
    "variable_of now reads an `export NAME := value` line, so the limit "
        .. "recorded in the comment above no longer holds.  The project's "
        .. "Makefile declares no export, so this is a change nobody asked for; "
        .. "decide it deliberately rather than by a test that moved.")

-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- 3. prerequisites_of: make's answer, or a refusal that names itself.
--
--     The synthetic fixture cannot be used here, and that is not an
--     inconvenience: this reader asks the *project's* Makefile, so the only
--     thing a fixture could add is the reader's own error handling.  What it
--     returns for `test-all` is pinned in section 6h of
--     `test_release_evidence.lua`, next to the clause that consumes it.

-- A target with no prerequisites is a real answer...
local empty = makefile_api.prerequisites_of("checksums")
assert(type(empty) == "table" and #empty == 0,
    "`make checksums` declares no prerequisites, so this reader should hand "
        .. "back an empty list, and it handed back " .. tostring(empty))
-- ...and a target that does not exist is a refusal.  Every caller of every
-- reader in this file is asking what something covers, so those two must not
-- look alike: an empty list is the answer "this rule requires nothing", and a
-- refusal is the answer "I could not find out", and a typo in a target name is
-- the cheapest way there is to turn a coverage gate off.
local absent, absent_refusal = makefile_api.prerequisites_of("no-such-target")
assert(absent == nil,
    "a target that does not exist came back as " .. tostring(absent)
        .. " rather than refused")
assert(type(absent_refusal) == "string" and absent_refusal:find("no%-such%-target") ~= nil,
    "the refusal does not name the target it could not read: "
        .. tostring(absent_refusal))
-- The name reaches a shell, so it is checked rather than quoted.
assert(not pcall(makefile_api.prerequisites_of, "test-all; false"),
    "a target name containing a shell separator reached the shell instead of "
        .. "being refused")

-- 4. expanded: the value, or a refusal.  Never a bare "" for a failed question.

local value = makefile_api.expanded("$(RELEASE_BUNDLE)")
assert(type(value) == "string" and value:find("/dist/wtop", 1, true) ~= nil,
    "expanded could not read a variable the project's own Makefile declares, so "
        .. "this clause is asserting nothing about a reader nobody has exercised")
-- The empty string is still a legitimate answer: an undefined variable expands
-- to nothing, and the reader must be able to say so.
local undefined = makefile_api.expanded("$(NO_SUCH_VARIABLE_IN_THIS_PROJECT)")
assert(undefined == "",
    "an undefined make variable should read as the empty string -- the answer is "
        .. "genuinely that there is no such value -- but it came back as ["
        .. tostring(undefined) .. "]")
-- A malformed expression is not the same answer, and make says so with its exit
-- status.  This is the assertion that used to be impossible to make, because
-- the reader had thrown the status away.
local malformed, malformed_refusal = makefile_api.expanded("$(")
assert(malformed == nil,
    "a malformed expression read back as " .. tostring(malformed)
        .. ".  Before the fix this returned \"\" -- the same value as an "
        .. "undefined variable -- so a guard asking which files a release ships "
        .. "could not tell \"none\" from \"I could not find out\".")
assert(type(malformed_refusal) == "string" and malformed_refusal:find("make exited", 1, true) ~= nil,
    "the refusal does not say make failed: " .. tostring(malformed_refusal))
-- A single quote in the expression is the case the shell used to eat.  The
-- expression below is valid make and valid sh; before the fix the quotes were
-- stripped on the way to make, which made make fail, and the discarded exit
-- status turned that failure into "".
local quoted = makefile_api.expanded("$(shell echo 'a  b')")
assert(type(quoted) == "string" and quoted:find("a", 1, true) ~= nil
        and quoted:find("b", 1, true) ~= nil,
    "an expression containing a single quote came back as ["
        .. tostring(quoted) .. "].  The quotes are being removed somewhere "
        .. "between this function and make, which is a different value rather "
        .. "than an error.")
assert(not pcall(makefile_api.expanded, ""),
    "expanded accepted an empty expression, which has no answer to report")
assert(not pcall(makefile_api.expanded, "one\ntwo"),
    "expanded accepted an expression spanning two lines; handing that to "
        .. "`make --eval` as one shell argument would either fail or silently "
        .. "re-wrap what it was given")

return true
