-- 18336470541 game id

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Make reruns deterministic: remove an earlier copy before creating this one.
if _G.DebugESP and _G.DebugESP.Unload then
	pcall(_G.DebugESP.Unload)
end
for _, staleName in ipairs({ "ClientDebugESP", "ClientDebugESPControls" }) do
	local stale = PlayerGui:FindFirstChild(staleName)
	if stale then
		stale:Destroy()
	end
end

local Config = {
	Enabled = true,
	ShowLabels = true,
	ShowDistance = false,
	ShowHealth = false,
	ShowWeaponIndicator = true,
	RoundMemoryEnabled = true,
	MaxDistance = 800,
	RefreshRate = 0.1,
	HeadStartSeconds = 25,
	HeadStartTolerance = 2,
	LabelTextSize = 11,
	LabelWidth = 230,
	LabelHeight = 36,
	NormalFill = Color3.fromRGB(255, 215, 0),
	NormalOutline = Color3.fromRGB(255, 245, 150),
	HeldFill = Color3.fromRGB(255, 0, 0),
	HeldOutline = Color3.fromRGB(255, 180, 180),
	FriendlyFill = Color3.fromRGB(70, 210, 120),
	FriendlyOutline = Color3.fromRGB(180, 255, 200),
	FillTransparency = 0.78,
	OutlineTransparency = 0,
	WeaponNamePatterns = {
		"gun", "rifle", "pistol", "shotgun", "smg", "sniper",
		"bow", "sword", "knife", "grenade", "launcher", "akm",
		"m249", "aa-12", "remington", "iar", "sks", "pkm",
		"m16", "ak-74",
	},
}

local Records = {}
local RoundMemory = {}
local Root
local ControlsGui
local ControlsPanel
local MainConnection
local PlayerRemovingConnection
local RebindConnection
local elapsed = 0
local destroyed = false
local uiHidden = false
local stats = { visible = 0, held = 0, inventory = 0, players = 0 }

local function isAlive(instance)
	return instance and instance.Parent ~= nil
end

local function matchesWeaponName(name)
	local lowerName = string.lower(name or "")
	for _, pattern in ipairs(Config.WeaponNamePatterns) do
		if string.find(lowerName, string.lower(pattern), 1, true) then
			return true
		end
	end
	return false
end

local function hasHeldWeapon(player)
	local character = player.Character
	if not character then
		return false
	end

	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Tool") and matchesWeaponName(child.Name) then
			return true
		end
	end

	local weaponRig = character:FindFirstChild("WeaponRig")
	local weaponFolder = weaponRig and weaponRig:FindFirstChild("Weapon")
	return weaponFolder ~= nil and #weaponFolder:GetChildren() > 0
end

local function hasInventoryWeapon(player)
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") and matchesWeaponName(child.Name) then
				return true
			end
		end
	end

	local gunValue = player:FindFirstChild("gun")
	return gunValue ~= nil and tostring(gunValue.Value) ~= ""
end

local function getFaction(player)
	if not player.Team or player.Neutral or not LocalPlayer.Team or LocalPlayer.Neutral then
		return "PLAYER"
	end
	return player.Team == LocalPlayer.Team and "FRIENDLY" or "ENEMY"
end

local function getTargetParts(player)
	local character = player.Character
	if not character then
		return nil
	end

	local head = character:FindFirstChild("Head")
		or character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("HumanoidRootPart")
	local root = character:FindFirstChild("HumanoidRootPart")
		or character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("Torso")

	if not head or not root then
		return nil
	end
	return character, head, root
end

local function makeText(parent, text, size, color)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.Font = Enum.Font.Code
	label.TextSize = size or 11
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

local function getColors(faction, roundHeld)
	if roundHeld then
		return Config.HeldFill, Config.HeldOutline
	end
	if faction == "FRIENDLY" then
		return Config.FriendlyFill, Config.FriendlyOutline
	end
	return Config.NormalFill, Config.NormalOutline
end

local function createRecord(player)
	local character, head = getTargetParts(player)
	if not character then
		return nil
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "DebugESPHighlight"
	highlight.Adornee = character
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillTransparency = Config.FillTransparency
	highlight.OutlineTransparency = Config.OutlineTransparency
	highlight.Parent = Root

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DebugESPLabel"
	billboard.Adornee = head
	billboard.AlwaysOnTop = true
	billboard.Size = UDim2.fromOffset(Config.LabelWidth, Config.LabelHeight)
	billboard.StudsOffset = Vector3.new(0, 2.8, 0)
	billboard.Parent = Root

	local label = makeText(billboard, "", Config.LabelTextSize)
	label.Name = "Info"
	label.Size = UDim2.fromScale(1, 1)
	label.TextWrapped = true
	label.TextStrokeTransparency = 0.2
	label.TextXAlignment = Enum.TextXAlignment.Center

	return {
		player = player,
		character = character,
		highlight = highlight,
		billboard = billboard,
		label = label,
	}
