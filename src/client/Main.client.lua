local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Events = ReplicatedStorage:WaitForChild("Events")

local MoveRequest = Events:WaitForChild("MoveRequest")
local RestartRound = Events:WaitForChild("RestartRound")
local NextRound = Events:WaitForChild("NextRound")
local UpdateUI = Events:WaitForChild("UpdateUI")
local PenaltyFlash = Events:WaitForChild("PenaltyFlash")
local RoundEnd = Events:WaitForChild("RoundEnd")
local SetMode = Events:WaitForChild("SetMode")
local PlaySound = Events:WaitForChild("PlaySound")

-- Wait for the map nodes to fully replicate from the server
local NodesFolder = Workspace:WaitForChild("Nodes")

-- UI SETUP
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DijkstraUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = playerGui

-- SOUNDS
local sounds = {
	RightNode = Instance.new("Sound"),
	Success = Instance.new("Sound"),
	Fail = Instance.new("Sound"),
	Oof = Instance.new("Sound")
}

sounds.RightNode.SoundId = "rbxassetid://876939830"
sounds.RightNode.Volume = 0.5

sounds.Success.SoundId = "rbxassetid://2865227271"
sounds.Success.Volume = 0.8

sounds.Fail.SoundId = "rbxassetid://12222242"
sounds.Fail.Volume = 0.8

sounds.Oof.SoundId = "rbxassetid://12222242"
sounds.Oof.Volume = 0.6

for _, s in pairs(sounds) do
	s.Parent = ScreenGui
end

local ambiance = Instance.new("Sound")
ambiance.SoundId = "rbxassetid://4630467570" -- Generic university/ambient chatter
ambiance.Looped = true
ambiance.Volume = 0.15
ambiance.Parent = game.Workspace
ambiance:Play()

local function CreateFloatingText(text, color, position)
	local part = Instance.new("Part")
	part.Size = Vector3.new(1, 1, 1)
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 1
	part.Parent = game.Workspace
	
	local bg = Instance.new("BillboardGui")
	bg.Size = UDim2.new(0, 200, 0, 50)
	bg.StudsOffset = Vector3.new(0, 2, 0)
	bg.AlwaysOnTop = true
	bg.Parent = part
	
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.new(1, 0, 1, 0)
	tl.BackgroundTransparency = 1
	tl.Text = text
	tl.TextColor3 = color
	tl.TextStrokeTransparency = 0.3
	tl.TextStrokeColor3 = Color3.new(0,0,0)
	tl.TextScaled = true
	tl.Font = Enum.Font.GothamBlack
	tl.Parent = bg
	
	TweenService:Create(bg, TweenInfo.new(1.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {StudsOffset = Vector3.new(0, 6, 0)}):Play()
	TweenService:Create(tl, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {TextTransparency = 1, TextStrokeTransparency = 1}):Play()
	
	game.Debris:AddItem(part, 1.5)
end

local function CreatePulse(position)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.2, 2, 2)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi/2)
	part.Color = Color3.fromRGB(80, 255, 120)
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.Transparency = 0.2
	part.Parent = game.Workspace
	
	TweenService:Create(part, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, 20, 20),
		Transparency = 1
	}):Play()
	game.Debris:AddItem(part, 0.7)
end

PlaySound.OnClientEvent:Connect(function(sType)
	if sounds[sType] then
		if sType == "RightNode" then
			sounds[sType].PlaybackSpeed = 1 + (math.random() * 0.3 - 0.15)
		end
		sounds[sType]:Play()
	end
	
	local char = player.Character
	if not char or not char:FindFirstChild("HumanoidRootPart") then return end
	
	local rootPos = char.HumanoidRootPart.Position
	local headPos = char:FindFirstChild("Head") and char.Head.Position or (rootPos + Vector3.new(0, 2, 0))
	
	if sType == "RightNode" then
		local rightFlash = Instance.new("Frame")
		rightFlash.Size = UDim2.new(1, 0, 1, 0)
		rightFlash.BackgroundColor3 = Color3.fromRGB(100, 255, 150)
		rightFlash.BackgroundTransparency = 0.85
		rightFlash.ZIndex = 0
		rightFlash.Parent = ScreenGui
		
		TweenService:Create(rightFlash, TweenInfo.new(0.5, Enum.EasingStyle.Cubic), {BackgroundTransparency = 1}):Play()
		game.Debris:AddItem(rightFlash, 0.6)
		
		CreateFloatingText("✔️ CERTO!", Color3.fromRGB(80, 255, 120), headPos)
		CreatePulse(rootPos - Vector3.new(0, 2.5, 0))
	elseif sType == "Success" then
		CreateFloatingText("🌟 MISSÃO PERFEITA! 🌟", Color3.fromRGB(255, 215, 0), headPos + Vector3.new(0, 2, 0))
	elseif sType == "Fail" then
		CreateFloatingText("❌ TENTE DE NOVO!", Color3.fromRGB(255, 80, 80), headPos + Vector3.new(0, 2, 0))
	elseif sType == "Oof" then
		CreateFloatingText("⚠️ PENALIDADE!", Color3.fromRGB(255, 100, 50), headPos + Vector3.new(math.random(-2,2), 0, math.random(-2,2)))
	end
end)

