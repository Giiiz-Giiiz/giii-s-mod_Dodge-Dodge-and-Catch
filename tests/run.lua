-- Host unit tests: lua5.4 tests/run.lua (from the repository root).
-- The game modules are pure Lua, so they run here exactly as on the device.
package.path = "app/?.lua;tests/?.lua;" .. package.path

local failed, passed = 0, 0
local current

T = {}

function T.eq(a, b, msg)
  if a ~= b then error(("%s: expected %s, got %s"):format(msg or "eq", tostring(b), tostring(a)), 2) end
end

function T.near(a, b, tol, msg)
  if math.abs(a - b) > tol then
    error(("%s: expected %.4f +- %.4f, got %.4f"):format(msg or "near", b, tol, a), 2)
  end
end

function T.ok(v, msg)
  if not v then error(msg or "expected true", 2) end
end

function T.test(name, fn)
  current = name
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL %s\n  %s"):format(name, err))
  end
end

for _, file in ipairs({"test_tilt", "test_world", "test_settings"}) do
  require(file)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
