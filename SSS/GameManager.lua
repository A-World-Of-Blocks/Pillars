--[[
	GameManager (Script)
	Location: ServerScriptService.GameManager

	Handles the full pre-game lobby, pillar assignment, player
	freezing, countdown, and game-start for the Pillars game.

	Map assumption:
	  • The workspace contains a Folder (or Model) named "Pillars"
	    that holds 8 children, each named "Pillar".
	  • Each Pillar model/folder contains a Part named "SpawnPart".

	State machine (simple linear):
	  LOBBY  →  (≥2 players)  →  COUNTDOWN  →  MATCH
	       ↑____ (players drop below 2 mid-countdown) _____|

	Systems:
	  1. Spawning & Freezing
	  2. Game Loop & Countdown
	  3. Edge Cases (PlayerRemoving)
]]

------------------------------------------------------------------------
-- SERVICES
------------------------------------------------------------------------
local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local TeleportService     = game:GetService("TeleportService")
local DataStoreService    = game:GetService("DataStoreService")
local HttpService         = game:GetService("HttpService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")

------------------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------------------
local MIN_PLAYERS    = 1    -- minimum players needed to start countdown
local COUNTDOWN_TIME = 25   -- seconds of countdown before match starts
local SPAWN_Y_OFFSET = 3    -- studs above SpawnPart surface to avoid clipping
local FROZEN_WALKSPEED  = 0
local FROZEN_JUMPPOWER  = 0
local ACTIVE_WALKSPEED  = 16
local ACTIVE_JUMPPOWER  = 50

-- Place ID of the game server (this place itself — used for requeuing).
-- TeleportService:GetPlaceId() is the cleanest way to get it at runtime.
local THIS_PLACE_ID = game.PlaceId

------------------------------------------------------------------------
-- GAME STATE
------------------------------------------------------------------------
-- Possible values: "LOBBY" | "COUNTDOWN" | "MATCH"
local gameState: string = "LOBBY"

------------------------------------------------------------------------
-- UI REMOTE
-- Fetched after a short wait to ensure SetupRemotes has run.
------------------------------------------------------------------------
local GameStateChanged: RemoteEvent = ReplicatedStorage:WaitForChild("GameStateChanged") :: RemoteEvent
local RequeueGame: RemoteEvent      = ReplicatedStorage:WaitForChild("RequeueGame")      :: RemoteEvent
local gameInProgress: BoolValue     = ReplicatedStorage:WaitForChild("GameInProgress")   :: BoolValue

--- Broadcast current state to every connected client.
local function broadcastState(state: string, data: { [string]: any })
	GameStateChanged:FireAllClients(state, data)
end

------------------------------------------------------------------------
-- SERVER REGISTRY
--
-- Game servers are always reserved servers (created via ReserveServer
-- in the lobby).  Because ReservedServerAccessCode can be longer than
-- 50 characters, we generate a short `serverKey` (UUID) to use as the
-- DataStore key, and store the `accessCode` inside the value.
--
-- Key layout in "PillarsServerRegistry_v3":
--   key   = serverKey
--   value = { serverKey, accessCode, playerCount, status, updatedAt }
--
-- The lobby writes the initial entry when it calls ReserveServer, then
-- passes the serverKey and accessCode to us via TeleportData.
-- We read them from the first player who joins.
--
-- Entries are removed when:
--   • Countdown or match starts (no more joins allowed)
--   • Server becomes empty
--   • BindToClose fires
------------------------------------------------------------------------
local MAX_PLAYERS_PER_SERVER = 8

local serverRegistry  = DataStoreService:GetDataStore("PillarsServerRegistry_v3")
-- MY_SERVER_KEY is populated once the first player arrives.
local MY_SERVER_KEY: string  = ""
local MY_ACCESS_CODE: string = ""