end

local function removeRecord(player)
	local record = Records[player]
	if not record then
		return
	end
	if isAlive(record.highlight) then
		record.highlight:Destroy()
	end
	if isAlive(record.billboard) then
		record.billboard:Destroy()
	end
	Records[player] = nil
end

local function ensureRoot()
	if isAlive(Root) then
		return
	end
	Root = Instance.new("Folder")
	Root.Name = "ClientDebugESP"
	Root.Parent = PlayerGui
end

local function updateStatsLabel()
	local status = ControlsPanel and ControlsPanel:FindFirstChild("Status")
	if not status then
		return
	end
	status.Text = string.format(
		"ESP %s | %d players | %d visible | %d held | %d inv | RANGE %dm",
		Config.Enabled and "ON" or "OFF",
		stats.players,
		stats.visible,
		stats.held,
		stats.inventory,
		Config.MaxDistance
	)
	status.TextColor3 = Config.Enabled and Color3.fromRGB(140, 230, 160)
		or Color3.fromRGB(230, 150, 150)
end

local function setButtonState(button, feature, enabled)
	button.Text = feature .. ": " .. (enabled and "ON" or "OFF")
	button.TextColor3 = enabled and Color3.fromRGB(150, 255, 170)
		or Color3.fromRGB(255, 150, 150)
end

local function makeButton(parent, name, text, position, callback)
	local button = Instance.new("TextButton")
	button.Name = name
	button.Text = text
	button.Font = Enum.Font.Code
	button.TextSize = 11
	button.TextColor3 = Color3.fromRGB(235, 235, 235)
	button.BackgroundColor3 = Color3.fromRGB(36, 36, 40)
	button.BorderColor3 = Color3.fromRGB(105, 105, 115)
	button.Size = UDim2.fromOffset(112, 24)
	button.Position = position
	button.AutoButtonColor = true
	button.Parent = parent
	button.Activated:Connect(callback)
	return button
end