-- MAIN CONTAINER
local MainContainer = Instance.new("Frame")
MainContainer.Size = UDim2.new(1, 0, 1, 0)
MainContainer.BackgroundTransparency = 1
MainContainer.Visible = false
MainContainer.Parent = ScreenGui

-- START MENU ENHANCEMENT
local StartMenu = Instance.new("Frame")
StartMenu.Size = UDim2.new(1, 0, 1, 0)
StartMenu.BackgroundColor3 = Color3.new(1, 1, 1)
StartMenu.Parent = ScreenGui

local UIGradient = Instance.new("UIGradient")
UIGradient.Color = ColorSequence.new{
	ColorSequenceKeypoint.new(0, Color3.fromRGB(15, 23, 42)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 41, 59))
}
UIGradient.Rotation = 45
UIGradient.Parent = StartMenu

local Title = Instance.new("TextLabel")
Title.Text = "Universidade Dijkstra"
Title.Font = Enum.Font.GothamBlack
Title.TextSize = 56
Title.TextColor3 = Color3.new(1,1,1)
Title.Size = UDim2.new(1, 0, 0, 120)
Title.Position = UDim2.new(0, 0, 0.2, 0)
Title.BackgroundTransparency = 1
Title.ZIndex = 2
Title.Parent = StartMenu

local TitleShadow = Instance.new("TextLabel")
TitleShadow.Text = "Universidade Dijkstra"
TitleShadow.Font = Enum.Font.GothamBlack
TitleShadow.TextSize = 56
TitleShadow.TextColor3 = Color3.fromRGB(55, 138, 221)
TitleShadow.Size = UDim2.new(1, 0, 0, 120)
TitleShadow.Position = UDim2.new(0, 4, 0.2, 4)
TitleShadow.BackgroundTransparency = 1
TitleShadow.ZIndex = 1
TitleShadow.Parent = StartMenu

local Subtitle = Instance.new("TextLabel")
Subtitle.Text = "Aprenda Grafos Jogando!"
Subtitle.Font = Enum.Font.GothamMedium
Subtitle.TextSize = 24
Subtitle.TextColor3 = Color3.fromRGB(200, 200, 200)
Subtitle.Size = UDim2.new(1, 0, 0, 40)
Subtitle.Position = UDim2.new(0, 0, 0.2, 80)
Subtitle.BackgroundTransparency = 1
Subtitle.Parent = StartMenu

local BtnMode1 = Instance.new("TextButton")
BtnMode1.Text = "Modo Dijkstra"
BtnMode1.Font = Enum.Font.GothamBold
BtnMode1.TextSize = 24
BtnMode1.TextColor3 = Color3.new(1,1,1)
BtnMode1.BackgroundColor3 = Color3.fromRGB(29, 158, 117)
BtnMode1.Size = UDim2.new(0, 300, 0, 65)
BtnMode1.Position = UDim2.new(0.5, -150, 0.5, -30)
Instance.new("UICorner", BtnMode1).CornerRadius = UDim.new(0, 12)
Instance.new("UIStroke", BtnMode1).Color = Color3.fromRGB(20, 110, 80)
Instance.new("UIStroke", BtnMode1).Thickness = 3
BtnMode1.Parent = StartMenu

local BtnMode2 = Instance.new("TextButton")
BtnMode2.Text = "Modo Livre"
BtnMode2.Font = Enum.Font.GothamBold
BtnMode2.TextSize = 24
BtnMode2.TextColor3 = Color3.new(1,1,1)
BtnMode2.BackgroundColor3 = Color3.fromRGB(80, 90, 100)
BtnMode2.Size = UDim2.new(0, 300, 0, 65)
BtnMode2.Position = UDim2.new(0.5, -150, 0.5, 60)
Instance.new("UICorner", BtnMode2).CornerRadius = UDim.new(0, 12)
Instance.new("UIStroke", BtnMode2).Color = Color3.fromRGB(50, 60, 70)
Instance.new("UIStroke", BtnMode2).Thickness = 3
BtnMode2.Parent = StartMenu

-- Hover effects
BtnMode1.MouseEnter:Connect(function() TweenService:Create(BtnMode1, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(39, 188, 137)}):Play() end)
BtnMode1.MouseLeave:Connect(function() TweenService:Create(BtnMode1, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(29, 158, 117)}):Play() end)
BtnMode2.MouseEnter:Connect(function() TweenService:Create(BtnMode2, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(100, 110, 120)}):Play() end)
BtnMode2.MouseLeave:Connect(function() TweenService:Create(BtnMode2, TweenInfo.new(0.2), {BackgroundColor3 = Color3.fromRGB(80, 90, 100)}):Play() end)

BtnMode1.MouseButton1Click:Connect(function() StartMenu.Visible = false SetMode:FireServer("Dijkstra") end)
BtnMode2.MouseButton1Click:Connect(function() StartMenu.Visible = false SetMode:FireServer("FreeRoam") end)

