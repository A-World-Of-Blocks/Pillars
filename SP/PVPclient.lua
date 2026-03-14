--[[
	PvPClient (LocalScript)
	Location: StarterPlayer.StarterPlayerScripts.PvPClient

	System 3 — Responsive PvP (PC / Mobile / Console)
	  • Any item can melee (sword is strongest, blocks do light
	    punch damage, empty hand = fist).
	  • Projectile items (snowball, boomerang) are thrown on
	    attack — consumed from inventory, visual projectile
	    spawned locally, hit reported to server.
	  • Camera punch recoil on every attack.
	  • Input: PC left-click, Console RT, Mobile attack button.
]]

local Players               = game:GetService("Players")
local RunService            = game:GetService("RunService")
local UserInputService      = game:GetService("UserInputService")
local ContextActionService  = game:GetService("ContextActionService")
local ReplicatedStorage     = game:GetService("ReplicatedStorage")
local GuiService            = game:GetService("GuiService")

local ItemDefs         = require(ReplicatedStorage:WaitForChild("ItemDefs"))
local InventoryMgr     = require(ReplicatedStorage:WaitForChild("InventoryManager"))

local MeleeHitEvent       = ReplicatedStorage:WaitForChild("MeleeHitEvent")       :: RemoteEvent
local ProjectileHitEvent  = ReplicatedStorage:WaitForChild("ProjectileHitEvent")  :: RemoteEvent
local InventoryChanged    = ReplicatedStorage:WaitForChild("InventoryChanged")    :: RemoteEvent
local RequestInventory    = ReplicatedStorage:WaitForChild("RequestInventory")    :: RemoteFunction
local ConsumeItemRemote   = ReplicatedStorage:WaitForChild("ConsumeItemRemote")   :: RemoteFunction

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

--------------------------------------------------------------
-- SOUNDS
--------------------------------------------------------------
local hitSound = Instance.new("Sound")
hitSound.SoundId = "rbxassetid://5633695679" -- Punch / thud sound
hitSound.Volume = 0.8
hitSound.Parent = workspace

local function playHitSound()
	hitSound:Play()
end

--------------------------------------------------------------
-- CONSTANTS
--------------------------------------------------------------
local MELEE_COOLDOWN   = 0.35  -- seconds between melee swings
local PROJ_COOLDOWN    = 0.8   -- seconds between projectile throws
local HIT_RANGE        = 5     -- melee studs in front of camera
local HIT_BOX_SIZE     = Vector3.new(4, 4, HIT_RANGE)

--------------------------------------------------------------
-- LOCAL INVENTORY MIRROR
--------------------------------------------------------------
local localInventory = InventoryMgr.New()

local function onInventoryUpdate(data)
	local inv = InventoryMgr.Deserialize(data)
	if inv then
		localInventory = inv
	end
end

InventoryChanged.OnClientEvent:Connect(onInventoryUpdate)

-- Also listen to optimistic local updates from BuildingClient
task.spawn(function()
	local localSignal = player:WaitForChild("LocalInventoryChanged", 5)
	if localSignal then
		localSignal.Event:Connect(onInventoryUpdate)
	end
end)

task.spawn(function()
	local data = RequestInventory:InvokeServer()
	if data then onInventoryUpdate(data) end
end)

--------------------------------------------------------------
-- STATE
--------------------------------------------------------------
local lastMeleeTime = 0
local lastProjTime  = 0

--------------------------------------------------------------
-- HELPER: get selected item def (or nil for empty hand)
--------------------------------------------------------------
local function getSelectedDef()
	local slot = InventoryMgr.GetSelectedSlot(localInventory)
	if not slot or not slot.itemId then return nil end
	return ItemDefs.Get(slot.itemId)
end

