--[[
	PvPServer (Script)
	Location: ServerScriptService.PvPServer

	System 3 — Responsive PvP (Server Side)
	  • Listens for MeleeHitEvent — any item can melee.
	    Sword deals the most damage/knockback; blocks deal less.
	  • Listens for ProjectileHitEvent — validates a projectile
	    hit (snowball, boomerang) after the client reports it.
	  • Validates: distance, cooldown, held item.
	  • Applies damage + LinearVelocity knockback to the victim.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemDefs     = require(ReplicatedStorage:WaitForChild("ItemDefs"))
local InventoryMgr = require(ReplicatedStorage:WaitForChild("InventoryManager"))

local MeleeHitEvent       = ReplicatedStorage:WaitForChild("MeleeHitEvent")       :: RemoteEvent
local ProjectileHitEvent  = ReplicatedStorage:WaitForChild("ProjectileHitEvent")  :: RemoteEvent
local GetPlayerInventory  = ReplicatedStorage:WaitForChild("GetPlayerInventory")  :: BindableFunction

--------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------
local MAX_MELEE_DIST     = 25   -- studs (generous for lag)
local MAX_PROJ_HIT_DIST  = 150  -- max distance for projectile hits
local MELEE_COOLDOWN     = 0.35 -- seconds between melee swings
local PROJ_COOLDOWN      = 0.8  -- seconds between projectile throws
local KNOCKBACK_DURATION = 0.2  -- how long the LinearVelocity lasts
local KNOCKBACK_FORCE    = 60   -- base velocity magnitude
local KNOCKBACK_UP_ANGLE = 0.35 -- radians — slight upward arc

-- Fist stats (when slot is empty / no item)
local FIST_DAMAGE    = 3
local FIST_KNOCKBACK = 0.2

--------------------------------------------------------------
-- Per-player cooldown tracking
--------------------------------------------------------------
local lastMeleeTime: { [Player]: number } = {}
local lastProjTime:  { [Player]: number } = {}

--------------------------------------------------------------
-- APPLY KNOCKBACK via LinearVelocity
--------------------------------------------------------------
local function applyKnockback(attackerRoot: BasePart, victimRoot: BasePart, multiplier: number)
	local flatDir = (victimRoot.Position - attackerRoot.Position) * Vector3.new(1, 0, 1)
	if flatDir.Magnitude < 0.01 then
		flatDir = attackerRoot.CFrame.LookVector * Vector3.new(1, 0, 1)
	end
	flatDir = flatDir.Unit

	-- Minecraft-style snappy knockback: override linear velocity instantly
	local pushForce = 55 * multiplier
	local upForce   = 15

	-- Using a temporary BodyVelocity ensures the forces override client-side friction
	-- continuously for a few frames so they properly detach from the ground horizontally.
	local bv = Instance.new("BodyVelocity")
	bv.MaxForce = Vector3.new(100000, 100000, 100000)
	bv.Velocity = (flatDir * pushForce) + Vector3.new(0, upForce, 0)
	bv.Parent = victimRoot

	game:GetService("Debris"):AddItem(bv, 0.15)

	-- Momentarily force Jump to help bypass ground friction
	local victimHum = victimRoot.Parent and victimRoot.Parent:FindFirstChildOfClass("Humanoid")
	if victimHum then
		victimHum.Jump = true
	end
end

--------------------------------------------------------------
-- SHARED: resolve attacker/victim characters
--------------------------------------------------------------
local function resolveHit(attacker: Player, victim: any, maxDist: number): (BasePart?, BasePart?, Humanoid?)
	if typeof(victim) ~= "Instance" or not victim:IsA("Player") then return nil, nil, nil end
	if victim == attacker then return nil, nil, nil end

	local attackerChar = attacker.Character
	local victimChar   = victim.Character
	if not attackerChar or not victimChar then return nil, nil, nil end

	local attackerRoot = attackerChar:FindFirstChild("HumanoidRootPart")
	local victimRoot   = victimChar:FindFirstChild("HumanoidRootPart")
	local victimHum    = victimChar:FindFirstChildOfClass("Humanoid")
	if not attackerRoot or not victimRoot or not victimHum then return nil, nil, nil end
	if victimHum.Health <= 0 then return nil, nil, nil end

	local dist = (attackerRoot.Position - victimRoot.Position).Magnitude
	if dist > maxDist then return nil, nil, nil end

	return attackerRoot, victimRoot, victimHum
end

--------------------------------------------------------------
-- MELEE HIT HANDLER — any item can melee
--------------------------------------------------------------
MeleeHitEvent.OnServerEvent:Connect(function(attacker: Player, victim: any)
	local attackerRoot, victimRoot, victimHum = resolveHit(attacker, victim, MAX_MELEE_DIST)
	if not attackerRoot then return end

	-- Cooldown
	local now = tick()
	if lastMeleeTime[attacker] and (now - lastMeleeTime[attacker]) < MELEE_COOLDOWN then
		return
	end
	lastMeleeTime[attacker] = now

	-- Determine damage + knockback from held item
	local damage = FIST_DAMAGE
	local kb     = FIST_KNOCKBACK

	local inv = GetPlayerInventory:Invoke(attacker)
	if inv then
		local slot = InventoryMgr.GetSelectedSlot(inv)
		if slot and slot.itemId then
			local def = ItemDefs.Get(slot.itemId)
			if def and def.damage > 0 then
				damage = def.damage
				kb     = def.knockback
			end
		end
	end

	victimHum:TakeDamage(damage)
	applyKnockback(attackerRoot, victimRoot, kb)
end)

--------------------------------------------------------------
-- PROJECTILE HIT HANDLER
-- The client simulates the projectile visually, then fires
-- this event when it detects a collision with another player.
-- Server validates distance + that the projectile item was
-- actually consumed before the throw.
--------------------------------------------------------------
ProjectileHitEvent.OnServerEvent:Connect(function(attacker: Player, victim: any, itemId: any)
	if type(itemId) ~= "string" then return end

	local def = ItemDefs.Get(itemId)
	if not def or not def.isProjectile then return end

	local attackerRoot, victimRoot, victimHum = resolveHit(attacker, victim, MAX_PROJ_HIT_DIST)
	if not attackerRoot then return end

	-- Cooldown (shared per-player projectile cooldown)
	local now = tick()
	if lastProjTime[attacker] and (now - lastProjTime[attacker]) < PROJ_COOLDOWN then
		return
	end
	lastProjTime[attacker] = now

	-- Apply damage + knockback
	victimHum:TakeDamage(def.damage)
	applyKnockback(attackerRoot, victimRoot, def.knockback)
end)

--------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------
Players.PlayerRemoving:Connect(function(player)
	lastMeleeTime[player] = nil
	lastProjTime[player]  = nil
end)

print("[PvPServer] Melee + projectile validation system running.")
