-- Procedural sprites (original art, generated at start; no asset files).
-- Every generator returns w, h, pixels as RGB565 little-endian, KEY = transparent.
local M = {}

M.KEY = 0xF81F

local floor, sqrt, atan, cos, max, min = math.floor, math.sqrt, math.atan, math.cos, math.max, math.min
local pack, concat = string.pack, table.concat

local function rgb(r, g, b)
  r, g, b = max(0, min(255, floor(r))), max(0, min(255, floor(g))), max(0, min(255, floor(b)))
  return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
end
M.rgb = rgb

local function image(w, h, fn)
  local rows, row = {}, {}
  local fmt = "<" .. ("I2"):rep(w)
  for y = 0, h - 1 do
    for x = 0, w - 1 do row[x + 1] = fn(x, y) or M.KEY end
    rows[y + 1] = pack(fmt, table.unpack(row, 1, w))
  end
  return w, h, concat(rows)
end

local function hash(x, y, s)
  local v = (x * 374761393 + y * 668265263 + floor(s * 1000) * 2246822519) & 0xFFFFFFFF
  v = ((v ~ (v >> 13)) * 1274126177) & 0xFFFFFFFF
  return (v ~ (v >> 16)) / 4294967296
end

function M.ship()
  local w, h = 19, 22
  return image(w, h, function(x, y)
    local cx = (w - 1) / 2
    local dx = math.abs(x - cx)
    -- flame
    if y >= 18 then
      if dx <= (21 - y) * 0.8 and dx <= 2.5 then return y == 18 and rgb(255, 230, 120) or rgb(255, 120, 40) end
      return nil
    end
    -- hull: narrow nose widening to swept wings
    local half = y < 12 and (y * 0.32 + 0.6) or (3.4 + (y - 12) * 1.05)
    if dx > half then return nil end
    if y >= 12 and dx > 3.2 and y > 16 then return nil end
    local edge = half - dx < 1.1
    if y >= 4 and y <= 9 and dx <= 1.4 then return rgb(120, 230, 255) end -- cockpit
    if edge then return rgb(70, 90, 140) end
    local shade = 200 - y * 4 + (dx < 1 and 30 or 0)
    if y >= 12 and dx > 3.2 then return rgb(220, 70, 80) end -- wing tips
    return rgb(shade, shade + 10, shade + 30)
  end)
end

function M.meteor(r, seed)
  local d = 2 * r + 2
  local c = (d - 1) / 2
  return image(d, d, function(x, y)
    local dx, dy = x - c, y - c
    local a = atan(dy, dx)
    local bump = 1 + 0.12 * cos(a * 3 + seed) + 0.08 * cos(a * 5 + seed * 2)
    local dist = sqrt(dx * dx + dy * dy) / (r * bump)
    if dist > 1 then return nil end
    local light = 0.55 + 0.45 * (-(dx + dy) / (r * 1.6)) -- lit from the upper left
    local n = hash(x, y, seed)
    local crater = hash(x // 3, y // 3, seed + 7) > 0.82
    local k = light * (crater and 0.7 or 1) * (0.9 + 0.2 * n)
    if dist > 0.86 then k = k * 0.75 end
    return rgb(150 * k + 20, 120 * k + 15, 100 * k + 10)
  end)
end

function M.barrier()
  local d = 16
  local c = (d - 1) / 2
  return image(d, d, function(x, y)
    local dist = sqrt((x - c) ^ 2 + (y - c) ^ 2)
    if dist > 7.6 then return nil end
    if dist > 6 then return rgb(120, 240, 255) end
    if dist > 4.6 then return rgb(40, 150, 220) end
    -- inner "shield" glyph
    local sx, sy = x - c, y - c
    if math.abs(sx) <= 2.6 - math.max(0, sy) * 0.6 and sy >= -3 and sy <= 3.5 then
      return rgb(230, 250, 255)
    end
    return rgb(20, 70, 120)
  end)
end

function M.star()
  local d = 16
  local c = (d - 1) / 2
  return image(d, d, function(x, y)
    local dx, dy = x - c, y - c
    local dist = sqrt(dx * dx + dy * dy)
    local a = atan(dx, -dy)
    local lim = 4 + 3.6 * (0.5 + 0.5 * cos(a * 5))
    if dist > lim then return nil end
    if dist > lim - 1.2 then return rgb(255, 170, 40) end
    return rgb(255, 235 - dist * 8, 90)
  end)
end

return M