--------------------------------------------------------------
-- MELEE HITBOX SCAN
--------------------------------------------------------------
local function scanHitbox(): Player?
	local char = player.Character
	if not char then return nil end

	local camCF = camera.CFrame
	local boxCF = camCF * CFrame.new(0, 0, -HIT_RANGE / 2)

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include

	local includeParts = {}
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer ~= player then
			local otherChar = otherPlayer.Character
			if otherChar then
				local hrp = otherChar:FindFirstChild("HumanoidRootPart")
				if hrp then
					table.insert(includeParts, hrp)
				end
			end
		end
	end

	if #includeParts == 0 then return nil end
	params.FilterDescendantsInstances = includeParts

	local hits = workspace:GetPartBoundsInBox(boxCF, HIT_BOX_SIZE, params)

	for _, part in hits do
		if part.Name == "HumanoidRootPart" then
			local model = part.Parent
			if model then
				local hitPlayer = Players:GetPlayerFromCharacter(model)
				if hitPlayer and hitPlayer ~= player then
					return hitPlayer
				end
			end
		end
	end
	return nil
end

--------------------------------------------------------------
-- HIGHLIGHT FOR TARGETED PLAYER
--------------------------------------------------------------
local targetHighlight = Instance.new("Highlight")
targetHighlight.FillTransparency = 1
targetHighlight.OutlineColor = Color3.fromRGB(255, 255, 255)
targetHighlight.OutlineTransparency = 0.2
targetHighlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
targetHighlight.Parent = workspace
targetHighlight.Adornee = nil

--------------------------------------------------------------
-- HEALTH BARS FOR OTHER PLAYERS
--------------------------------------------------------------
local function createHealthBar(char: Model)
	local hitPlayer = Players:GetPlayerFromCharacter(char)
	if hitPlayer == player then return end

	local head = char:WaitForChild("Head", 5)
	local hum = char:WaitForChild("Humanoid", 5) :: Humanoid
	if not head or not hum then return end

	local bg = Instance.new("BillboardGui")
	bg.Name = "HealthBarBG"
	bg.Size = UDim2.fromOffset(80, 10)
	bg.StudsOffset = Vector3.new(0, 2.5, 0)
	bg.AlwaysOnTop = true

	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	frame.BorderSizePixel = 0
	frame.Parent = bg

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(hum.Health / hum.MaxHealth, 1)
	fill.BackgroundColor3 = Color3.fromRGB(60, 220, 80)
	fill.BorderSizePixel = 0
	fill.Parent = frame

	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(0, 4)
	uiCorner.Parent = frame

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	-- Border
	local uiStroke = Instance.new("UIStroke")
	uiStroke.Color = Color3.new(0, 0, 0)
	uiStroke.Thickness = 1.5
	uiStroke.Parent = frame

	bg.Parent = head

	hum.HealthChanged:Connect(function(health)
		local frac = math.clamp(health / hum.MaxHealth, 0, 1)
		fill.Size = UDim2.fromScale(frac, 1)
		if frac < 0.3 then
			fill.BackgroundColor3 = Color3.fromRGB(220, 60, 60)
		elseif frac < 0.6 then
			fill.BackgroundColor3 = Color3.fromRGB(220, 180, 60)
		else
			fill.BackgroundColor3 = Color3.fromRGB(60, 220, 80)
		end
	end)
end

for _, p in Players:GetPlayers() do
	if p ~= player and p.Character then
		task.spawn(createHealthBar, p.Character)
	end
end
Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function(c)
		task.spawn(createHealthBar, c)
	end)
end)
for _, p in Players:GetPlayers() do
	if p ~= player then
		p.CharacterAdded:Connect(function(c)
			task.spawn(createHealthBar, c)
		end)
	end
end

--------------------------------------------------------------
-- CAMERA PUNCH — small recoil feedback
--------------------------------------------------------------
local punchOffset = 0
local PUNCH_STRENGTH = 3
local PUNCH_DECAY    = 12