-- TOP LEFT: STATS
local StatsPanel = Instance.new("Frame")
StatsPanel.Size = UDim2.new(0, 400, 0, 80)
StatsPanel.Position = UDim2.new(0, 20, 0, 20)
StatsPanel.BackgroundTransparency = 1
StatsPanel.Parent = MainContainer
local UIListLayout = Instance.new("UIListLayout")
UIListLayout.FillDirection = Enum.FillDirection.Horizontal
UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
UIListLayout.Padding = UDim.new(0, 10)
UIListLayout.Parent = StatsPanel

local function createStatCard(labelTxt, color)
	local Card = Instance.new("Frame")
	Card.Size = UDim2.new(0, 90, 1, 0)
	Card.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	Instance.new("UICorner", Card).CornerRadius = UDim.new(0, 10)
	
	local Label = Instance.new("TextLabel")
	Label.Text = labelTxt
	Label.Size = UDim2.new(1, 0, 0.4, 0)
	Label.Position = UDim2.new(0, 0, 0, 5)
	Label.BackgroundTransparency = 1
	Label.TextColor3 = Color3.fromRGB(200, 200, 200)
	Label.Font = Enum.Font.Code
	Label.TextSize = 12
	Label.Parent = Card
	
	local Val = Instance.new("TextLabel")
	Val.Text = "0"
	Val.Size = UDim2.new(1, 0, 0.6, 0)
	Val.Position = UDim2.new(0, 0, 0.4, 0)
	Val.BackgroundTransparency = 1
	Val.TextColor3 = color or Color3.new(1,1,1)
	Val.Font = Enum.Font.GothamBlack
	Val.TextSize = 24
	Val.Parent = Card
	
	Card.Parent = StatsPanel
	return Val
end

local ValCost = createStatCard("SEU CUSTO", Color3.new(1,1,1))
local ValOpt = createStatCard("IDEAL", Color3.fromRGB(29, 158, 117))
local ValPen = createStatCard("PENALIDADE", Color3.fromRGB(216, 90, 48))
local ValRound = createStatCard("RODADA", Color3.fromRGB(55, 138, 221))

-- TOP CENTER: MISSION
local MissionCard = Instance.new("Frame")
MissionCard.Size = UDim2.new(0, 300, 0, 80)
MissionCard.Position = UDim2.new(0.5, -150, 0, 20)
MissionCard.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
Instance.new("UICorner", MissionCard).CornerRadius = UDim.new(0, 10)
MissionCard.Parent = MainContainer

local MLab = Instance.new("TextLabel")
MLab.Text = "MISSÃO ATUAL"
MLab.Size = UDim2.new(1, 0, 0, 20)
MLab.Position = UDim2.new(0, 0, 0, 5)
MLab.BackgroundTransparency = 1
MLab.TextColor3 = Color3.fromRGB(200, 200, 200)
MLab.Font = Enum.Font.Code
MLab.TextSize = 12
MLab.Parent = MissionCard

local MText = Instance.new("TextLabel")
MText.Text = "-"
MText.Size = UDim2.new(1, 0, 0, 30)
MText.Position = UDim2.new(0, 0, 0, 25)
MText.BackgroundTransparency = 1
MText.TextColor3 = Color3.new(1,1,1)
MText.Font = Enum.Font.GothamBold
MText.TextSize = 16
MText.Parent = MissionCard

local MSub = Instance.new("TextLabel")
MSub.Text = "De ? -> Para ?"
MSub.Size = UDim2.new(1, 0, 0, 20)
MSub.Position = UDim2.new(0, 0, 0, 55)
MSub.BackgroundTransparency = 1
MSub.TextColor3 = Color3.fromRGB(210, 210, 210)
MSub.Font = Enum.Font.Code
MSub.TextSize = 12
MSub.TextStrokeTransparency = 0.6
MSub.TextStrokeColor3 = Color3.new(0,0,0)
MSub.Parent = MissionCard

-- TOP RIGHT: MINIMAP
local Minimap = Instance.new("Frame")
Minimap.Size = UDim2.new(0, 300, 0, 300)
Minimap.Position = UDim2.new(1, -320, 0, 20)
Minimap.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
Minimap.ClipsDescendants = true
Instance.new("UICorner", Minimap).CornerRadius = UDim.new(0, 12)
Minimap.Parent = MainContainer

-- BOTTOM CONTROLS
local BottomRow = Instance.new("Frame")
BottomRow.Size = UDim2.new(1, -40, 0, 40)
BottomRow.Position = UDim2.new(0, 20, 1, -60)
BottomRow.BackgroundTransparency = 1
BottomRow.Parent = MainContainer

local BtnRestart = Instance.new("TextButton")
BtnRestart.Text = "↺ Reiniciar Rodada"
BtnRestart.Size = UDim2.new(0, 150, 1, 0)
BtnRestart.Position = UDim2.new(0, 0, 0, 0)
BtnRestart.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
BtnRestart.TextColor3 = Color3.new(1,1,1)
BtnRestart.Font = Enum.Font.Code
BtnRestart.TextSize = 14
Instance.new("UICorner", BtnRestart).CornerRadius = UDim.new(0, 8)
BtnRestart.Parent = BottomRow

