--[[
	LobbyUI (LocalScript)
	Location: StarterPlayer.StarterPlayerScripts.LobbyUI

	Compact top-center info bar that shows game state.
	Smart re-animation: only slides in when content truly changes.
]]

------------------------------------------------------------------------
-- SERVICES
------------------------------------------------------------------------
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")

------------------------------------------------------------------------
-- REMOTE
------------------------------------------------------------------------
local GameStateChanged: RemoteEvent = ReplicatedStorage:WaitForChild("GameStateChanged") :: RemoteEvent

------------------------------------------------------------------------
-- PALETTE
------------------------------------------------------------------------
local C_BG          = Color3.fromRGB(8,   11,  22)    -- deep navy
local C_PANEL       = Color3.fromRGB(14,  18,  36)    -- panel base
local C_PANEL2      = Color3.fromRGB(20,  26,  52)    -- panel gradient end
local C_BORDER      = Color3.fromRGB(70, 130, 255)    -- electric blue
local C_BORDER_DIM  = Color3.fromRGB(40,  70, 160)    -- dimmer border
local C_TEXT        = Color3.fromRGB(220, 228, 255)   -- cool white
local C_MUTED       = Color3.fromRGB(100, 130, 190)   -- muted blue-grey
local C_GOLD        = Color3.fromRGB(255, 200,  50)   -- countdown gold
local C_GOLD_DARK   = Color3.fromRGB(180, 130,  20)
local C_RED         = Color3.fromRGB(255,  70,  70)   -- urgent red
local C_RED_DARK    = Color3.fromRGB(160,  30,  30)
local C_GREEN       = Color3.fromRGB( 50, 220, 110)   -- GO! green
local C_PILL        = Color3.fromRGB(22,  30,  60)

------------------------------------------------------------------------
-- HELPER CONSTRUCTORS
------------------------------------------------------------------------
local function corner(parent, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function stroke(parent, color, thick, trans)
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thick
	s.Transparency = trans or 0
	s.Parent = parent
	return s
end

local function padding(parent, t, b, l, r)
	local p = Instance.new("UIPadding")
	p.PaddingTop    = UDim.new(0, t)
	p.PaddingBottom = UDim.new(0, b)
	p.PaddingLeft   = UDim.new(0, l)
	p.PaddingRight  = UDim.new(0, r)
	p.Parent = parent
end

local function gradient(parent, c0, c1, rot)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(c0, c1)
	g.Rotation = rot or 90
	g.Parent = parent
	return g
end

------------------------------------------------------------------------
-- BUILD GUI
------------------------------------------------------------------------
local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screen = Instance.new("ScreenGui")
screen.Name           = "LobbyUI"
screen.ResetOnSpawn   = false
screen.IgnoreGuiInset = true
screen.DisplayOrder   = 10
screen.Parent         = playerGui

------------------------------------------------------------------------
-- OUTER WRAPPER — top-center anchor, no full-screen backdrop
------------------------------------------------------------------------
local wrapper = Instance.new("Frame")
wrapper.Name              = "Wrapper"
wrapper.AnchorPoint       = Vector2.new(0.5, 0)
wrapper.Size              = UDim2.new(0, 460, 0, 86)
wrapper.Position          = UDim2.new(0.5, 0, 0, -110)   -- start above screen
wrapper.BackgroundTransparency = 1
wrapper.BorderSizePixel   = 0
wrapper.ClipsDescendants  = false
wrapper.ZIndex            = 2
wrapper.Parent            = screen

------------------------------------------------------------------------
-- OUTER GLOW FRAME (soft shadow / bloom effect)
------------------------------------------------------------------------
local glow = Instance.new("Frame")
glow.Name             = "Glow"
glow.Size             = UDim2.new(1, 24, 1, 24)
glow.Position         = UDim2.new(0, -12, 0, -12)
glow.BackgroundColor3 = C_BORDER
glow.BackgroundTransparency = 0.82
glow.BorderSizePixel  = 0
glow.ZIndex           = 1
glow.Parent           = wrapper
corner(glow, 22)

------------------------------------------------------------------------
-- MAIN PANEL CARD
------------------------------------------------------------------------
local panel = Instance.new("Frame")
panel.Name             = "Panel"
panel.Size             = UDim2.fromScale(1, 1)
panel.Position         = UDim2.fromScale(0, 0)
panel.BackgroundColor3 = C_PANEL
panel.BorderSizePixel  = 0
panel.ZIndex           = 2
panel.Parent           = wrapper
corner(panel, 14)

-- Panel gradient
local panelGrad = Instance.new("UIGradient")
panelGrad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0,   C_PANEL),
	ColorSequenceKeypoint.new(1,   C_PANEL2),
})
panelGrad.Rotation = 120
panelGrad.Parent = panel