RunService.RenderStepped:Connect(function(dt)
	-- Highlight the player in the crosshair
	local victim = scanHitbox()
	if victim and victim.Character then
		targetHighlight.Adornee = victim.Character
	else
		targetHighlight.Adornee = nil
	end

	if math.abs(punchOffset) > 0.01 then
		punchOffset = punchOffset * math.max(0, 1 - PUNCH_DECAY * dt)
		local char = player.Character
		if char then
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.CameraOffset = Vector3.new(0, punchOffset * 0.05, 0)
			end
		end
	end
end)

--------------------------------------------------------------
-- PROJECTILE VISUAL SPAWNER
--------------------------------------------------------------
local function spawnProjectile(def: any)
	local char = player.Character
	if not char then return end
	local head = char:FindFirstChild("Head")
	if not head then return end

	-- Starting position: slightly in front of the camera
	local origin = camera.CFrame.Position + camera.CFrame.LookVector * 2
	local direction = camera.CFrame.LookVector

	-- Create projectile part
	local proj = Instance.new("Part")
	proj.Name = "Projectile_" .. def.id
	proj.Shape = Enum.PartType.Ball
	proj.Size = Vector3.new(1, 1, 1)
	proj.Color = def.color
	proj.Material = def.material
	proj.Anchored = false
	proj.CanCollide = false
	proj.CanTouch = true
	proj.CanQuery = false
	proj.Massless = true
	proj.CastShadow = true
	proj.Position = origin
	proj.Parent = workspace

	-- Trail for visual flair
	local att0 = Instance.new("Attachment"); att0.Parent = proj
	local att1 = Instance.new("Attachment"); att1.Position = Vector3.new(0, 0, 0.3); att1.Parent = proj
	local trail = Instance.new("Trail")
	trail.Attachment0 = att0
	trail.Attachment1 = att1
	trail.Lifetime = 0.3
	trail.MinLength = 0.1
	trail.Color = ColorSequence.new(def.color)
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	trail.Parent = proj

	-- Physics: launch forward
	local bv = Instance.new("BodyVelocity")
	bv.Velocity = direction * (def.projectileSpeed or 100)
	bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
	bv.Parent = proj

	-- Detect hits
	local hasHit = false
	local startPos = origin
	local maxRange = def.projectileRange or 80

	-- Touched handler for hit detection
	proj.Touched:Connect(function(hit)
		if hasHit then return end
		-- Ignore own character
		local model = hit:FindFirstAncestorOfClass("Model")
		if model == char then return end

		-- Check if it's another player
		if model then
			local hitPlayer = Players:GetPlayerFromCharacter(model)
			if hitPlayer and hitPlayer ~= player then
				hasHit = true
				playHitSound()
				ProjectileHitEvent:FireServer(hitPlayer, def.id)
				proj:Destroy()
				return
			end
		end		-- Hit world geometry — destroy
		if hit.Anchored then
			hasHit = true
			proj:Destroy()
		end
	end)

	-- Boomerang return arc
	if def.returns then
		task.spawn(function()
			task.wait(0.4) -- travel outward for a bit
			if proj.Parent and not hasHit then
				-- Reverse direction to come back
				local returnDir = (head.Position - proj.Position)
				if returnDir.Magnitude > 1 then
					bv.Velocity = returnDir.Unit * (def.projectileSpeed or 90)
				end
			end
			task.wait(1.0)
			if proj.Parent then
				proj:Destroy()
			end
		end)
	end

	-- Lifetime / range cleanup
	task.spawn(function()
		while proj.Parent and not hasHit do
			task.wait(0.05)
			if (proj.Position - startPos).Magnitude > maxRange then
				break
			end
		end
		task.wait(0.1)
		if proj.Parent then
			proj:Destroy()
		end
	end)
end

--------------------------------------------------------------
-- PLATFORM DETECTION
--------------------------------------------------------------
local isMobile  = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local isConsole = GuiService:IsTenFootInterface()