local ScoreOut = Instance.new("TextLabel")
ScoreOut.Text = "Pontuação total: 0"
ScoreOut.Size = UDim2.new(0, 200, 1, 0)
ScoreOut.Position = UDim2.new(1, -200, 0, 0)
ScoreOut.BackgroundTransparency = 1
ScoreOut.TextColor3 = Color3.new(1,1,1)
ScoreOut.Font = Enum.Font.Code
ScoreOut.TextXAlignment = Enum.TextXAlignment.Right
ScoreOut.Parent = BottomRow

-- MSG BAR
local MsgBar = Instance.new("Frame")
MsgBar.Size = UDim2.new(0, 500, 0, 40)
MsgBar.Position = UDim2.new(0.5, -250, 0, 110)
MsgBar.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
Instance.new("UICorner", MsgBar).CornerRadius = UDim.new(0, 8)
MsgBar.Parent = MainContainer

local MsgIcon = Instance.new("TextLabel")
MsgIcon.Text = "🏫"
MsgIcon.Size = UDim2.new(0, 40, 1, 0)
MsgIcon.BackgroundTransparency = 1
MsgIcon.Font = Enum.Font.Gotham
MsgIcon.TextSize = 20
MsgIcon.Parent = MsgBar

local MsgTxt = Instance.new("TextLabel")
MsgTxt.Text = "Carregando universidade..."
MsgTxt.Size = UDim2.new(1, -50, 1, 0)
MsgTxt.Position = UDim2.new(0, 40, 0, 0)
MsgTxt.BackgroundTransparency = 1
MsgTxt.TextColor3 = Color3.new(1, 1, 1)
MsgTxt.Font = Enum.Font.Code
MsgTxt.TextSize = 14
MsgTxt.TextXAlignment = Enum.TextXAlignment.Left
MsgTxt.TextStrokeTransparency = 0.5
MsgTxt.TextStrokeColor3 = Color3.new(0, 0, 0)
MsgTxt.Parent = MsgBar

-- PENALTY FLASH
local FlashOverlay = Instance.new("Frame")
FlashOverlay.Size = UDim2.new(1, 0, 1, 0)
FlashOverlay.BackgroundColor3 = Color3.fromRGB(216, 90, 48)
FlashOverlay.BackgroundTransparency = 1
FlashOverlay.ZIndex = 10
FlashOverlay.Parent = ScreenGui

local FlashText = Instance.new("TextLabel")
FlashText.Text = ""
FlashText.Size = UDim2.new(0, 300, 0, 80)
FlashText.Position = UDim2.new(0.5, -150, 0.5, -40)
FlashText.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
FlashText.TextColor3 = Color3.fromRGB(216, 90, 48)
FlashText.Font = Enum.Font.Code
FlashText.TextSize = 30
FlashText.Visible = false
Instance.new("UICorner", FlashText).CornerRadius = UDim.new(0, 10)
Instance.new("UIStroke", FlashText).Color = Color3.fromRGB(216, 90, 48)
Instance.new("UIStroke", FlashText).Thickness = 2
FlashText.Parent = FlashOverlay

-- OVERLAY (redesigned for readability)
local Overlay = Instance.new("Frame")
Overlay.Size = UDim2.new(1, 0, 1, 0)
Overlay.BackgroundColor3 = Color3.new(0, 0, 0)
Overlay.BackgroundTransparency = 0.4           -- slightly darker to focus on the card
Overlay.Visible = false
Overlay.ZIndex = 100
Overlay.Parent = ScreenGui

local OvBox = Instance.new("Frame")
OvBox.Size = UDim2.new(0, 340, 0, 280)
OvBox.Position = UDim2.new(0.5, -170, 0.5, -140)
OvBox.BackgroundColor3 = Color3.fromRGB(245, 245, 248)   -- light card background
OvBox.BorderSizePixel = 0
Instance.new("UICorner", OvBox).CornerRadius = UDim.new(0, 16)
-- Soft shadow effect (stroke)
local shadow = Instance.new("UIStroke")
shadow.Color = Color3.fromRGB(200, 200, 200)
shadow.Thickness = 1
shadow.Transparency = 0.8
shadow.Parent = OvBox
OvBox.Parent = Overlay

local OvIcon = Instance.new("TextLabel")
OvIcon.Text = "🎉"
OvIcon.Size = UDim2.new(1, 0, 0, 60)
OvIcon.Position = UDim2.new(0, 0, 0, 20)
OvIcon.BackgroundTransparency = 1
OvIcon.TextSize = 44
OvIcon.Font = Enum.Font.GothamBold
OvIcon.TextColor3 = Color3.fromRGB(30, 30, 30)
OvIcon.Parent = OvBox

