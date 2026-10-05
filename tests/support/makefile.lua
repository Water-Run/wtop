-- Reading a target's recipe out of the Makefile.
--
-- Three test files needed this and each of them wrote it, which is the shape of
-- problem this project keeps removing: a second copy of a fact, which is a
-- second thing to forget to update.  It is here for the same reason the ELF
-- list moved into the baseline target -- one place, so the next edit cannot
-- find only one of the copies.
--
-- Two Lua details shape the implementation, and both have cost somebody a run
-- in this project.  Lua patterns have no non-capturing group, so a body cannot
-- be matched as `((?:...)+)`; and a bare `-` is the lazy repetition operator, so
-- a target name containing one -- `test-all`, `test-54` -- has to be escaped
-- before it becomes part of a pattern.  Reading lines avoids both, and it also
-- means re-indenting the Makefile cannot quietly make a helper stop finding
-- anything.

local M = {}

--- The recipe lines of `target`, tab-indented, as one string.
-- Returns an empty string when the target has no recipe.
function M.recipe_of(text, target)
  local escaped = target:gsub("(%W)", "%%%1")
  -- `promised` is the line-before-this-one-ended-in-a-backslash flag, and it
  -- decides what a tab-indented line *is*.  Without it a continued prerequisite
  -- list is read as a recipe: `make test-all` is an aggregate with no recipe at
  -- all, and this function used to hand back 118 bytes of its third and second
  -- prerequisite lines.  That mattered because a clause in
  -- `tests/unit/test_release_evidence.lua` asks whether `test-all` runs
  -- `test-release-notices` -- a question about prerequisites -- and was asking
  -- it of this function, so it passed on a misreading that happened to contain
  -- the right word.  Two defects cancelling into a correct-looking pass is worse
  -- than either one alone, and only one of them was a defect to the reader.
  --
  -- The flag is only carried across the prerequisite block.  A *recipe* line
  -- may also end in a backslash -- `test-sanitized`'s shell `for` loop does --
  -- and the line after that is another recipe line, not a continuation of
  -- anything, so re-arming the flag from a recipe line would truncate the
  -- recipe at its first shell continuation.
  local collecting, promised, body = false, false, {}
  for line in text:gmatch("[^\n]+") do
    if line:match("^" .. escaped .. ":") then
      collecting = true
      promised = line:match("\\$") ~= nil
    elseif collecting then
      if promised then
        promised = line:match("\\$") ~= nil
      elseif line:match("^\t") then
        body[#body + 1] = line
      else
        break
      end
    end
  end
  return table.concat(body, "\n")
end

--- A `NAME := value` assignment, with backslash continuations joined.
--
-- A variable split across lines is a variable the first version of a reader
-- silently truncates, which is how a file list came back one short of its real
-- length and the guard built on top of it compared against a lie.  The lines
-- are collected first and the decision to stop is made afterwards.
--
-- `?=` counts as an assignment here, and that is not a formality.  The
-- overridable defaults this Makefile uses to let a caller name an output --
-- `BASELINE_OUTPUT ?= dist/BASELINE.txt` -- are written `?=`, so a reader that
-- only knows `:=` reports "this Makefile declares no such variable" about a
-- variable that is right there on line 374.  That answer is the dangerous one:
-- it reads like an absence in the Makefile rather than an absence in the
-- reader, and a guard built on it decides the project has no default output
-- path and checks nothing.
-- It joins a continued value with a single space, which leaves *two* spaces
-- where the first line's trailing space met the join: `RELEASE_ELFS` reads
-- back with a double space before `$(CURDIR)`.  That is left alone on purpose.
-- Every caller either scans for non-space runs (`NATIVE_SOURCES` is matched with
-- `native/%S+%.c`) or compares whole values, and it fails loudly rather than
-- quietly -- a value carrying a stray space is a path that does not exist, so a
-- clause consuming one cannot find its file.  Tidying it would be a change to
-- a reader nobody measured a problem in, which is how the two clauses in
-- `test_release_evidence.lua` came to disagree with this file in the first
-- place.
--
-- It also does not see an `export NAME := value` line, because the pattern
-- anchors on the name at the start of the line.  The project's Makefile
-- declares no `export`, so growing the pattern for a shape nothing needs would
-- be a rule written for a case that has never occurred; the limit is pinned in
-- `tests/unit/test_makefile_readers.lua` instead, so it stays a fact about this
-- reader rather than something a future reader rediscovers.
function M.variable_of(text, name)
  local escaped = name:gsub("(%W)", "%%%1")
  -- Whether the *previous* consumed line ended in a backslash decides whether
  -- the next line belongs to the value, because that is how make reads it: the
  -- backslash-newline is replaced by a space, so the line after a trailing
  -- backslash is part of the value whether or not it has a backslash of its
  -- own.  NATIVE_SOURCES is the case that keeps this honest -- its last source
  -- has no backslash and is still part of the list.
  --
  -- Deciding after appending is the same off-by-one in the other direction, and
  -- it is worse than returning too little: a single-line variable picks up
  -- whatever line follows it, so `BASELINE_OUTPUT ?= dist/BASELINE.txt` came
  -- back as "dist/BASELINE.txt baseline: native toolchain" -- the target's own
  -- prerequisites, glued onto a file path.  NATIVE_SOURCES hid the first half
  -- of that bug, because the caller extracts `native/%.c` and the extra words
  -- do not match it, so the helper had been quietly wrong for a whole increment
  -- with a test built on top of it.
  local function value_of(line)
    local value = line:match("^%s*(.*)$") or ""
    return (value:gsub("\\%s*$", ""))
  end
  local collecting, promised, parts = false, false, {}
  for line in text:gmatch("[^\n]+") do
    if not collecting then
      if line:match("^" .. escaped .. "%s*[?:]?=") then
        collecting = true
        -- The value is everything after the first `=`, not after `:=`: a `?=`
        -- line has no `:=` in it, so the narrower pattern would assign "" to a
        -- variable that has a perfectly good default.
        parts[#parts + 1] = value_of(line:match("=(.*)$") or "")
        promised = line:match("\\$") ~= nil
      end
    elseif promised then
      parts[#parts + 1] = value_of(line)
      promised = line:match("\\$") ~= nil
    else
      collecting = false
    end
  end
  return table.concat(parts, " ")
end

--- The prerequisites make resolves for `target`, read out of make's database.
--
-- The two readers above read the text, and each of them was wrong here for a
-- while before it was taught about backslash continuations.  This one exists
-- because being taught is not enough when the thing being read is a *count*.
--
-- A prerequisite list has no length the reader can predict: it is as long as the
-- file happened to make it.  `tests/unit/test_release_evidence.lua` §6f -- the
-- clause that requires every gate in `make test-all` to run somewhere in CI --
-- read the list with `makefile:match("test%-all:[^\n]*\n?[^\n]*")`, a pattern
-- that reads exactly two lines, on a rule this project writes across three.
-- `test-luarocks`, `test-bundle-dir` and `test-bundle-file` were therefore never
-- compared against the workflow at all, and the comment above the clause
-- asserted that the Makefile "writes the aggregate across two lines" -- the same
-- false claim, in the place where it read like a checked fact.  Two more readers
-- in the same file guessed the line count the same way and happened to be right
-- (a target whose only continuation is a recipe line, and a release-evidence
-- list that fits on two), which is the part that made the shared helper worth
-- writing: not one wrong reader, but three correct-by-coincidence readers and a
-- fourth that was not.
--
-- Asking make is not a tidier way to read the list.  It is the only way to read
-- a list whose length is decided by the shape of the file rather than by a
-- pattern in the reader, and it is also the only reader that survives the file
-- being re-wrapped.
--
-- Two things in the answer are not prerequisites, and both are silent failures
-- if they are treated as gates:
--
--   * `.WAIT` is make 4.4's own serialisation marker, inserted between the
--     prerequisites of any target named in `.NOTPARALLEL` -- which `test-all`
--     is.  It is not a target this project defines, and a clause that reported
--     it as a gate CI never runs would be reporting make's implementation.
--   * A name make cannot build at all exits non-zero, which is what a typo gets
--     in place of an answer.  That is the same silence `variable_of` had for a
--     `?=` default: the caller is reasoning about coverage, and an empty list
--     reads as "this rule requires nothing" rather than "this reader found
--     nothing", so the refusal is returned rather than raised and the caller has
--     to say what it will do about it.
function M.prerequisites_of(target)
  assert(type(target) == "string" and target:match("^[%w][%w%-_%.]*$") ~= nil,
    "prerequisites_of was given " .. tostring(target) .. " instead of a plain "
        .. "target name; the name is handed to a shell, so it is refused rather "
        .. "than quoted")
  local pipe = assert(io.popen("make --no-print-directory -p -n " .. target
      .. " 2>/dev/null", "r"))
  local output = pipe:read("*a") or ""
  local _, _, code = pipe:close()
  -- The rule is matched at the start of a line rather than with a bare `:` so
  -- that `.PHONY: ... test-all ...` and `test-all-extra:` cannot both satisfy
  -- the search for `test-all:`.  `^` anchors to the start of the *string* in a
  -- Lua pattern, so the line has to be walked instead of searched.
  local escaped = target:gsub("(%W)", "%%%1")
  local seen, prerequisites = false, nil
  for line in output:gmatch("[^\n]+") do
    local rest = line:match("^" .. escaped .. ":(.*)$")
    if rest ~= nil then
      assert(not seen,
        "make's database describes " .. target .. " on more than one line, so "
            .. "this reader cannot tell which of them is the rule")
      seen, prerequisites = true, rest
    end
  end
  if code ~= 0 then
    return nil, "make could not build " .. target .. " (exit " .. tostring(code)
        .. "), so the list of its prerequisites is not knowable from here.  This "
        .. "is refused rather than reported as an empty list, because every "
        .. "caller of this function is asking what something *covers*."
  end
  assert(seen,
    "make exited cleanly on " .. target .. " and its database has no rule for "
        .. "it, so this reader is looking at something other than the rule")
  local words = {}
  for word in prerequisites:gmatch("%S+") do
    if word ~= ".WAIT" then words[#words + 1] = word end
  end
  return words
end

--- The value of a make expression, by asking make.
--
-- `variable_of` reads the text; this reads the meaning, and only make can read
-- it: expanding `RELEASE_ELFS` needs `$(CURDIR)`, which no file in the tree
-- declares, and `$(RELEASE_BUNDLE)` on top of that.  A guard that compared the
-- unexpanded text against a workflow's paths would conclude the release ships a
-- file called `$(RELEASE_BUNDLE)/wtop` -- a filename rather than a fact, and
-- one that fails in the direction of "this is not covered", which is the wrong
-- answer to a question about what a release contains.
--
-- The caller passes an expression rather than a name because the useful
-- question is usually about a form: `$(patsubst $(CURDIR)/%,%,$(...))` is how
-- a guard asks for the repo-relative path that a workflow would write.
--
-- Two ways this used to hand back a wrong answer, both measured, and neither
-- raised anything:
--
--   * The expression went into a single-quoted shell argument, so a `'` inside
--     it ended the quoting and the shell reported a syntax error.  The
--     diagnostic went to stderr, which this function discards, and the caller
--     got "" -- indistinguishable from a variable that is genuinely empty.
--     `$(shell echo it's)` is enough to do it, and no caller passes one today,
--     which is exactly why it survived: a bug that needs a shape nothing
--     currently has is a bug that is waiting, not a bug that is harmless.
--   * make's exit status was thrown away.  A malformed expression makes make
--     exit non-zero, and that too came back as "".  So one empty string stood
--     for four different situations -- an empty variable, an undefined one, an
--     unknown make function, and a syntax error -- and every caller of this
--     function is asking what a release contains, where "nothing" and "I could
--     not find out" have to be different answers.
--
-- The refusal is returned rather than raised, and it matches
-- `prerequisites_of` above: two readers that both shell out to make and both
-- fail differently would be a second contract to keep in agreement.
function M.expanded(expression)
  local target_of_probe = "wtop-test-expand-make-expression"
  assert(type(expression) == "string" and expression:find("%S") ~= nil,
    "expanded() needs a non-empty make expression, got "
        .. string.format("%q", tostring(expression)))
  assert(not expression:find("[\n\r]"),
    "a make expression spanning lines cannot be handed to `make --eval` as one "
        .. "shell argument, and quoting it into shape would change what make "
        .. "reads rather than preserving it.  It is refused rather than "
        .. "reformatted, because a reader that silently rewraps its input is a "
        .. "reader that can report a value nobody asked for.")
  -- `'\''` is the standard way to put a single quote inside a single-quoted
  -- shell word: close the quote, emit an escaped quote, reopen.  Without it
  -- the expression ends the argument and the rest of it is parsed as shell.
  -- The whole `--eval` argument is one shell word, rule included.
  local rule = target_of_probe .. ": ; @echo " .. expression
  local quoted = "'" .. rule:gsub("'", "'\\''") .. "'"
  local pipe = assert(io.popen("make --no-print-directory --eval=" .. quoted
      .. " " .. target_of_probe .. " 2>/dev/null", "r"))
  local output = pipe:read("*a")
  local _, _, code = pipe:close()
  if code ~= 0 then
    return nil, "make exited " .. tostring(code) .. " on the expression "
        .. expression .. ", so its value is not knowable from here.  This is "
        .. "refused rather than reported as an empty value: a caller that is "
        .. "asking which files a release ships cannot tell \"nothing\" from "
        .. "\"I could not find out\", and the empty string used to stand for "
        .. "both."
  end
  -- Last non-empty line, because make is free to print something of its own
  -- first and a guard that read the wrong line would be reasoning about a
  -- different value than the one it asked for.
  local last
  for line in (output or ""):gmatch("[^\n]+") do
    if line:find("%S") then last = line end
  end
  return (last or ""):gsub("%s+$", "")
end

return M
