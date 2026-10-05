-- The quality and status vocabularies, in one place.
--
-- Measured, this list existed three times: here it would be the fourth.  The
-- copies were in `model/snapshot.lua`, `core/scheduler.lua` and
-- `inspectors/model.lua`, and they had already diverged -- the snapshot's had
-- eleven entries, the other two had ten, and the missing one was `truncated` --
-- and, worse, they disagreed about what to do with a label none of them
-- publishes.  The inspector model refused and named it.  The scheduler rewrote
-- it to `fresh` when the status was `ok`, silently, which is the permissive
-- direction: a collector that misspells `partial` had its degradation published
-- as fresh data, with the numbers installed under it.  The snapshot did the same
-- until an increment ago and now refuses instead.  So the project already knew
-- the right shape and had three copies of it, one of which was right.
--
-- That is the shape of the defect this project has documented thirty-three
-- times: a second copy of a fact is not only a thing that drifts, it is a thing
-- that can be right in one place and wrong in the other while everything stays
-- green.  Nothing here decides *policy*; the list is a promise about what the UI,
-- the JSON snapshot and an agent will read, and there is now one place it is
-- written down.
--
-- The subprocess executor's status list in `core/runner.lua` is deliberately not
-- here.  It is a different vocabulary -- six entries, including `timeout` and
-- `cancelled`, which a resource reading can never be -- and merging it would be
-- the same mistake in the other direction.
local M = {}

M.VALID_STATUS = { ok = true, unavailable = true, denied = true, error = true }

-- `missing` and `held` were added here in increment 83, and the reason is the
-- blind spot the two checks above could not see.  Every *scan* in this project
-- reads literals: the reason-code inventories of increments 81 and 82 read
-- `reason =` sites and a `Capability` constructor's first argument, and
-- measured, all 71 quality sites that assign a string literal assign a
-- published word -- so the literal scans report this list as complete.  The one
-- check that is not a scan, the scheduler's, asks a different question and so
-- cannot answer this one: it validates `result.quality`, the aggregate a
-- collector returns, and a mount row or a GPU engine's rate is published
-- beside it rather than in it.  Two values reached the I/O page's Quality
-- column anyway, because neither arrives as a literal: a mount's quality is
-- whatever the statvfs provider's failure classifier returned, and a GPU
-- engine's rate quality is the result of a comparison against the previous
-- sample.  Instrumenting the renderer across all 105 test files recorded seven
-- distinct values reaching it, and `held` -- a real state meaning "the counter
-- went backwards, so the last high-water mark is being held" -- had no display
-- label in any of the ten catalogues and rendered as the English word in all
-- ten.  So the list is a promise about what a *row* may say as well as what a
-- *result* may say, and until now only the result half was policed.

M.VALID_QUALITY = {
  fresh = true, stale = true, gap = true, estimated = true, unavailable = true,
  denied = true, error = true, partial = true, reset = true, measured = true,
  truncated = true, missing = true, held = true,
}

-- How badly a published quality is doing, for anything that colours it.  The
-- token names belong to the theme layer, so this ranks and the caller spells;
-- what must not be duplicated is the ranking itself, and increment 83 found
-- the copy that had drifted.  The I/O page's quality column marked `partial`
-- and `stale` as warnings and left everything else muted, so a mount whose
-- statvfs was *denied* or *errored* was painted exactly like a healthy one --
-- the two states the collector is most likely to produce and the user most
-- needs to see, ranked below the two it did paint.  The Insights collector
-- table already ranked `denied` and `error` as critical, so the project had the
-- right ranking written down in one place and the wrong one in another.
--
-- The two entries that are not obvious were measured rather than guessed, and
-- the first draft of this table got both wrong.
--
-- `unavailable` is muted, not critical.  A mount row reaches it mostly by the
-- product declining to read it -- a network filesystem that might block, or a
-- budget the collector imposed on itself -- and `mount.partial_reason` already
-- says which.  The Insights table paints an unavailable collector muted for the
-- same reason.  A row that turned red every time wtop was careful would be a
-- false alarm, and a false alarm is a colour the operator learns to ignore.
--
-- `missing` is a warning, not a critical.  The mount point is gone, so the
-- reading is not what it claims to be -- but nothing failed that could have
-- succeeded, which is the whole difference between this and `denied`.  It was
-- first written as critical, which ranked a vanished directory above a
-- permission failure the user can go and fix.
--
-- `nil` means "nothing to say": the good answers (`fresh`, `measured`), the
-- informational ones (`estimated`, `reset`) and the deliberate ones
-- (`unavailable`) are not neutral by accident, they are the absence of a
-- complaint.  The kernel's own instruction to retain a prior high-water mark
-- until a DRM counter catches up is what `held` names, so it is a warning
-- about the number rather than an error -- but it is not a number that moved,
-- and the overlay prints it next to the one that did not.
M.SEVERITY = {
  denied = "critical", error = "critical",
  partial = "warn", stale = "warn", gap = "warn", truncated = "warn",
  missing = "warn", held = "warn",
}

return M