local OvTitle = Instance.new("TextLabel")
OvTitle.Text = "Mission Complete!"
OvTitle.Size = UDim2.new(1, -40, 0, 30)
OvTitle.Position = UDim2.new(0, 20, 0, 80)
OvTitle.BackgroundTransparency = 1
OvTitle.TextColor3 = Color3.fromRGB(20, 20, 20)
OvTitle.Font = Enum.Font.GothamBlack
OvTitle.TextSize = 24
OvTitle.TextWrapped = true
OvTitle.Parent = OvBox

local OvBody = Instance.new("TextLabel")
OvBody.Text = "-"
OvBody.Size = UDim2.new(1, -40, 0, 90)
OvBody.Position = UDim2.new(0, 20, 0, 120)
OvBody.BackgroundTransparency = 1
OvBody.TextColor3 = Color3.fromRGB(60, 60, 60)
OvBody.Font = Enum.Font.GothamMedium
OvBody.TextSize = 15
OvBody.TextWrapped = true
OvBody.LineHeight = 1.2
OvBody.Parent = OvBox

local OvNext = Instance.new("TextButton")
OvNext.Text = "Próxima Rodada →"
OvNext.Size = UDim2.new(0, 180, 0, 44)
OvNext.Position = UDim2.new(0.5, -90, 1, -60)
OvNext.BackgroundColor3 = Color3.fromRGB(29, 158, 117)
OvNext.TextColor3 = Color3.new(1, 1, 1)
OvNext.Font = Enum.Font.GothamBold
OvNext.TextSize = 16
Instance.new("UICorner", OvNext).CornerRadius = UDim.new(0, 10)
OvNext.Parent = OvBox

-- STATE
local gameState = {}
local edgeParts = {}
local minimapNodes = {}
local minX, minZ, maxX, maxZ = 0, 0, 0, 0

local function clearEdges()
	for _, p in ipairs(edgeParts) do
		p:Destroy()
	end
	edgeParts = {}
end

local function getNodeById(id)
	for _, n in ipairs(gameState.nodes or {}) do
		if n.id == id then return n end
	end
end

local function draw3DEdges()
	clearEdges()
	if not gameState.edgeMap then return end
	
	for key, w in pairs(gameState.edgeMap) do
		local parts = string.split(key, "_")
		local uId = tonumber(parts[1])
		local vId = tonumber(parts[2])
		
		local n1 = getNodeById(uId)
		local n2 = getNodeById(vId)
		if n1 and n2 then
			local p1 = Vector3.new(n1.x, n1.y, n1.z)
			local p2 = Vector3.new(n2.x, n2.y, n2.z)
			
			local dist = (p1 - p2).Magnitude
			local edgePart = Instance.new("Part")
			edgePart.Size = Vector3.new(0.5, 0.5, dist)
			edgePart.CFrame = CFrame.lookAt(p1, p2) * CFrame.new(0, 0, -dist/2)
			edgePart.Anchored = true
			edgePart.CanCollide = false
			edgePart.Material = Enum.Material.Neon
			edgePart.Name = "edge_" .. key
			
			local onTrail = false
			if gameState.visited then
				for i = 2, #gameState.visited do
					local a, b = gameState.visited[i-1], gameState.visited[i]
					if (a == uId and b == vId) or (a == vId and b == uId) then
						onTrail = true break
					end
				end
			end
			
			if onTrail then
				edgePart.Color = Color3.fromRGB(55, 138, 221)
				edgePart.Size = Vector3.new(1, 1, dist)
			else
				edgePart.Color = Color3.fromRGB(150, 150, 150)
				edgePart.Transparency = 0.5
			end
			
			edgePart.Parent = Workspace
			table.insert(edgeParts, edgePart)
			
			local bg = Instance.new("BillboardGui")
			bg.Size = UDim2.new(0, 60, 0, 30)
			bg.AlwaysOnTop = true
			
			local txt = Instance.new("TextLabel")
			txt.Size = UDim2.new(1, 0, 1, 0)
			txt.BackgroundTransparency = 0.2
			txt.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
			txt.TextColor3 = Color3.new(1,1,1)
			txt.Font = Enum.Font.Code
			txt.TextSize = 24
			txt.Text = tostring(w)
			Instance.new("UICorner", txt).CornerRadius = UDim.new(0, 4)
			txt.Parent = bg
			
			bg.Parent = edgePart
			edgePart.Parent = Workspace
		end
	end
end

local minimapMinX, minimapMinZ = 0, 0
local minimapRangeX, minimapRangeZ = 1, 1

local PlayerIcon = Instance.new("Frame")
PlayerIcon.Name = "PlayerIcon"
PlayerIcon.BackgroundTransparency = 1
PlayerIcon.Size = UDim2.new(0, 12, 0, 12)
PlayerIcon.ZIndex = 6
PlayerIcon.Parent = Minimap

local hHead = Instance.new("Frame")
hHead.BackgroundColor3 = Color3.fromRGB(245, 205, 47)
hHead.Size = UDim2.new(0, 8, 0, 8)
hHead.Position = UDim2.new(0.5, 0, 0, -4)
hHead.AnchorPoint = Vector2.new(0.5, 0)
Instance.new("UICorner", hHead).CornerRadius = UDim.new(1,0)
hHead.Parent = PlayerIcon

