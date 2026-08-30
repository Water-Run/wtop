-- Deliberately poison loader state. The next alphabetical fixture verifies
-- that tests/run.lua restores its process baseline between independent files.
package.path = "/tmp/wtop-runner-poison/?.lua"
package.cpath = "/tmp/wtop-runner-poison/?.so"
package.loaded["wtop.runner_isolation_probe"] = { poisoned = true }
package.preload["wtop.runner_isolation_probe"] = function()
    return { poisoned = true }
end
package.loaded.math = { poisoned = true }

return true