local function registrySet(status: string, playerCount: number)
	if MY_SERVER_KEY == "" then return end
	local ok, err = pcall(function()
		serverRegistry:SetAsync(MY_SERVER_KEY, {
			serverKey   = MY_SERVER_KEY,
			accessCode  = MY_ACCESS_CODE,
			playerCount = playerCount,
			status      = status,        -- "LOBBY" | "COUNTDOWN" | "MATCH"
			updatedAt   = os.time(),
		})
	end)
	if ok then
		print(string.format("[GameManager] Registry SET — status=%s players=%d key=%s", status, playerCount, MY_SERVER_KEY))
	else
		warn("[GameManager] Registry SET failed: " .. tostring(err))
	end
end

local function registryRemove()
	if MY_SERVER_KEY == "" then return end
	local ok, err = pcall(function()
		serverRegistry:RemoveAsync(MY_SERVER_KEY)
	end)
	if ok then
		print("[GameManager] Registry REMOVE — key=" .. MY_SERVER_KEY)
	else
		warn("[GameManager] Registry REMOVE failed: " .. tostring(err))
	end
end

-- Remove on server close
game:BindToClose(function()
	registryRemove()
end)

-- Helper called every time the player count or state changes.
local function updateRegistry()
	local count = #Players:GetPlayers()
	if gameState == "MATCH" or gameState == "COUNTDOWN" then
		registryRemove()
	elseif count == 0 then
		registryRemove()
	else
		registrySet(gameState, count)
	end
end

-- When the first player joins, read the serverKey from their TeleportData
-- and register this server in the DataStore so the lobby can find it.
Players.PlayerAdded:Connect(function(player: Player)
	if MY_SERVER_KEY == "" then
		-- player:GetJoinData() is the correct server-side API for reading
		-- data passed via TeleportOptions:SetTeleportData().
		local joinData = player:GetJoinData()
		local tpData   = joinData and joinData.TeleportData

		if type(tpData) == "table" and type(tpData._serverKey) == "string" and tpData._serverKey ~= "" then
			-- Strictly bound length to prevent ANY KeyNameLimit errors from stale teleport data
			MY_SERVER_KEY  = string.sub(tpData._serverKey, 1, 40)
			MY_ACCESS_CODE = tpData._accessCode or ""
			print("[GameManager] Server key received from TeleportData: " .. MY_SERVER_KEY)
			task.defer(updateRegistry)
		else
			print("[GameManager] No server key in TeleportData — may be Studio or direct join. TeleportData=" .. tostring(tpData))
		end
	else
		task.defer(updateRegistry)
	end
end)

Players.PlayerRemoving:Connect(function(_) task.defer(updateRegistry) end)


------------------------------------------------------------------------
-- SPAWN POOL SETUP
--
-- Scan the workspace for every SpawnPart inside every Pillar model.
-- We do this at server startup so the pool is ready before any player
-- can join.  If the Pillars folder isn't loaded yet we wait for it.
------------------------------------------------------------------------
local pillarsFolder = workspace:WaitForChild("Pillars")

-- availableSpawns: list of SpawnPart BaseParts not yet claimed
local availableSpawns: { BasePart } = {}

for _, pillar in pillarsFolder:GetChildren() do
	local spawnPart = pillar:FindFirstChild("SpawnPart")
	if spawnPart and spawnPart:IsA("BasePart") then
		table.insert(availableSpawns, spawnPart)
	else
		warn("[GameManager] Pillar '" .. pillar.Name .. "' has no SpawnPart BasePart!")
	end
end