local hTorso = Instance.new("Frame")
hTorso.BackgroundColor3 = Color3.fromRGB(13, 105, 172)
hTorso.Size = UDim2.new(0, 12, 0, 10)
hTorso.Position = UDim2.new(0.5, 0, 0, 4)
hTorso.AnchorPoint = Vector2.new(0.5, 0)
hTorso.Parent = PlayerIcon

local hLeftArm = Instance.new("Frame")
hLeftArm.BackgroundColor3 = Color3.fromRGB(245, 205, 47)
hLeftArm.Size = UDim2.new(0, 4, 0, 10)
hLeftArm.Position = UDim2.new(0.5, -8, 0, 4)
hLeftArm.AnchorPoint = Vector2.new(0.5, 0)
hLeftArm.Parent = PlayerIcon

local hRightArm = Instance.new("Frame")
hRightArm.BackgroundColor3 = Color3.fromRGB(245, 205, 47)
hRightArm.Size = UDim2.new(0, 4, 0, 10)
hRightArm.Position = UDim2.new(0.5, 8, 0, 4)
hRightArm.AnchorPoint = Vector2.new(0.5, 0)
hRightArm.Parent = PlayerIcon

local hLegs = Instance.new("Frame")
hLegs.BackgroundColor3 = Color3.fromRGB(75, 151, 75)
hLegs.Size = UDim2.new(0, 12, 0, 8)
hLegs.Position = UDim2.new(0.5, 0, 0, 14)
hLegs.AnchorPoint = Vector2.new(0.5, 0)
hLegs.Parent = PlayerIcon

local function drawMinimap()
	for _, c in ipairs(Minimap:GetChildren()) do
		if not c:IsA("UICorner") and c.Name ~= "PlayerIcon" then c:Destroy() end
	end
	
	if not gameState.nodes then return end
	
	local minX, minZ = math.huge, math.huge
	local maxX, maxZ = -math.huge, -math.huge
	for _, n in ipairs(gameState.nodes) do
		if n.x < minX then minX = n.x end
		if n.x > maxX then maxX = n.x end
		if n.z < minZ then minZ = n.z end
		if n.z > maxZ then maxZ = n.z end
	end
	
	minX = minX - 20
	maxX = maxX + 20
	minZ = minZ - 20
	maxZ = maxZ + 20
	
	local rangeX = maxX - minX
	local rangeZ = maxZ - minZ
	if rangeX <= 0 then rangeX = 1 end
	if rangeZ <= 0 then rangeZ = 1 end
	
	minimapMinX = minX
	minimapMinZ = minZ
	minimapRangeX = rangeX
	minimapRangeZ = rangeZ
	
	if gameState.edgeMap then
		for key, w in pairs(gameState.edgeMap) do
			local parts = string.split(key, "_")
			local uId = tonumber(parts[1])
			local vId = tonumber(parts[2])
			
			local n1 = getNodeById(uId)
			local n2 = getNodeById(vId)
			if n1 and n2 then
				local p1x = (n1.x - minX) / rangeX
				local p1z = (n1.z - minZ) / rangeZ
				local p2x = (n2.x - minX) / rangeX
				local p2z = (n2.z - minZ) / rangeZ
				
				local line = Instance.new("Frame")
				line.Name = "edge_" .. key
				line.BackgroundColor3 = Color3.fromRGB(150, 150, 150)
				line.BorderSizePixel = 0
				
				local onTrail = false
				if gameState.visited then
					for i = 2, #gameState.visited do
						local a, b = gameState.visited[i-1], gameState.visited[i]
						if (a == uId and b == vId) or (a == vId and b == uId) then onTrail = true break end
					end
				end
				
				local thickness = 1
				if onTrail then
					line.BackgroundColor3 = Color3.fromRGB(55, 138, 221)
					thickness = 3
					line.ZIndex = 2
				else
					line.BackgroundTransparency = 0.5
					thickness = 1
					line.ZIndex = 1
				end
				
				local dx = p2x - p1x
				local dz = p2z - p1z
				local mag = math.sqrt(dx*dx + dz*dz) * Minimap.Size.X.Offset
				local angle = math.deg(math.atan2(dz, dx))
				
				line.Size = UDim2.new(0, mag, 0, thickness)
				line.Position = UDim2.new((p1x + p2x)/2, 0, (p1z + p2z)/2, 0)
				line.AnchorPoint = Vector2.new(0.5, 0.5)
				line.Rotation = angle
				line.Parent = Minimap
				
				local costLbl = Instance.new("TextLabel")
				costLbl.Size = UDim2.new(0, 16, 0, 12)
				costLbl.Position = UDim2.new((p1x + p2x)/2, 0, (p1z + p2z)/2, 0)
				costLbl.AnchorPoint = Vector2.new(0.5, 0.5)
				costLbl.Text = tostring(w)
				costLbl.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
				costLbl.TextColor3 = Color3.new(1,1,1)
				costLbl.Font = Enum.Font.Code
				costLbl.TextSize = 10
				costLbl.ZIndex = 3
				Instance.new("UICorner", costLbl).CornerRadius = UDim.new(0, 3)
				costLbl.Parent = Minimap
			end
		end
	end
	
	for _, n in ipairs(gameState.nodes) do
		local px = (n.x - minX) / rangeX
		local pz = (n.z - minZ) / rangeZ
		
		local dot = Instance.new("Frame")
		dot.Size = UDim2.new(0, 10, 0, 10)
		dot.Position = UDim2.new(px, 0, pz, 0)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.ZIndex = 4
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1,0)
		
		if gameState.playerPos == n.id then
			dot.BackgroundColor3 = Color3.fromRGB(245, 205, 47)
			dot.Size = UDim2.new(0, 14, 0, 14)
		elseif gameState.dst == n.id then
			dot.BackgroundColor3 = Color3.fromRGB(80, 255, 120)
			dot.Size = UDim2.new(0, 12, 0, 12)
		else
			dot.BackgroundColor3 = Color3.fromRGB(55, 138, 221)
			dot.Size = UDim2.new(0, 10, 0, 10)
		end
		
		dot.Parent = Minimap
		
		local dotLabel = Instance.new("TextLabel")
		dotLabel.Text = n.name
		dotLabel.Size = UDim2.new(0, 40, 0, 12)
		dotLabel.Position = UDim2.new(0.5, 0, 1, 2)
		dotLabel.AnchorPoint = Vector2.new(0.5, 0)
		dotLabel.BackgroundTransparency = 1
		dotLabel.TextColor3 = Color3.new(1, 1, 1)
		dotLabel.Font = Enum.Font.Code
		dotLabel.TextSize = 10
		dotLabel.ZIndex = 5
		dotLabel.Parent = dot
	end