--------------------------------------------------------------
-- ATTACK INPUT — fires on any platform
-- Melee with any item; projectile throw if holding one
--------------------------------------------------------------
local function handleAttack(_actionName, inputState, _inputObj)
	if inputState ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end

	local def = getSelectedDef()

	-- If holding a projectile → throw it (consumes 1)
	if def and def.isProjectile then
		local now = tick()
		if (now - lastProjTime) < PROJ_COOLDOWN then return Enum.ContextActionResult.Sink end

		local slotCheck = InventoryMgr.GetSelectedSlot(localInventory)
		if not slotCheck or not slotCheck.itemId then return Enum.ContextActionResult.Pass end

		local consumed = ConsumeItemRemote:InvokeServer(def.id)
		if not consumed then return Enum.ContextActionResult.Pass end

		lastProjTime = now
		InventoryMgr.ConsumeSelected(localInventory)
		local localSignal = player:FindFirstChild("LocalInventoryChanged")
		if localSignal then
			localSignal:Fire(InventoryMgr.Serialize(localInventory))
		end

		punchOffset = PUNCH_STRENGTH
		spawnProjectile(def)

		local swingSignal = ReplicatedStorage:FindFirstChild("SwordSwingSignal")
		if swingSignal then swingSignal:Fire() end

		return Enum.ContextActionResult.Sink
	end

	-- Helper: handle melee logic if victim is hit
	local function doMeleeHit(v: Player)
		playHitSound()
		MeleeHitEvent:FireServer(v)
	end

	-- Holding a block: only attack if a player is in the melee hitbox.
	-- If no player is in range, pass through so the building system can place.
	local slot = InventoryMgr.GetSelectedSlot(localInventory)
	local heldDef = slot and slot.itemId and ItemDefs.Get(slot.itemId)
	if heldDef and heldDef.isBlock then
		local victim = scanHitbox()
		if not victim then
			return Enum.ContextActionResult.Pass  -- let building handle it
		end
		-- Player is in range — punch with fist (server uses FIST_DAMAGE when no weapon)
		local now = tick()
		if (now - lastMeleeTime) < MELEE_COOLDOWN then return Enum.ContextActionResult.Sink end
		lastMeleeTime = now
		punchOffset = PUNCH_STRENGTH
		local swingSignal = ReplicatedStorage:FindFirstChild("SwordSwingSignal")
		if swingSignal then swingSignal:Fire() end
		doMeleeHit(victim)
		return Enum.ContextActionResult.Sink
	end

	-- Melee with current item (or empty fist)
	local now = tick()
	if (now - lastMeleeTime) < MELEE_COOLDOWN then return Enum.ContextActionResult.Pass end
	lastMeleeTime = now

	punchOffset = PUNCH_STRENGTH

	local swingSignal = ReplicatedStorage:FindFirstChild("SwordSwingSignal")
	if swingSignal then swingSignal:Fire() end

	local victim = scanHitbox()
	if victim then
		doMeleeHit(victim)
	end

	return Enum.ContextActionResult.Sink
end

--------------------------------------------------------------
-- MOBILE: attack a specific player tapped on screen, OR do a
-- generic forward-attack when the Attack button is pressed.
--------------------------------------------------------------