local function createControls()
	if isAlive(ControlsGui) then
		return
	end

	ControlsGui = Instance.new("ScreenGui")
	ControlsGui.Name = "ClientDebugESPControls"
	ControlsGui.ResetOnSpawn = false
	ControlsGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	ControlsGui.Parent = PlayerGui

	ControlsPanel = Instance.new("Frame")
	ControlsPanel.Name = "Panel"
	ControlsPanel.Size = UDim2.fromOffset(390, 330)
	ControlsPanel.Position = UDim2.fromOffset(24, 120)
	ControlsPanel.BackgroundColor3 = Color3.fromRGB(20, 20, 23)
	ControlsPanel.BorderColor3 = Color3.fromRGB(210, 170, 55)
	ControlsPanel.Parent = ControlsGui

	local accent = Instance.new("Frame")
	accent.Size = UDim2.fromOffset(4, 330)
	accent.BackgroundColor3 = Color3.fromRGB(235, 190, 55)
	accent.BorderSizePixel = 0
	accent.Parent = ControlsPanel

	local header = makeText(ControlsPanel, "CLIENT DEBUG ESP  //  LOCAL ONLY", 13, Color3.fromRGB(245, 205, 80))
	header.Name = "Header"
	header.Position = UDim2.fromOffset(14, 8)
	header.Size = UDim2.fromOffset(365, 22)
	header.TextXAlignment = Enum.TextXAlignment.Center

	local dragStart
	local startPosition
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragStart = input.Position
			startPosition = ControlsPanel.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not dragStart or not startPosition then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch then
			local delta = input.Position - dragStart
			ControlsPanel.Position = UDim2.new(
				startPosition.X.Scale,
				startPosition.X.Offset + delta.X,
				startPosition.Y.Scale,
				startPosition.Y.Offset + delta.Y
			)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragStart = nil
			startPosition = nil
		end
	end)

	local status = makeText(ControlsPanel, "", 10, Color3.fromRGB(140, 230, 160))
	status.Name = "Status"
	status.Position = UDim2.fromOffset(14, 34)
	status.Size = UDim2.fromOffset(365, 18)

	local enable
	enable = makeButton(ControlsPanel, "Enable", "ESP: ON", UDim2.fromOffset(14, 62), function()
		Config.Enabled = not Config.Enabled
		setButtonState(enable, "ESP", Config.Enabled)
		updateStatsLabel()
	end)
	setButtonState(enable, "ESP", Config.Enabled)

	local labels
	labels = makeButton(ControlsPanel, "Labels", "LABELS: ON", UDim2.fromOffset(142, 62), function()
		Config.ShowLabels = not Config.ShowLabels
		setButtonState(labels, "LABELS", Config.ShowLabels)
	end)
	setButtonState(labels, "LABELS", Config.ShowLabels)

	local distance
	distance = makeButton(ControlsPanel, "Distance", "DISTANCE: OFF", UDim2.fromOffset(270, 62), function()
		Config.ShowDistance = not Config.ShowDistance
		setButtonState(distance, "DISTANCE", Config.ShowDistance)
	end)
	setButtonState(distance, "DISTANCE", Config.ShowDistance)

	local health
	health = makeButton(ControlsPanel, "Health", "HEALTH: OFF", UDim2.fromOffset(14, 92), function()
		Config.ShowHealth = not Config.ShowHealth
		setButtonState(health, "HEALTH", Config.ShowHealth)
	end)
	setButtonState(health, "HEALTH", Config.ShowHealth)

	local weapons
	weapons = makeButton(ControlsPanel, "Weapons", "WEAPONS: ON", UDim2.fromOffset(142, 92), function()
		Config.ShowWeaponIndicator = not Config.ShowWeaponIndicator
		setButtonState(weapons, "WEAPONS", Config.ShowWeaponIndicator)
	end)
	setButtonState(weapons, "WEAPONS", Config.ShowWeaponIndicator)

	local memory
	memory = makeButton(ControlsPanel, "Memory", "ROUND MEMORY: ON", UDim2.fromOffset(270, 92), function()
		Config.RoundMemoryEnabled = not Config.RoundMemoryEnabled
		if not Config.RoundMemoryEnabled then
			table.clear(RoundMemory)
		end
		setButtonState(memory, "MEMORY", Config.RoundMemoryEnabled)
	end)
	setButtonState(memory, "MEMORY", Config.RoundMemoryEnabled)

	makeButton(ControlsPanel, "RangeDown", "RANGE -", UDim2.fromOffset(14, 122), function()
		Config.MaxDistance = math.max(100, Config.MaxDistance - 100)
		updateStatsLabel()
	end)

	makeButton(ControlsPanel, "RangeUp", "RANGE +", UDim2.fromOffset(142, 122), function()
		Config.MaxDistance = math.min(2000, Config.MaxDistance + 100)
		updateStatsLabel()
	end)

	makeButton(ControlsPanel, "Refresh", "REFRESH NOW", UDim2.fromOffset(270, 122), function()
		ensureRoot()
		for _, player in ipairs(Players:GetPlayers()) do
			removeRecord(player)
		end
	end)

	makeButton(ControlsPanel, "NewRound", "CLEAR ROUND", UDim2.fromOffset(14, 152), function()
		table.clear(RoundMemory)
	end)

	makeButton(ControlsPanel, "Hide", "HIDE PANEL", UDim2.fromOffset(142, 152), function()
		uiHidden = not uiHidden
		ControlsPanel.Visible = not uiHidden
	end)

	makeButton(ControlsPanel, "Unload", "UNLOAD ESP", UDim2.fromOffset(270, 152), function()
		if _G.DebugESP and _G.DebugESP.Unload then
			_G.DebugESP.Unload()
		end
	end)

	local info = makeText(
		ControlsPanel,
		"RANGE: " .. Config.MaxDistance .. " studs  |  Right Alt: hide/show\n"
			.. "GOLD = normal/inventory  |  RED = held or remembered\n"
			.. "PLAYER = no team data  |  head start = "
			.. Config.HeadStartSeconds .. "s +/- " .. Config.HeadStartTolerance .. "s",
		10,
		Color3.fromRGB(175, 175, 185)
	)
	info.Name = "Info"
	info.Position = UDim2.fromOffset(14, 190)
	info.Size = UDim2.fromOffset(365, 54)
	info.TextWrapped = true
	info.TextYAlignment = Enum.TextYAlignment.Top
end