end

local activeHighlights = {}

local function clearHighlights()
	for _, hl in ipairs(activeHighlights) do hl:Destroy() end
	activeHighlights = {}
end

local function applyNeighborHighlights()
	clearHighlights()
	if not gameState.adj or not gameState.playerPos then return end
	
	local neighbors = gameState.adj[gameState.playerPos]
	if not neighbors then return end
	
	for _, edge in ipairs(neighbors) do
		local isVisited = false
		if gameState.visited then
			for _, v in ipairs(gameState.visited) do
				if v == edge.v then isVisited = true break end
			end
		end
		
		if not isVisited then
			local n = getNodeById(edge.v)
			if n and n.partName then
				-- WaitForChild ensures the part is fully replicated
				local part = NodesFolder:WaitForChild(n.partName, 5)
				if not part then continue end
				
				local hl = Instance.new("Highlight")
				hl.Adornee = part
				hl.FillTransparency = 1
				hl.OutlineColor = Color3.new(1, 1, 1)
				hl.OutlineTransparency = 0
				hl.Parent = part
				table.insert(activeHighlights, hl)
				
				game:GetService("TweenService"):Create(hl, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {OutlineTransparency = 0.8}):Play()
			end
		end
	end
end

local activePrompts = {}

local function clearPrompts()
	for _, p in ipairs(activePrompts) do p:Destroy() end
	activePrompts = {}
end

local function applyPrompts()
	clearPrompts()
	if not gameState.playerPos then return end
	
	if gameState.mode == "FreeRoam" then
		for _, n in ipairs(gameState.nodes) do
			if n.id ~= gameState.playerPos then
				-- WaitForChild ensures the part is fully replicated
				local part = NodesFolder:WaitForChild(n.partName, 5)
				if not part then continue end
				
				local prompt = Instance.new("ProximityPrompt")
				prompt.ActionText = "Teleportar para"
				prompt.ObjectText = n.name
				prompt.KeyboardKeyCode = Enum.KeyCode.E
				prompt.MaxActivationDistance = 45
				prompt.RequiresLineOfSight = false
				prompt.Parent = part
				
				prompt.Triggered:Connect(function()
					MoveRequest:FireServer(n.id)
				end)
				table.insert(activePrompts, prompt)
			end
		end
		return
	end
	
	local neighbors = gameState.adj and gameState.adj[gameState.playerPos]
	if not neighbors then return end
	
	for _, edge in ipairs(neighbors) do
		local isVisited = false
		if gameState.visited then
			for _, v in ipairs(gameState.visited) do
				if v == edge.v then isVisited = true break end
			end
		end
		
		if not isVisited then
			local n = getNodeById(edge.v)
			if n and n.partName then
				-- WaitForChild ensures the part is fully replicated
				local part = NodesFolder:WaitForChild(n.partName, 5)
				if not part then continue end
				
				local prompt = Instance.new("ProximityPrompt")
				prompt.ActionText = "Ir (Custo: " .. edge.w .. ")"
				prompt.ObjectText = n.name
				prompt.KeyboardKeyCode = Enum.KeyCode.E
				prompt.MaxActivationDistance = 45
				prompt.RequiresLineOfSight = false
				prompt.Parent = part
				
				prompt.Triggered:Connect(function()
					MoveRequest:FireServer(n.id)
				end)
				table.insert(activePrompts, prompt)
			end
		end
	end