print(string.format("[GameManager] Found %d spawn points.", #availableSpawns))

------------------------------------------------------------------------
-- PER-PLAYER DATA
--
-- Maps Player → the SpawnPart they were assigned so we can return it
-- to the pool if they disconnect.
------------------------------------------------------------------------
local assignedSpawn: { [Player]: BasePart } = {}

------------------------------------------------------------------------
-- HELPER: FREEZE a player's character in place
------------------------------------------------------------------------
local function freezePlayer(player: Player)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local hrp      = char:FindFirstChild("HumanoidRootPart")
	if humanoid then
		humanoid.WalkSpeed = FROZEN_WALKSPEED
		humanoid.JumpPower = FROZEN_JUMPPOWER
	end
	-- Anchor the root part as a belt-and-suspenders freeze so
	-- physics don't nudge the player off their pillar.
	if hrp then
		hrp.Anchored = true
	end
end

------------------------------------------------------------------------
-- HELPER: UNFREEZE a player's character
------------------------------------------------------------------------
local function unfreezePlayer(player: Player)
	local char = player.Character
	if not char then return end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local hrp      = char:FindFirstChild("HumanoidRootPart")
	if humanoid then
		humanoid.WalkSpeed = ACTIVE_WALKSPEED
		humanoid.JumpPower = ACTIVE_JUMPPOWER
	end
	if hrp then
		hrp.Anchored = false
	end
end

------------------------------------------------------------------------
-- HELPER: UNFREEZE every player currently in the game
------------------------------------------------------------------------
local function unfreezeAll()
	for _, player in Players:GetPlayers() do
		unfreezePlayer(player)
	end
end

------------------------------------------------------------------------
-- HELPER: Remove a specific entry from availableSpawns by reference
------------------------------------------------------------------------
local function removeFromPool(spawnPart: BasePart)
	for i, s in availableSpawns do
		if s == spawnPart then
			table.remove(availableSpawns, i)
			return
		end
	end
end

------------------------------------------------------------------------
-- HELPER: Return a SpawnPart back to the available pool
------------------------------------------------------------------------
local function returnToPool(spawnPart: BasePart)
	-- Guard against duplicates (shouldn't happen, but be safe)
	for _, s in availableSpawns do
		if s == spawnPart then return end
	end
	table.insert(availableSpawns, spawnPart)
	print("[GameManager] Spawn returned to pool. Pool size: " .. #availableSpawns)
end

------------------------------------------------------------------------
-- SYSTEM 1: ASSIGN SPAWN & TELEPORT & FREEZE
--
-- Called once the character has fully loaded.
-- Picks a random available SpawnPart, teleports the player to it,
-- claims it, and freezes them.
------------------------------------------------------------------------
local function assignSpawnToPlayer(player: Player)
	-- If the match is already running, don't re-spawn on an empty pillar.
	if gameState == "MATCH" then
		return
	end

	-- Check there's a free spawn slot.
	if #availableSpawns == 0 then
		warn("[GameManager] No available spawns for " .. player.Name .. "!")
		return
	end

	-- Pick a random SpawnPart from the pool.
	local index     = math.random(1, #availableSpawns)
	local spawnPart = availableSpawns[index]

	-- Claim it — remove from pool immediately.
	removeFromPool(spawnPart)
	assignedSpawn[player] = spawnPart

	-- Teleport: position the HRP above the SpawnPart's surface.
	local char = player.Character
	if not char then
		-- Character not loaded yet; this shouldn't happen here but guard anyway.
		returnToPool(spawnPart)
		assignedSpawn[player] = nil
		return
	end

	local hrp = char:WaitForChild("HumanoidRootPart", 5)
	if not hrp then
		warn("[GameManager] HumanoidRootPart not found for " .. player.Name)
		returnToPool(spawnPart)
		assignedSpawn[player] = nil
		return
	end

	-- Place the player on top of the SpawnPart.
	hrp.CFrame = spawnPart.CFrame * CFrame.new(0, SPAWN_Y_OFFSET, 0)

	-- Freeze immediately so they cannot move during the lobby/countdown.
	freezePlayer(player)

	print(string.format(
		"[GameManager] %s → %s (%s). Pool remaining: %d",
		player.Name,
		spawnPart.Name,
		spawnPart.Parent and spawnPart.Parent.Name or "?",
		#availableSpawns
		))
end

------------------------------------------------------------------------
-- SYSTEM 3 (EARLY): PLAYER REMOVING
--
-- When a player leaves at any time, give their SpawnPart back to the
-- pool so the next joining player can use it.
------------------------------------------------------------------------
Players.PlayerRemoving:Connect(function(player: Player)
	local spawnPart = assignedSpawn[player]
	if spawnPart then
		-- Only return to pool if we haven't started the match yet.
		-- Once the match is live, pillars are no longer relevant for
		-- re-spawning new players.
		if gameState ~= "MATCH" then
			returnToPool(spawnPart)
		end
		assignedSpawn[player] = nil
	end

	print(string.format(
		"[GameManager] %s left during %s. Players remaining: %d",
		player.Name, gameState, #Players:GetPlayers() - 1  -- -1 because PlayerRemoving fires before removal
		))
end)

------------------------------------------------------------------------
-- SYSTEM 1 (CONTINUED): PLAYER ADDED
--
-- Hook up character-loaded callback for every new player.
------------------------------------------------------------------------
Players.PlayerAdded:Connect(function(player: Player)
	-- CharacterAdded fires each time the character respawns.
	player.CharacterAdded:Connect(function(_char)
		-- Yield one frame so the character hierarchy is fully populated.
		task.wait()
		assignSpawnToPlayer(player)
	end)

	-- Handle the case where the character is already loaded when we
	-- connect (unlikely on server, but safe to cover).
	if player.Character then
		task.wait()
		assignSpawnToPlayer(player)
	end
end)

------------------------------------------------------------------------
-- SYSTEM 2: MAIN GAME LOOP
--
-- Runs exactly once at startup and drives the lobby → countdown →
-- match state machine.
------------------------------------------------------------------------

-- Countdown UI binding point (future): you can fire a RemoteEvent here
-- to update a GUI label with the remaining time.

local function runGameLoop()
	print("[GameManager] Server started. Waiting for players…")

	-- ----------------------------------------------------------------
	-- PHASE 1 — LOBBY: wait until at least MIN_PLAYERS are present.
	-- ----------------------------------------------------------------
	while #Players:GetPlayers() < MIN_PLAYERS do
		local playerCount = #Players:GetPlayers()
		broadcastState("LOBBY", { playerCount = playerCount, minPlayers = MIN_PLAYERS })
		task.wait(1)
		print(string.format(
			"[GameManager] LOBBY — %d/%d players. Waiting…",
			#Players:GetPlayers(), MIN_PLAYERS
			))
	end

	-- ----------------------------------------------------------------
	-- PHASE 2 — COUNTDOWN: count down from COUNTDOWN_TIME.
	-- Players who join during the countdown are assigned to a pillar
	-- automatically by the PlayerAdded / CharacterAdded callbacks above.
	-- ----------------------------------------------------------------
	gameState = "COUNTDOWN"
	updateRegistry()
	print(string.format(
		"[GameManager] %d player(s) detected. Starting %ds countdown!",
		#Players:GetPlayers(), COUNTDOWN_TIME
		))

	local timeLeft = COUNTDOWN_TIME

	-- Broadcast immediately so clients don't wait a second for first tick
	broadcastState("COUNTDOWN", { timeLeft = timeLeft, playerCount = #Players:GetPlayers() })

	while timeLeft > 0 do
		task.wait(1)
		timeLeft -= 1

		local playerCount = #Players:GetPlayers()

		-- If everyone left during the countdown, abort back to lobby.
		if playerCount < MIN_PLAYERS then
			print("[GameManager] Player count dropped below minimum. Aborting countdown — back to LOBBY.")
			gameState = "LOBBY"
			updateRegistry()
			broadcastState("LOBBY", { playerCount = playerCount, minPlayers = MIN_PLAYERS })
			-- Recursively restart the loop (tail-call style via task.spawn
			-- to avoid a deep stack if this keeps repeating).
			task.spawn(runGameLoop)
			return
		end

		-- Broadcast the new tick to all clients.
		broadcastState("COUNTDOWN", { timeLeft = timeLeft, playerCount = playerCount })

		-- Print every second so the Output window shows clear progress.
		print(string.format(
			"[GameManager] COUNTDOWN — %ds remaining | %d player(s) on pillars",
			timeLeft, playerCount
			))
	end

	-- ----------------------------------------------------------------
	-- PHASE 3 — MATCH START: unfreeze everyone and let the game begin.
	-- ----------------------------------------------------------------
	gameState = "MATCH"
	gameInProgress.Value = true   -- block new players from teleporting in
	updateRegistry()              -- removes this server from the joinable registry
	print("[GameManager] ══════════════════════════════")
	print("[GameManager]      MATCH START! GOOD LUCK.  ")
	print("[GameManager] ══════════════════════════════")

	broadcastState("MATCH", {})
	unfreezeAll()

	-- Signal other server scripts that the match has begun
	local matchStarted = ReplicatedStorage:FindFirstChild("MatchStarted")
	if matchStarted then
		matchStarted:Fire()
	end

	-- The match is now live.  Win detection is handled by SpectatorServer,
	-- which fires the MatchEnded BindableEvent when one player remains.
	-- That event (wired below) will respawn all players and restart this loop.
end

------------------------------------------------------------------------
-- ROUND RESET — triggered by SpectatorServer via the MatchEnded event.
-- Respawns every player, resets the spawn pool, and restarts the loop.
------------------------------------------------------------------------
local matchEnded = ReplicatedStorage:WaitForChild("MatchEnded") :: BindableEvent

matchEnded.Event:Connect(function(winnerName: string)
	print(string.format("[GameManager] Round over — winner: %s. Resetting…", winnerName))

	gameState = "LOBBY"
	gameInProgress.Value = false   -- allow new players to teleport in again
	updateRegistry()

	-- Broadcast LOBBY so client UIs (LobbyUI etc.) reset
	broadcastState("LOBBY", { playerCount = #Players:GetPlayers(), minPlayers = MIN_PLAYERS })

	-- Return ALL spawn parts to the pool so the next round can assign fresh pillars
	for _, pillar in pillarsFolder:GetChildren() do
		local sp = pillar:FindFirstChild("SpawnPart")
		if sp and sp:IsA("BasePart") then
			-- Only add if not already present
			local found = false
			for _, s in availableSpawns do
				if s == sp then found = true; break end
			end
			if not found then
				table.insert(availableSpawns, sp)
			end
		end
	end
	-- Clear per-player assignments
	for p in assignedSpawn do
		assignedSpawn[p] = nil
	end

	-- Give SpectatorServer time to call LoadCharacter on spectators first,
	-- then respawn any remaining players who were alive (they finished on top)
	task.delay(0.5, function()
		for _, p in Players:GetPlayers() do
			if p and p.Parent then
				p:LoadCharacter()
			end
		end

		-- Restart the game loop
		task.spawn(runGameLoop)
	end)
end)

-- Kick off the game loop on a separate thread so it doesn't block
-- any other server-side initialization.
task.spawn(runGameLoop)

------------------------------------------------------------------------
-- REQUEUE HANDLER
-- Client fires RequeueGame.  We look up their party (from PartySync),
-- read the ServerRegistry to find a joinable lobby server, and
-- TeleportAsync them there.  Falls back to ReserveServer.
------------------------------------------------------------------------
local PartySync = require(ReplicatedStorage:WaitForChild("PartySyncModule", 10))

local function findBestLobbyServer(neededSlots: number): { accessCode: string, serverKey: string }?
	-- List all registered servers, filter to joinable ones, pick fullest.
	-- Returns the best server's entry (or nil if none found).
	local pages
	local ok, err = pcall(function()
		pages = serverRegistry:ListKeysAsync()
	end)
	if not ok then
		warn("[GameManager] Registry ListKeys failed: " .. tostring(err))
		return nil
	end

	local STALE_SECONDS = 90

	local bestEntry = nil
	local bestCount = -1

	while true do
		local keys = pages:GetCurrentPage()
		for _, keyInfo in ipairs(keys) do
			local entry
			local rok = pcall(function()
				entry = serverRegistry:GetAsync(keyInfo.KeyName)
			end)
			if rok and type(entry) == "table"
				and entry.status == "LOBBY"
				and entry.serverKey ~= MY_SERVER_KEY   -- don't send back to ourselves
				and (os.time() - (entry.updatedAt or 0)) < STALE_SECONDS
				and (MAX_PLAYERS_PER_SERVER - (entry.playerCount or 0)) >= neededSlots
			then
				if (entry.playerCount or 0) > bestCount then
					bestCount = entry.playerCount
					bestEntry = entry
				end
			end
		end
		if pages.IsFinished then break end
		pages:AdvanceToNextPageAsync()
	end

	return bestEntry
end

RequeueGame.OnServerEvent:Connect(function(player)
	local partyData = PartySync and PartySync.GetParty(player)
	local playersToSend = {}

	if partyData then
		if partyData.hostUserId ~= player.UserId then
			warn("[GameManager] Non-host tried to requeue: " .. player.Name)
			return
		end
		for _, member in ipairs(partyData.members) do
			local p = Players:GetPlayerByUserId(member.userId)
			if p and p.Parent == Players then
				table.insert(playersToSend, p)
			end
		end
	else
		table.insert(playersToSend, player)
	end

	if #playersToSend == 0 then return end

	local teleportData = nil
	if partyData then
		teleportData = {
			partyCode  = partyData.code,
			members    = partyData.members,
			hostUserId = partyData.hostUserId,
		}
	end

	local bestEntry = findBestLobbyServer(#playersToSend)

	local teleportOptions = Instance.new("TeleportOptions")

	if bestEntry then
		-- Join an existing reserved lobby server
		if teleportData then
			teleportData._accessCode = bestEntry.accessCode
			teleportData._serverKey  = bestEntry.serverKey
			teleportOptions:SetTeleportData(teleportData)
		else
			teleportOptions:SetTeleportData({ _accessCode = bestEntry.accessCode, _serverKey = bestEntry.serverKey })
		end
		teleportOptions.ReservedServerAccessCode = bestEntry.accessCode
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(THIS_PLACE_ID, playersToSend, teleportOptions)
		end)
		if ok then return end
		warn("[GameManager] TeleportAsync to existing server failed: " .. tostring(err))
		teleportOptions.ReservedServerAccessCode = nil
	end

	-- Fallback: reserve a brand-new server, register it, then teleport
	local newCode
	local placeIdToReserve = tonumber(THIS_PLACE_ID)
	if not placeIdToReserve or placeIdToReserve == 0 then
		warn("[GameManager] Cannot ReserveServer — THIS_PLACE_ID is invalid or 0 (often happens in unpublished Studio games)")
		return
	end

	local rok, rerr = pcall(function()
		newCode = TeleportService:ReserveServerAsync(placeIdToReserve)
	end)
	if not rok then
		warn("[GameManager] ReserveServer failed: " .. tostring(rerr))
		return
	end

	-- Pre-register the new server so other queues can fill it
	local newServerKey = string.sub(HttpService:GenerateGUID(false), 1, 40)
	local setOk, setErr = pcall(function()
		serverRegistry:SetAsync(newServerKey, {
			serverKey   = newServerKey,
			accessCode  = newCode,
			playerCount = #playersToSend,
			status      = "LOBBY",
			updatedAt   = os.time(),
		})
	end)
	if not setOk then
		warn("[GameManager] Failed to SetAsync DataStore! Error:", tostring(setErr))
	end

	if teleportData then
		teleportData._accessCode = newCode
		teleportData._serverKey  = newServerKey
		teleportOptions:SetTeleportData(teleportData)
	else
		teleportOptions:SetTeleportData({ _accessCode = newCode, _serverKey = newServerKey })
	end
	teleportOptions.ReservedServerAccessCode = newCode

	pcall(function()
		TeleportService:TeleportAsync(THIS_PLACE_ID, playersToSend, teleportOptions)
	end)
end)


