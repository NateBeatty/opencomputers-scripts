-- fueltest.lua — Show which inventory stacks build.lua and pbuild.lua burn.
--
-- Usage: fueltest            list every stack and whether it counts as fuel
--        fueltest --insert   also put one of each fuel type into the generator
--                            and take it back out, to prove it really burns
--
-- Fuel is matched by name only against fuelItems, read the same way the
-- builders read it: the defaults, then /etc/builder.cfg, then /etc/pbuild.cfg.

local component = require("component")
local robot = require("robot")

local insertTest = ({...})[1] == "--insert"

local fuelItems = { ["minecraft:coal"] = 1280 }
for _, path in ipairs({ "/etc/builder.cfg", "/etc/pbuild.cfg" }) do
  local f = loadfile(path)
  if f then
    local ok, cfg = pcall(f)
    if ok and type(cfg) == "table" and type(cfg.fuelItems) == "table" then
      fuelItems = cfg.fuelItems
      print("fuelItems from " .. path)
    end
  end
end

print("Fuel names:")
for name, energy in pairs(fuelItems) do
  print(string.format("  %-28s %d energy", name, energy))
end
print("")

if not component.isAvailable("inventory_controller") then
  print("[FAIL] No Inventory Controller: cannot read item names.")
  return
end
local ic = component.inventory_controller
local gen = component.isAvailable("generator") and component.generator or nil

local found, tested = 0, {}
for slot = 1, robot.inventorySize() do
  local stack = ic.getStackInInternalSlot(slot)
  if stack then
    local key = stack.name .. "@" .. tostring(stack.damage or 0)
    local isFuel = fuelItems[stack.name] ~= nil
    print(string.format("%2d  %-4s %-30s x%-3d %s", slot, isFuel and "FUEL" or "",
      key, stack.size, stack.label or ""))

    if isFuel then
      found = found + 1
      if insertTest and gen and not tested[key] then
        tested[key] = true
        if (gen.count() or 0) > 0 then
          print("      generator already has fuel queued; skipped the burn test")
        else
          robot.select(slot)
          local ok, reason = gen.insert(1)
          if ok then
            print("      generator accepted it")
            gen.remove()  -- back into the inventory
          else
            print("      generator REFUSED it: " .. tostring(reason))
          end
        end
      end
    end
  end
end

print("")
print(found .. " fuel stack(s) found.")
if insertTest and not gen then print("[WARN] No Generator Upgrade, so nothing was inserted.") end