-- Top highlight line (1px bright stripe at top edge)
local topLine = Instance.new("Frame")
topLine.Size             = UDim2.new(0.6, 0, 0, 1)
topLine.Position         = UDim2.new(0.2, 0, 0, 0)
topLine.BackgroundColor3 = C_BORDER
topLine.BackgroundTransparency = 0.3
topLine.BorderSizePixel  = 0
topLine.ZIndex           = 4
topLine.Parent           = panel
corner(topLine, 1)

-- Panel border stroke
local panelStroke = stroke(panel, C_BORDER, 1.5, 0.15)

------------------------------------------------------------------------
-- CONTENT LAYOUT — horizontal flex row
------------------------------------------------------------------------
-- Left icon badge
local iconBadge = Instance.new("Frame")
iconBadge.Name            = "IconBadge"
iconBadge.Size            = UDim2.new(0, 52, 0, 52)
iconBadge.Position        = UDim2.new(0, 16, 0.5, 0)
iconBadge.AnchorPoint     = Vector2.new(0, 0.5)
iconBadge.BackgroundColor3 = C_BORDER
iconBadge.BackgroundTransparency = 0.80
iconBadge.BorderSizePixel = 0
iconBadge.ZIndex          = 3
iconBadge.Parent          = panel
corner(iconBadge, 12)
stroke(iconBadge, C_BORDER, 1, 0.5)

local iconLabel = Instance.new("TextLabel")
iconLabel.Size             = UDim2.fromScale(1, 1)
iconLabel.BackgroundTransparency = 1
iconLabel.Text             = "⚔"
iconLabel.Font             = Enum.Font.GothamBold
iconLabel.TextSize         = 24
iconLabel.TextColor3       = C_BORDER
iconLabel.TextXAlignment   = Enum.TextXAlignment.Center
iconLabel.ZIndex           = 4
iconLabel.Parent           = iconBadge

-- Text column
local textCol = Instance.new("Frame")
textCol.Name              = "TextCol"
textCol.Size              = UDim2.new(1, -84, 1, 0)
textCol.Position          = UDim2.new(0, 78, 0, 0)
textCol.BackgroundTransparency = 1
textCol.BorderSizePixel   = 0
textCol.ZIndex            = 3
textCol.Parent            = panel

-- Game title (small cap label)
local gameTitle = Instance.new("TextLabel")
gameTitle.Name            = "GameTitle"
gameTitle.Size            = UDim2.new(1, -8, 0, 18)
gameTitle.Position        = UDim2.new(0, 0, 0, 12)
gameTitle.BackgroundTransparency = 1
gameTitle.Text            = "PILLARS"
gameTitle.Font            = Enum.Font.GothamBold
gameTitle.TextSize        = 11
gameTitle.TextColor3      = C_BORDER
gameTitle.TextXAlignment  = Enum.TextXAlignment.Left
--gameTitle.LetterSpacing   = 4   -- wide tracking (requires TextLabel property)
gameTitle.ZIndex          = 4
gameTitle.Parent          = textCol

-- Main message
local msgLabel = Instance.new("TextLabel")
msgLabel.Name            = "MsgLabel"
msgLabel.Size            = UDim2.new(1, -8, 0, 26)
msgLabel.Position        = UDim2.new(0, 0, 0, 28)
msgLabel.BackgroundTransparency = 1
msgLabel.Text            = "Waiting for players…"
msgLabel.Font            = Enum.Font.GothamSemibold
msgLabel.TextSize        = 16
msgLabel.TextColor3      = C_TEXT
msgLabel.TextXAlignment  = Enum.TextXAlignment.Left
msgLabel.TextWrapped     = true
msgLabel.ZIndex          = 4
msgLabel.Parent          = textCol

------------------------------------------------------------------------
-- RIGHT SIDE — countdown number OR player pill
------------------------------------------------------------------------
local rightCol = Instance.new("Frame")
rightCol.Name             = "RightCol"
rightCol.Size             = UDim2.new(0, 72, 1, 0)
rightCol.Position         = UDim2.new(1, -80, 0, 0)
rightCol.BackgroundTransparency = 1
rightCol.BorderSizePixel  = 0
rightCol.ZIndex           = 3
rightCol.Parent           = panel