end

UpdateUI.OnClientEvent:Connect(function(data)
	gameState = data
	
	if gameState.mode == "Menu" then
		StartMenu.Visible = true
		MainContainer.Visible = false
		Overlay.Visible = false
		return
	end
	
	MainContainer.Visible = true
	StartMenu.Visible = false
	
	if gameState.mode == "FreeRoam" then
		StatsPanel.Visible = false
		MissionCard.Visible = false
		MsgBar.Visible = false
		drawMinimap()
		return
	end
	
	StatsPanel.Visible = true
	MissionCard.Visible = true
	MsgBar.Visible = true
	
	ValCost.Text = tostring(gameState.playerCost or 0)
	ValOpt.Text = tostring(gameState.optimalCost or "?")
	ValPen.Text = "+" .. tostring(gameState.penaltyTotal or 0)
	ValRound.Text = tostring(gameState.roundNum or 1)
	ScoreOut.Text = "Pontuação total: " .. tostring(gameState.totalScore or 0)
	
	if gameState.mission then
		local srcNode = getNodeById(gameState.src)
		local dstNode = getNodeById(gameState.dst)
		local currNode = getNodeById(gameState.playerPos)
		MText.Text = gameState.mission.emoji .. " " .. gameState.mission.verb .. " " .. dstNode.name
		MSub.Text = string.format("De: %s %s  ->  Para: %s %s", srcNode.name, srcNode.emoji, dstNode.name, dstNode.emoji)
		
		local unvisCount = 0
		if gameState.adj and gameState.playerPos then
			local neighbors = gameState.adj[gameState.playerPos]
			if neighbors then
				for _, edge in ipairs(neighbors) do
					local isVisited = false
					if gameState.visited then
						for _, v in ipairs(gameState.visited) do
							if v == edge.v then isVisited = true break end
						end
					end
					if not isVisited then unvisCount = unvisCount + 1 end
				end
			end
		end
		
		if unvisCount == 0 and gameState.playerPos ~= gameState.dst then
			MsgIcon.Text = "🚫"
			MsgTxt.Text = "Beco sem saída - sem vizinhos não visitados. Reinicie a rodada."
		else
			MsgIcon.Text = "📍"
			MsgTxt.Text = string.format("Você está no(a) %s %s. Missão: %s %s %s.",
				currNode.emoji, currNode.name, gameState.mission.emoji, gameState.mission.verb, dstNode.name)
		end
	end
	
	applyNeighborHighlights()
	applyPrompts()
	
	draw3DEdges()
	drawMinimap()
	Overlay.Visible = false
end)

PenaltyFlash.OnClientEvent:Connect(function(pen)
	FlashText.Text = "+" .. tostring(pen) .. " penalidade!"
	FlashText.Visible = true
	FlashOverlay.BackgroundTransparency = 0.8
	
	local ts = TweenService:Create(FlashOverlay, TweenInfo.new(0.8), {BackgroundTransparency = 1})
	ts:Play()
	task.delay(0.8, function() FlashText.Visible = false end)
end)

RoundEnd.OnClientEvent:Connect(function(res)
	OvIcon.Text = res.perfect and "🏆" or (res.diff <= 20 and "🎯" or "📚")
	OvTitle.Text = res.perfect and "Caminho Perfeito!" or "Missão Cumprida!"
	OvBody.Text = string.format("Seu custo: %d | Ideal: %d\nPenalidade: +%d\nPontuação da rodada: %d\n\n%s",
		res.playerCost, res.optimalCost, res.penaltyTotal, res.roundScore,
		res.perfect and "Você seguiu o caminho exato de Dijkstra! 🧠" or (res.diff == 0 and "Custo ideal, mas deu algumas voltas!" or "Você pagou " .. res.diff .. " a mais. Tente o caminho mais barato!"))
	
	Overlay.Visible = true
	
	if gameState.optimalPath then
		for i = 1, #gameState.optimalPath - 1 do
			local u = gameState.optimalPath[i]
			local v = gameState.optimalPath[i+1]
			local k = string.format("%d_%d", math.min(u, v), math.max(u, v))
			
			local mLine = Minimap:FindFirstChild("edge_" .. k)
			if mLine then
				mLine.BackgroundColor3 = Color3.fromRGB(255, 215, 0)
				mLine.ZIndex = 5
			end
			
			local wLine = Workspace:FindFirstChild("edge_" .. k)
			if wLine then
				wLine.Color = Color3.fromRGB(255, 215, 0)
			end
		end
	end
end)

BtnRestart.MouseButton1Click:Connect(function()
	RestartRound:FireServer()
end)

OvNext.MouseButton1Click:Connect(function()
	NextRound:FireServer()
end)

game:GetService("RunService").RenderStepped:Connect(function()
	local char = player.Character
	if not char then return end
	
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return end
	
	local px = (root.Position.X - minimapMinX) / minimapRangeX
	local pz = (root.Position.Z - minimapMinZ) / minimapRangeZ
	PlayerIcon.Position = UDim2.new(px, 0, pz, 0)
end)