-- Player settings and best score in the app's own save slots, as "key=value" lines.
-- Unknown keys are ignored and out-of-range values fall back to the default, so an older
-- or newer save never stops the game from starting.
local M = {}

M.VERSION = 1

-- name = {default, kind, a, b, step}
M.SPEC = {
  mode = {"fused", "enum", {"fused", "gyro", "accel", "touch"}},
  axes = {"two", "enum", {"two", "x"}},
  max = {20, "num", 8, 40, 2}, -- degrees of tilt for full speed
  dead = {3, "num", 0, 10, 1}, -- degrees ignored around neutral
  curve = {1.4, "num", 1.0, 2.6, 0.2},
  smooth = {0.06, "num", 0, 0.24, 0.03}, -- seconds
  invert_x = {false, "bool"},
  invert_y = {false, "bool"},
  sound = {true, "bool"},
  diag = {false, "bool"},
  rec = {false, "bool"}, -- log every IMU sample (simulator trace format)
  lang = {"ja", "enum", {"ja", "en"}},
}
M.ORDER = {"mode", "axes", "max", "dead", "curve", "smooth", "invert_x", "invert_y",
           "sound", "diag", "rec", "lang"}

function M.defaults()
  local s = {}
  for k, spec in pairs(M.SPEC) do s[k] = spec[1] end
  return s
end

local function index_of(list, v)
  for i, x in ipairs(list) do if x == v then return i end end
end

local function coerce(k, text)
  local spec = M.SPEC[k]
  if not spec then return nil end
  if spec[2] == "enum" then
    return index_of(spec[3], text) and text or nil
  elseif spec[2] == "bool" then
    if text == "1" or text == "true" then return true end
    if text == "0" or text == "false" then return false end
  else
    local v = tonumber(text)
    if v and v == v and v >= spec[3] and v <= spec[4] then return v end
  end
  return nil
end

function M.parse(text)
  local s = M.defaults()
  if type(text) ~= "string" then return s end
  for line in text:gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k and k ~= "v" then
      local val = coerce(k, v)
      if val ~= nil then s[k] = val end
    end
  end
  return s
end

function M.serialize(s)
  local out = {"v=" .. M.VERSION}
  for _, k in ipairs(M.ORDER) do
    local v = s[k]
    if type(v) == "boolean" then v = v and "1" or "0" end
    out[#out + 1] = k .. "=" .. tostring(v)
  end
  return table.concat(out, "\n") .. "\n"
end

-- Next value for a setting (dir = 1 or -1), wrapping enums and booleans, clamping numbers.
function M.step(s, k, dir)
  local spec = M.SPEC[k]
  local v = s[k]
  if spec[2] == "enum" then
    local list = spec[3]
    local i = (index_of(list, v) or 1) - 1
    s[k] = list[(i + dir) % #list + 1]
  elseif spec[2] == "bool" then
    s[k] = not v
  else
    local n = v + dir * spec[5]
    n = math.floor(n / spec[5] + 0.5) * spec[5] -- keep on the grid despite float steps
    s[k] = math.max(spec[3], math.min(spec[4], n))
  end
end

function M.parse_best(text)
  if type(text) ~= "string" then return 0 end
  local v = tonumber(text:match("best=(%d+)"))
  return v or 0
end

function M.serialize_best(best) return "v=1\nbest=" .. math.floor(best) .. "\n" end

return M