local function refreshRecord(player)
	if player == LocalPlayer then
		return
	end

	local character, head, root = getTargetParts(player)
	if not character then
		removeRecord(player)
		return
	end

	local record = Records[player]
	if not record
		or record.character ~= character
		or not isAlive(record.highlight)
		or not isAlive(record.billboard) then
		removeRecord(player)
		record = createRecord(player)
		Records[player] = record
	end
	if not record then
		return
	end

	record.character = character
	record.highlight.Adornee = character
	record.highlight.Parent = Root
	record.billboard.Adornee = head
	record.billboard.Parent = Root

	local camera = workspace.CurrentCamera
	local distance = camera and (camera.CFrame.Position - root.Position).Magnitude or math.huge
	local visible = Config.Enabled and distance <= Config.MaxDistance
	local held = hasHeldWeapon(player)
	local inventory = hasInventoryWeapon(player)
	local faction = getFaction(player)
	local roundHeld = Config.RoundMemoryEnabled and RoundMemory[player.UserId] == true
	local fill, outline = getColors(faction, held or roundHeld)
	local state = Config.ShowWeaponIndicator
		and (held and "HELD" or (inventory and "INV" or "NONE"))
		or ""
	local distanceText = Config.ShowDistance and (" | " .. math.floor(distance) .. "m") or ""

	if held and Config.RoundMemoryEnabled then
		RoundMemory[player.UserId] = true
	end

	record.highlight.Enabled = visible
	record.billboard.Enabled = visible and Config.ShowLabels
	record.highlight.FillColor = fill
	record.highlight.OutlineColor = outline
	record.label.Text = (player.DisplayName or player.Name)
		.. " [" .. faction .. "]"
		.. (state ~= "" and (" | " .. state) or "")
		.. distanceText
	record.label.TextColor3 = (held or roundHeld)
		and Color3.fromRGB(255, 150, 150)
		or Color3.fromRGB(255, 255, 255)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if Config.ShowHealth and humanoid then
		record.label.Text ..= string.format(" | HP %d", math.max(0, math.floor(humanoid.Health)))
	end

	stats.players += 1
	if visible then
		stats.visible += 1
	end
	if held or roundHeld then
		stats.held += 1
	end
	if inventory then
		stats.inventory += 1
	end
end

local function newRound()
	table.clear(RoundMemory)
end

local function unload()
	if destroyed then
		return
	end
	destroyed = true
	for player in pairs(Records) do
		removeRecord(player)
	end
	if MainConnection then
		MainConnection:Disconnect()
	end
	if PlayerRemovingConnection then
		PlayerRemovingConnection:Disconnect()
	end
	if RebindConnection then
		RebindConnection:Disconnect()
	end
	if isAlive(ControlsGui) then
		ControlsGui:Destroy()
	end
	if isAlive(Root) then
		Root:Destroy()
	end
	if _G.DebugESP then
		_G.DebugESP = nil
	end
end

ensureRoot()
createControls()

MainConnection = RunService.RenderStepped:Connect(function(deltaTime)
	if destroyed then
		return
	end
	elapsed += deltaTime
	if elapsed < Config.RefreshRate then
		return
	end
	elapsed = 0

	ensureRoot()
	if not isAlive(ControlsGui) then
		createControls()
	end

	stats.players = 0
	stats.visible = 0
	stats.held = 0
	stats.inventory = 0
	for _, player in ipairs(Players:GetPlayers()) do
		refreshRecord(player)
	end
	updateStatsLabel()
end)

-- The game may add/remove its own reveal Highlight or rebuild the Seeker
-- character. Keep only our objects rebound to the current character.
RebindConnection = RunService.RenderStepped:Connect(function()
	if destroyed then
		return
	end
	ensureRoot()
	for player, record in pairs(Records) do
		if player ~= LocalPlayer then
			local character, head = getTargetParts(player)
			if character and head then
				if record.character ~= character
					or not isAlive(record.highlight)
					or not isAlive(record.billboard)
					or record.highlight.Adornee ~= character
					or record.billboard.Adornee ~= head then
					removeRecord(player)
					Records[player] = createRecord(player)
				else
					record.highlight.Parent = Root
					record.billboard.Parent = Root
				end
			end
		end
	end
end)

PlayerRemovingConnection = Players.PlayerRemoving:Connect(removeRecord)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or destroyed then
		return
	end
	if input.KeyCode == Enum.KeyCode.RightAlt and isAlive(ControlsPanel) then
		uiHidden = not uiHidden
		ControlsPanel.Visible = not uiHidden
	end
end)

_G.DebugESP = {
	Config = Config,
	Records = Records,
	RoundMemory = RoundMemory,
	HeadStart = {
		Seconds = Config.HeadStartSeconds,
		Tolerance = Config.HeadStartTolerance,
		RoleInference = false,
	},
	NewRound = newRound,
	Refresh = function()
		ensureRoot()
		for player in pairs(Records) do
			removeRecord(player)
		end
	end,
	SetEnabled = function(enabled)
		Config.Enabled = enabled == true
	end,
	SetUiHidden = function(hidden)
		uiHidden = hidden == true
		if isAlive(ControlsPanel) then
			ControlsPanel.Visible = not uiHidden
		end
	end,
	Unload = unload,
}
