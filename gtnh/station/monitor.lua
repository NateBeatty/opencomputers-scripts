-- monitor.lua — Watch a building robot from a base computer, and control it.
-- Usage: monitor [port]
--
-- Needs a network card (wireless, to reach the robot). The robot broadcasts a
-- serialized status table every few seconds; this prints it and can send
-- pause / resume / stop back.
--
-- Keys: p pause   r resume   s stop   q quit

local component = require("component")
local computer = require("computer")
local event = require("event")
local serialization = require("serialization")
local keyboard = require("keyboard")
local term = require("term")

local args = {...}
local port = tonumber(args[1]) or 65656

if not component.isAvailable("modem") then
  print("[ERROR] No network card in this computer.")
  return
end
local modem = component.getPrimary("modem")
modem.open(port)

local status = nil
local robotAddress = nil
local lastUpdate = nil

local function draw()
  term.clear()
  print("=== Builder monitor (port " .. port .. ") ===")
  print("")
  if not status then
    print("Waiting for a broadcast from the robot...")
  else
    local age = lastUpdate and math.floor(computer.uptime() - lastUpdate) or 0
    print(string.format("Plan:     %s (version %s)", tostring(status.plan), tostring(status.version)))
    print(string.format("Phase:    %s%s", tostring(status.phase),
      status.note and (" (" .. tostring(status.note) .. ")") or ""))
    if status.layers and status.layer then
      print(string.format("Layer:    %d of %d", status.layer, status.layers - 1))
    end
    if status.cells and status.cells > 0 then
      print(string.format("Cell:     %d of %d (%.1f%%)",
        status.cell or 0, status.cells, (status.cell or 0) / status.cells * 100))
    end
    print(string.format("Energy:   %s%%", tostring(status.energy)))
    print(string.format("Fuel:     %s", tostring(status.fuel)))
    print(string.format("Placed:   %s   skipped: %s   deferred: %s",
      tostring(status.placed), tostring(status.skipped), tostring(status.deferred)))
    print(string.format("Updated:  %ds ago", age))
    if robotAddress then
      print(string.format("Robot:    %s", robotAddress:sub(1, 8)))
    end
  end
  print("")
  print("p pause   r resume   s stop   q quit")

  if status and status.phase == "waiting-materials" then
    print("")
    print("!! The robot is waiting for materials: " .. tostring(status.note))
  elseif status and status.phase == "waiting-fuel" then
    print("")
    print("!! The robot is out of fuel. Put coal in the ender chest.")
  elseif status and status.phase == "error" then
    print("")
    print("!! Error: " .. tostring(status.note))
  end
end

local function send(command)
  modem.broadcast(port, command)
  print("[CMD] sent: " .. command)
end

draw()

while true do
  -- The fields differ per event:
  --   modem_message: name, localAddress, remoteAddress, port, distance, message
  --   key_down:      name, keyboardAddress, char, keycode, playerName
  local name, a2, a3, a4, _, a6 = event.pull(2)

  if name == "modem_message" and a4 == port and type(a6) == "string" then
    local ok, decoded = pcall(serialization.unserialize, a6)
    if ok and type(decoded) == "table" and decoded.phase then
      status = decoded
      robotAddress = a3
      lastUpdate = computer.uptime()
      draw()
    end

  elseif name == "key_down" then
    local char = type(a3) == "number" and a3 > 0 and string.char(a3) or ""
    if char == "p" then send("pause")
    elseif char == "r" then send("resume")
    elseif char == "s" then send("stop")
    elseif char == "q" then
      modem.close(port)
      term.clear()
      return
    end

  elseif name == nil then
    -- Timed out: refresh the "updated Ns ago" line so a silent robot is obvious.
    if status then draw() end
  end
end