-- Player pill (lobby / countdown)
local pill = Instance.new("Frame")
pill.Name             = "Pill"
pill.Size             = UDim2.new(0, 68, 0, 28)
pill.Position         = UDim2.new(0.5, 0, 0.5, 0)
pill.AnchorPoint      = Vector2.new(0.5, 0.5)
pill.BackgroundColor3 = C_PILL
pill.BackgroundTransparency = 0.1
pill.BorderSizePixel  = 0
pill.ZIndex           = 4
pill.Parent           = rightCol
corner(pill, 14)
stroke(pill, C_BORDER, 1, 0.5)

local pillLabel = Instance.new("TextLabel")
pillLabel.Size            = UDim2.fromScale(1, 1)
pillLabel.BackgroundTransparency = 1
pillLabel.Text            = "1/2"
pillLabel.Font            = Enum.Font.GothamBold
pillLabel.TextSize        = 14
pillLabel.TextColor3      = C_TEXT
pillLabel.TextXAlignment  = Enum.TextXAlignment.Center
pillLabel.ZIndex          = 5
pillLabel.Visible 		  = false
pillLabel.Parent          = pill

-- Countdown number (replaces pill during countdown)
local cdLabel = Instance.new("TextLabel")
cdLabel.Name             = "CdLabel"
cdLabel.Size             = UDim2.fromScale(1, 1)
cdLabel.BackgroundTransparency = 1
cdLabel.Text             = ""
cdLabel.Font             = Enum.Font.GothamBold
cdLabel.TextSize         = 40
cdLabel.TextColor3       = C_GOLD
cdLabel.TextXAlignment   = Enum.TextXAlignment.Center
cdLabel.ZIndex           = 4
cdLabel.Visible          = false
cdLabel.Parent           = rightCol

------------------------------------------------------------------------
-- PROGRESS BAR — thin strip along the very bottom of the panel
------------------------------------------------------------------------
local barBg = Instance.new("Frame")
barBg.Name             = "BarBg"
barBg.Size             = UDim2.new(1, -28, 0, 4)
barBg.Position         = UDim2.new(0, 14, 1, -8)
barBg.AnchorPoint      = Vector2.new(0, 1)
barBg.BackgroundColor3 = Color3.fromRGB(25, 32, 62)
barBg.BackgroundTransparency = 0.2
barBg.BorderSizePixel  = 0
barBg.ZIndex           = 3
barBg.Visible          = false
barBg.Parent           = panel
corner(barBg, 2)

local barFill = Instance.new("Frame")
barFill.Name             = "BarFill"
barFill.Size             = UDim2.fromScale(1, 1)
barFill.BackgroundColor3 = C_GOLD
barFill.BorderSizePixel  = 0
barFill.ZIndex           = 4
barFill.Parent           = barBg
corner(barFill, 2)

local barGrad = Instance.new("UIGradient")
barGrad.Color = ColorSequence.new(C_GOLD, C_GOLD_DARK)
barGrad.Rotation = 90
barGrad.Parent = barFill

------------------------------------------------------------------------
-- DOTS LABEL (sits inside textCol, below msgLabel)
------------------------------------------------------------------------
local dotsLabel = Instance.new("TextLabel")
dotsLabel.Name            = "DotsLabel"
dotsLabel.Size            = UDim2.new(1, 0, 0, 14)
dotsLabel.Position        = UDim2.new(0, 0, 0, 56)
dotsLabel.BackgroundTransparency = 1
dotsLabel.Text            = "• • •"
dotsLabel.Font            = Enum.Font.Gotham
dotsLabel.TextSize        = 11
dotsLabel.TextColor3      = C_MUTED
dotsLabel.TextXAlignment  = Enum.TextXAlignment.Left
dotsLabel.ZIndex          = 4
dotsLabel.Parent          = textCol

------------------------------------------------------------------------
-- LOCAL STATE
------------------------------------------------------------------------
local currentState     = ""      -- "", "LOBBY", "COUNTDOWN", "MATCH"
local lastMinPlayers   = -1
local lastPlayerCount  = -1
local totalTime        = 20
local isPanelVisible   = false
local activeTweens: { Tween } = {}

------------------------------------------------------------------------
-- TWEEN HELPERS
------------------------------------------------------------------------
local function cancelTweens()
	for _, t in activeTweens do t:Cancel() end
	table.clear(activeTweens)
end

local function tw(obj, info, props)
	local t = TweenService:Create(obj, info, props)
	table.insert(activeTweens, t)
	t:Play()
	return t