--- Called by MobileControls when the player taps on a character.
--- @param targetPlayer Player to attack
--- @return boolean whether an attack was performed
function _G.MobileAttackPlayer(targetPlayer: Player): boolean
	if targetPlayer == player then return false end

	local def = getSelectedDef()

	-- Projectile: throw toward that player
	if def and def.isProjectile then
		local now = tick()
		if (now - lastProjTime) < PROJ_COOLDOWN then return false end

		local slotCheck = InventoryMgr.GetSelectedSlot(localInventory)
		if not slotCheck or not slotCheck.itemId then return false end

		local consumed = ConsumeItemRemote:InvokeServer(def.id)
		if not consumed then return false end

		lastProjTime = now
		InventoryMgr.ConsumeSelected(localInventory)
		local localSignal = player:FindFirstChild("LocalInventoryChanged")
		if localSignal then
			localSignal:Fire(InventoryMgr.Serialize(localInventory))
		end

		punchOffset = PUNCH_STRENGTH
		spawnProjectile(def)

		local swingSignal = ReplicatedStorage:FindFirstChild("SwordSwingSignal")
		if swingSignal then swingSignal:Fire() end
		return true
	end

	-- Helper: handle melee logic if victim is hit
	local function doMeleeHit(v: Player)
		playHitSound()
		MeleeHitEvent:FireServer(v)
	end

	-- Melee: only if in range
	local now = tick()
	if (now - lastMeleeTime) < MELEE_COOLDOWN then return false end
	lastMeleeTime = now

	punchOffset = PUNCH_STRENGTH

	local swingSignal = ReplicatedStorage:FindFirstChild("SwordSwingSignal")
	if swingSignal then swingSignal:Fire() end

	doMeleeHit(targetPlayer)
	return true
end

--- Called by MobileControls Attack button — does a forward attack
--- just like the PC left-click (scans hitbox ahead of camera).
--- Always available; holding a block punches if a player is in range.
function _G.MobileDoAttack(): boolean
	-- Helper
	local function doMeleeHit(v: Player)
		playHitSound()
		MeleeHitEvent:FireServer(v)
	end

	local def = getSelectedDef()

	-- Projectile: throw forward
	if def and def.isProjectile then
		local now = tick()
		if (now - lastProjTime) < PROJ_COOLDOWN then return false end

		local slotCheck = InventoryMgr.GetSelectedSlot(localInventory)
		if not slotCheck or not slotCheck.itemId then return false end

		local consumed = ConsumeItemRemote:InvokeServer(def.id)
		if not consumed then return false end

		lastProjTime = now
		InventoryMgr.ConsumeSelected(localInventory)
		local localSignal = player:FindFirstChild("LocalInventoryChanged")
		if localSignal then
			localSignal:Fire(InventoryMgr.Serialize(localInventory))
		end

		punchOffset = PUNCH_STRENGTH
		spawnProjectile(def)

		local swingSignal = ReplicatedStorage:FindFirstChild("SwordSwingSignal")
		if swingSignal then swingSignal:Fire() end
		return true
	end

	-- Holding a block: only attack if a player is actually in the hitbox.
	-- Returns false when no player found so MobileControls can still place.
	local slot = InventoryMgr.GetSelectedSlot(localInventory)
	local heldDef = slot and slot.itemId and ItemDefs.Get(slot.itemId)
	if heldDef and heldDef.isBlock then
		local victim = scanHitbox()
		if not victim then return false end  -- no player → let building handle it

		local now = tick()
		if (now - lastMeleeTime) < MELEE_COOLDOWN then return true end  -- sink but don't double-fire
		lastMeleeTime = now
		punchOffset = PUNCH_STRENGTH
		local swingSignal = ReplicatedStorage:FindFirstChild("SwordSwingSignal")
		if swingSignal then swingSignal:Fire() end
		MeleeHitEvent:FireServer(victim)
		return true
	end

	-- Empty fist or melee weapon
	local now = tick()
	if (now - lastMeleeTime) < MELEE_COOLDOWN then return false end
	lastMeleeTime = now

	punchOffset = PUNCH_STRENGTH

	local swingSignal = ReplicatedStorage:FindFirstChild("SwordSwingSignal")
	if swingSignal then swingSignal:Fire() end

	local victim = scanHitbox()
	if victim then
		MeleeHitEvent:FireServer(victim)
	end
	return true
end

-- Bind: PC left-click + console RT (priority 2000 > building's 1000)
if not isMobile then
	ContextActionService:BindActionAtPriority("MeleeAttack", handleAttack, false, 2000,
		Enum.UserInputType.MouseButton1,
		Enum.KeyCode.ButtonR2
	)
end

print("[PvPClient] Melee + projectile system running.")
