-- The reason a degraded reading carries, and the one assertion that has to
-- hold for every collector that publishes one.
--
-- A result has exactly one reason slot, so the slot can only be filled with a
-- code whose sentence is true in *every* case that produced the published
-- quality.  That is the whole rule, and it is decidable: for each quality,
-- enumerate what can set it and ask whether one sentence covers them all.
-- Where it does, the reason is that sentence's code; where it does not, the
-- collector is not closable with one slot and needs a different fix.  disk is
-- the measured counterexample -- its `partial` can come from the caller's
-- `include` predicate raising, which is not a partial read at all.
--
-- What this helper exists to stop is the mistake the inventory clauses cannot
-- see.  A reason naming the *wrong* cause is a real code in the interface
-- inventory, translated in ten languages, spelled in the source: every
-- clause in `test_reason_localization.lua` passes.  Two mutations per
-- collector are aimed at exactly this -- the codes swapped, and the reason
-- published on a `fresh` reading -- and the swap is the dangerous one, because
-- a user whose cgroup counters were reset and a user with no rate yet need
-- different investigations and would be told the same wrong thing.
local M = {}

-- `expected` maps a quality to its reason, and uses `false` for a quality that
-- must carry none.  A quality absent from the table is an error rather than a
-- skip: a collector that grows a new degraded quality has to be given a reason
-- here, which is the moment to decide whether one sentence covers it.
--
-- `label` names the sample in the failure, because the first sample, the one
-- after a counter reset and the one with a missing file are all the same shape
-- as far as this check is concerned and nothing else says which was which.
function M.assert_reason(result, expected, label)
  local quality = result.quality
  local reason = expected[quality]
  assert(reason ~= nil or quality == "fresh",
    label .. ": quality " .. tostring(quality)
      .. " is not in the reason table, so no sentence has been decided for it.  "
      .. "Enumerate what can set that quality and add its code, or state here "
      .. "that no one sentence covers its cases and leave the collector alone.")
  if reason == false or quality == "fresh" then
    assert(result.reason == nil, label .. ": a fresh reading must name no cause, "
      .. "but it says " .. tostring(result.reason)
      .. ".  A reason written as an independent second guess rather than as the "
      .. "cause of what was published looks exactly like this.")
  else
    assert(result.reason == reason, label .. ": quality " .. tostring(quality)
      .. " should carry reason " .. tostring(reason) .. ", but the result says "
      .. tostring(result.reason))
  end
  return result.reason
end

return M