end

------------------------------------------------------------------------
-- SLIDE POSITIONS
------------------------------------------------------------------------
local POS_SHOWN  = UDim2.new(0.5, 0, 0,  18)   -- just below top edge
local POS_HIDDEN = UDim2.new(0.5, 0, 0, -110)  -- above screen

local easeOut = TweenInfo.new(0.5,  Enum.EasingStyle.Back,  Enum.EasingDirection.Out)
local easeIn  = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.In)

local function slideIn()
	if isPanelVisible then return end
	isPanelVisible = true
	wrapper.Position = POS_HIDDEN
	wrapper.Visible  = true
	tw(wrapper, easeOut, { Position = POS_SHOWN })
end

local function slideOut(cb)
	if not isPanelVisible then
		if cb then cb() end
		return
	end
	isPanelVisible = false
	tw(wrapper, easeIn, { Position = POS_HIDDEN })
	task.delay(0.4, function()
		wrapper.Visible = false
		if cb then cb() end
	end)
end

local function nudgeIn()
	-- Small bounce to signal a content refresh without full slide
	tw(wrapper, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.new(0.5, 0, 0, 22),
	})
	task.delay(0.18, function()
		tw(wrapper, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = POS_SHOWN,
		})
	end)
end

------------------------------------------------------------------------
-- BORDER PULSE
------------------------------------------------------------------------
local borderThread: thread? = nil

local function startBorderPulse()
	if borderThread then task.cancel(borderThread) end
	borderThread = task.spawn(function()
		while true do
			tw(panelStroke, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Transparency = 0.65 })
			tw(glow,        TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { BackgroundTransparency = 0.92 })
			task.wait(1.4)
			tw(panelStroke, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { Transparency = 0.1 })
			tw(glow,        TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { BackgroundTransparency = 0.78 })
			task.wait(1.4)
		end
	end)
end

local function stopBorderPulse()
	if borderThread then task.cancel(borderThread) end
	borderThread = nil
	panelStroke.Transparency = 0.15
	glow.BackgroundTransparency = 0.82
end

------------------------------------------------------------------------
-- DOTS ANIMATION
------------------------------------------------------------------------
local dotsThread: thread? = nil
local DOT_SEQ = { "·", "· ·", "· · ·", "· ·", "·" }

local function startDots()
	if dotsThread then task.cancel(dotsThread) end
	dotsLabel.Visible = true
	dotsThread = task.spawn(function()
		local i = 1
		while true do
			dotsLabel.Text = DOT_SEQ[i]
			i = (i % #DOT_SEQ) + 1
			task.wait(0.5)
		end
	end)
end

local function stopDots()
	if dotsThread then task.cancel(dotsThread) end
	dotsThread = nil
	dotsLabel.Visible = false
end

------------------------------------------------------------------------
-- COUNTDOWN NUMBER BOUNCE
------------------------------------------------------------------------
local function bounceNumber(n: number)
	local urgent = n <= 5
	local color  = if urgent then C_RED else C_GOLD

	cdLabel.TextColor3 = color
	cdLabel.TextSize   = 52
	cdLabel.Text       = tostring(n)

	tw(cdLabel, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		TextSize = 40,
	})

	-- Flash the glow on each tick
	glow.BackgroundColor3        = color
	glow.BackgroundTransparency  = 0.6
	tw(glow, TweenInfo.new(0.8, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0.88,
		BackgroundColor3       = C_BORDER,
	})
end

------------------------------------------------------------------------
-- STATE: LOBBY
------------------------------------------------------------------------
local function applyLobbyState(playerCount: number, minPlayers: number)
	local stateChanged  = currentState ~= "LOBBY"
	local contentChanged = playerCount ~= lastPlayerCount or minPlayers ~= lastMinPlayers

	if not stateChanged and not contentChanged then return end  -- nothing to do

	lastPlayerCount = playerCount
	lastMinPlayers  = minPlayers

	if stateChanged then
		cancelTweens()
		stopDots()
		stopBorderPulse()
		currentState = "LOBBY"

		-- Reset visuals for lobby
		iconLabel.Text        = "⚔"
		iconLabel.TextColor3  = C_BORDER
		iconBadge.BackgroundColor3 = C_BORDER

		msgLabel.TextColor3   = C_TEXT
		msgLabel.TextSize     = 16

		cdLabel.Visible       = false
		barBg.Visible         = false
		pill.Visible          = true

		startDots()
		startBorderPulse()
	end

	-- Update text
	msgLabel.Text = string.format("Waiting for %d more player%s to join",
		math.max(0, minPlayers - playerCount),
		if (minPlayers - playerCount) == 1 then "" else "s"
	)
	pillLabel.Text = string.format("%d / %d", playerCount, minPlayers)

	if not isPanelVisible then
		slideIn()
	elseif contentChanged and not stateChanged then
		-- Just a count update: subtle nudge, no full slide
		nudgeIn()
		tw(pill, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = 0,
		})
		task.delay(0.25, function()
			tw(pill, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				BackgroundTransparency = 0.1,
			})
		end)
	end
end

------------------------------------------------------------------------
-- STATE: COUNTDOWN
------------------------------------------------------------------------
local function applyCountdownState(timeLeft: number, playerCount: number)
	local stateChanged = currentState ~= "COUNTDOWN"

	if stateChanged then
		cancelTweens()
		stopDots()
		stopBorderPulse()
		currentState = "COUNTDOWN"
		totalTime    = timeLeft

		-- Transition icon to timer icon
		iconLabel.Text       = "⏱"
		iconLabel.TextColor3 = C_GOLD
		iconBadge.BackgroundColor3 = C_GOLD

		msgLabel.TextColor3  = C_MUTED
		msgLabel.TextSize    = 14

		cdLabel.Visible      = true
		pill.Visible         = true
		barBg.Visible        = true
		barFill.Size         = UDim2.fromScale(1, 1)

		if not isPanelVisible then
			slideIn()
		end
	end

	msgLabel.Text  = "Match starts in"
	pillLabel.Text = string.format("%d ▸", playerCount)

	bounceNumber(timeLeft)

	-- Progress bar
	local frac    = math.clamp(timeLeft / totalTime, 0, 1)
	local urgent  = timeLeft <= 5
	local barC1   = if urgent then C_RED      else C_GOLD
	local barC2   = if urgent then C_RED_DARK else C_GOLD_DARK

	barGrad.Color = ColorSequence.new(barC1, barC2)
	barFill.BackgroundColor3 = barC1

	tw(barFill, TweenInfo.new(0.85, Enum.EasingStyle.Linear), {
		Size = UDim2.fromScale(frac, 1),
	})
end

------------------------------------------------------------------------
-- STATE: MATCH
------------------------------------------------------------------------
local function applyMatchState()
	cancelTweens()
	stopDots()
	stopBorderPulse()
	currentState = "MATCH"

	-- Flash panel green
	iconLabel.Text       = "🏁"
	iconLabel.TextColor3 = C_GREEN
	iconBadge.BackgroundColor3 = C_GREEN

	msgLabel.Text      = "Match started — good luck!"
	msgLabel.TextColor3 = C_GREEN
	msgLabel.TextSize  = 16

	cdLabel.Text       = "GO!"
	cdLabel.TextColor3 = C_GREEN
	cdLabel.TextSize   = 28
	cdLabel.Visible    = true

	pill.Visible   = false
	barBg.Visible  = false
	stopDots()

	-- Glow flare
	glow.BackgroundColor3       = C_GREEN
	glow.BackgroundTransparency = 0.4
	tw(glow, TweenInfo.new(1, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0.90,
		BackgroundColor3       = C_BORDER,
	})

	-- Slide out after 2 s
	task.delay(2, function()
		slideOut(function()
			-- Full reset for next round
			barFill.Size             = UDim2.fromScale(1, 1)
			cdLabel.Visible          = false
			cdLabel.Text             = ""
			pill.Visible             = true
			glow.BackgroundColor3    = C_BORDER
			glow.BackgroundTransparency = 0.82
			panelStroke.Transparency = 0.15
		end)
	end)
end

------------------------------------------------------------------------
-- REMOTE LISTENER
------------------------------------------------------------------------
GameStateChanged.OnClientEvent:Connect(function(state: string, data: { [string]: any })
	if state == "LOBBY" then
		applyLobbyState(
			tonumber(data.playerCount) or 1,
			tonumber(data.minPlayers)  or 2
		)
	elseif state == "COUNTDOWN" then
		applyCountdownState(
			tonumber(data.timeLeft)    or 20,
			tonumber(data.playerCount) or 1
		)
	elseif state == "MATCH" then
		applyMatchState()
	end
end)

------------------------------------------------------------------------
-- INITIAL SHOW
------------------------------------------------------------------------
task.delay(0.5, function()
	if currentState == "" then
		applyLobbyState(#Players:GetPlayers(), 2)
	end
end)
