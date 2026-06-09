local Players          = game:GetService("Players")
local ReplicatedStorage= game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local TweenService     = game:GetService("TweenService")
local Workspace        = game:GetService("Workspace")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Events    = ReplicatedStorage:WaitForChild("Events")

local MoveRequest  = Events:WaitForChild("MoveRequest")
local RestartRound = Events:WaitForChild("RestartRound")
local NextRound    = Events:WaitForChild("NextRound")
local UpdateUI     = Events:WaitForChild("UpdateUI")
local PenaltyFlash = Events:WaitForChild("PenaltyFlash")
local RoundEnd     = Events:WaitForChild("RoundEnd")
local SetMode      = Events:WaitForChild("SetMode")
local PlaySound    = Events:WaitForChild("PlaySound")

local NodesFolder = Workspace:WaitForChild("Nodes")

-- ============================================================
--  FORWARD DECLARATIONS  (all shared state at top)
-- ============================================================
local gameState        = {}
local edgeParts        = {}
local minimapMinX      = 0
local minimapMinZ      = 0
local minimapRangeX    = 1
local minimapRangeZ    = 1
local pathHistory      = {}
local activeHighlights = {}
local activePrompts    = {}
local timerDuration    = 60
local timerRemaining   = 0
local timerActive      = false

-- UI elements forward-declared so every closure below captures the same upvalue
local ScreenGui, MainContainer, StartMenu
local StatsPanel, MissionCard, MsgBar, MsgIcon, MsgTxt
local TimerBar, TimerLabel, TimerFill
local Minimap, PlayerIcon
local FlashOverlay, FlashText
local Overlay, OvBox, OvIcon, OvTitle, OvBody, OvNext
local FailOverlay, FailRestartBtn
local PathPanel, PathScroll
local ValCost, ValOpt, ValPen, ValRound, ScoreOut
local BtnRestart

-- ============================================================
--  TIMER CONSTANTS
-- ============================================================
local TIMER_BASE_SECS     = 20
local TIMER_SECS_PER_EDGE = 15

-- ============================================================
--  SCREENGUI
-- ============================================================
ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name         = "DijkstraUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent       = playerGui

local uiScale = Instance.new("UIScale")
uiScale.Scale  = 1
uiScale.Parent = ScreenGui

local function refreshUIScale()
	local vp    = Workspace.CurrentCamera.ViewportSize
	local scale = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.50, 1.0)
	uiScale.Scale = scale
end
Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refreshUIScale)
task.defer(refreshUIScale)

-- ============================================================
--  SOUNDS
-- ============================================================
local sounds = {
	RightNode = Instance.new("Sound"),
	Success   = Instance.new("Sound"),
	Fail      = Instance.new("Sound"),
	Oof       = Instance.new("Sound"),
}
sounds.RightNode.SoundId = "rbxassetid://876939830";  sounds.RightNode.Volume = 0.5
sounds.Success.SoundId   = "rbxassetid://2865227271"; sounds.Success.Volume   = 0.8
sounds.Fail.SoundId      = "rbxassetid://12222242";   sounds.Fail.Volume      = 0.8
sounds.Oof.SoundId       = "rbxassetid://12222242";   sounds.Oof.Volume       = 0.6
for _, s in pairs(sounds) do s.Parent = ScreenGui end

local ambiance = Instance.new("Sound")
ambiance.SoundId = "rbxassetid://4630467570"
ambiance.Looped  = true
ambiance.Volume  = 0.15
ambiance.Parent  = Workspace
ambiance:Play()

-- ============================================================
--  VISUAL EFFECTS
-- ============================================================
local function CreateFloatingText(text, color, position)
	local part = Instance.new("Part")
	part.Size        = Vector3.new(1,1,1)
	part.Position    = position
	part.Anchored    = true
	part.CanCollide  = false
	part.Transparency = 1
	part.Parent      = Workspace
	local bg = Instance.new("BillboardGui")
	bg.Size        = UDim2.new(0, 200, 0, 50)
	bg.StudsOffset = Vector3.new(0, 5, 0)
	bg.AlwaysOnTop = true
	bg.Parent      = part
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.new(1,0,1,0)
	tl.BackgroundTransparency = 1
	tl.Text  = text
	tl.TextColor3 = color
	tl.TextStrokeTransparency = 0.3
	tl.TextStrokeColor3 = Color3.new(0,0,0)
	tl.TextScaled = true
	tl.Font  = Enum.Font.GothamBlack
	tl.Parent = bg
	TweenService:Create(bg, TweenInfo.new(1.2, Enum.EasingStyle.Back,  Enum.EasingDirection.Out), {StudsOffset = Vector3.new(0,9,0)}):Play()
	TweenService:Create(tl, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),  {TextTransparency=1, TextStrokeTransparency=1}):Play()
	game.Debris:AddItem(part, 1.5)
end

local function CreatePulse(position)
	local part = Instance.new("Part")
	part.Shape       = Enum.PartType.Cylinder
	part.Size        = Vector3.new(0.2,2,2)
	part.CFrame      = CFrame.new(position) * CFrame.Angles(0,0,math.pi/2)
	part.Color       = Color3.fromRGB(80,255,120)
	part.Material    = Enum.Material.Neon
	part.Anchored    = true
	part.CanCollide  = false
	part.Transparency = 0.2
	part.Parent      = Workspace
	TweenService:Create(part, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{Size=Vector3.new(0.2,20,20), Transparency=1}):Play()
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
	local headPos = (char:FindFirstChild("Head") and char.Head.Position) or (rootPos + Vector3.new(0,2,0))
	if sType == "RightNode" then
		local f = Instance.new("Frame")
		f.Size = UDim2.new(1,0,1,0)
		f.BackgroundColor3 = Color3.fromRGB(100,255,150)
		f.BackgroundTransparency = 0.85
		f.ZIndex = 0
		f.Parent = ScreenGui
		TweenService:Create(f, TweenInfo.new(0.5, Enum.EasingStyle.Cubic), {BackgroundTransparency=1}):Play()
		game.Debris:AddItem(f, 0.6)
		CreateFloatingText("✔️ CERTO!", Color3.fromRGB(80,255,120), headPos)
		CreatePulse(rootPos - Vector3.new(0,2.5,0))
	elseif sType == "Success" then
		CreateFloatingText("🌟 MISSÃO PERFEITA! 🌟", Color3.fromRGB(255,215,0), headPos + Vector3.new(0,2,0))
	elseif sType == "Fail" then
		CreateFloatingText("❌ TENTE DE NOVO!", Color3.fromRGB(255,80,80), headPos + Vector3.new(0,2,0))
	elseif sType == "Oof" then
		CreateFloatingText("⚠️ PENALIDADE!", Color3.fromRGB(255,100,50), headPos + Vector3.new(math.random(-2,2),0,math.random(-2,2)))
	end
end)

-- ============================================================
--  MAIN CONTAINER
-- ============================================================
MainContainer = Instance.new("Frame")
MainContainer.Size = UDim2.new(1,0,1,0)
MainContainer.BackgroundTransparency = 1
MainContainer.Visible = false
MainContainer.Parent  = ScreenGui

-- ============================================================
--  START MENU
-- ============================================================
StartMenu = Instance.new("Frame")
StartMenu.Size = UDim2.new(1,0,1,0)
StartMenu.BackgroundColor3 = Color3.new(1,1,1)
StartMenu.Parent = ScreenGui
local UIGradient = Instance.new("UIGradient")
UIGradient.Color = ColorSequence.new{
	ColorSequenceKeypoint.new(0, Color3.fromRGB(15,23,42)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(30,41,59)),
}
UIGradient.Rotation = 45
UIGradient.Parent   = StartMenu

local function makeLabel(parent, text, font, size, color, pos, sz, zIdx)
	local l = Instance.new("TextLabel")
	l.Text   = text; l.Font = font; l.TextSize = size
	l.TextColor3 = color; l.Position = pos; l.Size = sz
	l.BackgroundTransparency = 1; l.ZIndex = zIdx or 1
	l.Parent = parent
	return l
end
makeLabel(StartMenu, "Universidade Dijkstra", Enum.Font.GothamBlack, 56,
	Color3.new(1,1,1), UDim2.new(0,0,0.2,0), UDim2.new(1,0,0,120), 2)
makeLabel(StartMenu, "Universidade Dijkstra", Enum.Font.GothamBlack, 56,
	Color3.fromRGB(55,138,221), UDim2.new(0,4,0.2,4), UDim2.new(1,0,0,120), 1)
makeLabel(StartMenu, "Aprenda Grafos Jogando!", Enum.Font.GothamMedium, 24,
	Color3.fromRGB(200,200,200), UDim2.new(0,0,0.2,80), UDim2.new(1,0,0,40))

local function makeMenuBtn(text, bgColor, posY)
	local btn = Instance.new("TextButton")
	btn.Text = text; btn.Font = Enum.Font.GothamBold
	btn.TextSize = 24; btn.TextColor3 = Color3.new(1,1,1)
	btn.BackgroundColor3 = bgColor
	btn.Size = UDim2.new(0,300,0,65)
	btn.Position = UDim2.new(0.5,-150,0.5,posY)
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0,12)
	btn.Parent = StartMenu
	return btn
end
local BtnMode1 = makeMenuBtn("Modo Dijkstra", Color3.fromRGB(29,158,117), -30)
local BtnMode2 = makeMenuBtn("Modo Livre",    Color3.fromRGB(80,90,100),   60)
BtnMode1.MouseEnter:Connect(function() TweenService:Create(BtnMode1,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(39,188,137)}):Play() end)
BtnMode1.MouseLeave:Connect(function() TweenService:Create(BtnMode1,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(29,158,117)}):Play() end)
BtnMode2.MouseEnter:Connect(function() TweenService:Create(BtnMode2,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(100,110,120)}):Play() end)
BtnMode2.MouseLeave:Connect(function() TweenService:Create(BtnMode2,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(80,90,100)}):Play() end)
BtnMode1.MouseButton1Click:Connect(function() StartMenu.Visible = false; SetMode:FireServer("Dijkstra") end)
BtnMode2.MouseButton1Click:Connect(function() StartMenu.Visible = false; SetMode:FireServer("FreeRoam") end)

-- ============================================================
--  STATS PANEL  (top left)
-- ============================================================
StatsPanel = Instance.new("Frame")
StatsPanel.Size = UDim2.new(0,400,0,80)
StatsPanel.Position = UDim2.new(0,20,0,20)
StatsPanel.BackgroundTransparency = 1
StatsPanel.Parent = MainContainer
local statList = Instance.new("UIListLayout")
statList.FillDirection = Enum.FillDirection.Horizontal
statList.SortOrder     = Enum.SortOrder.LayoutOrder
statList.Padding       = UDim.new(0,10)
statList.Parent        = StatsPanel

local function createStatCard(labelTxt, color)
	local Card = Instance.new("Frame")
	Card.Size = UDim2.new(0,90,1,0)
	Card.BackgroundColor3 = Color3.fromRGB(40,40,40)
	Instance.new("UICorner", Card).CornerRadius = UDim.new(0,10)
	local Lbl = Instance.new("TextLabel")
	Lbl.Text = labelTxt; Lbl.Size = UDim2.new(1,0,0.4,0)
	Lbl.Position = UDim2.new(0,0,0,5); Lbl.BackgroundTransparency = 1
	Lbl.TextColor3 = Color3.fromRGB(200,200,200)
	Lbl.Font = Enum.Font.Code; Lbl.TextSize = 12; Lbl.Parent = Card
	local Val = Instance.new("TextLabel")
	Val.Text = "0"; Val.Size = UDim2.new(1,0,0.6,0)
	Val.Position = UDim2.new(0,0,0.4,0); Val.BackgroundTransparency = 1
	Val.TextColor3 = color or Color3.new(1,1,1)
	Val.Font = Enum.Font.GothamBlack; Val.TextSize = 24; Val.Parent = Card
	Card.Parent = StatsPanel
	return Val
end
ValCost  = createStatCard("SEU CUSTO",  Color3.new(1,1,1))
ValOpt   = createStatCard("IDEAL",      Color3.fromRGB(29,158,117))
ValPen   = createStatCard("PENALIDADE", Color3.fromRGB(216,90,48))
ValRound = createStatCard("RODADA",     Color3.fromRGB(55,138,221))

-- ============================================================
--  MISSION CARD  (top center)
-- ============================================================
MissionCard = Instance.new("Frame")
MissionCard.Size = UDim2.new(0,300,0,80)
MissionCard.Position = UDim2.new(0.5,-150,0,20)
MissionCard.BackgroundColor3 = Color3.fromRGB(40,40,40)
Instance.new("UICorner", MissionCard).CornerRadius = UDim.new(0,10)
MissionCard.Parent = MainContainer
makeLabel(MissionCard,"MISSÃO ATUAL",Enum.Font.Code,12,Color3.fromRGB(200,200,200),UDim2.new(0,0,0,5),UDim2.new(1,0,0,20))
local MText = makeLabel(MissionCard,"-",Enum.Font.GothamBold,16,Color3.new(1,1,1),UDim2.new(0,0,0,25),UDim2.new(1,0,0,30))
local MSub  = makeLabel(MissionCard,"De ? -> Para ?",Enum.Font.Code,12,Color3.fromRGB(210,210,210),UDim2.new(0,0,0,55),UDim2.new(1,0,0,20))
MSub.TextStrokeTransparency = 0.6; MSub.TextStrokeColor3 = Color3.new(0,0,0)

-- ============================================================
--  COUNTDOWN TIMER  (below mission card)
-- ============================================================
TimerBar = Instance.new("Frame")
TimerBar.Name = "TimerBar"
TimerBar.Size = UDim2.new(0,300,0,42)
TimerBar.Position = UDim2.new(0.5,-150,0,108)
TimerBar.BackgroundColor3 = Color3.fromRGB(35,35,42)
TimerBar.BorderSizePixel  = 0
Instance.new("UICorner", TimerBar).CornerRadius = UDim.new(0,10)
TimerBar.Visible = false
TimerBar.Parent  = MainContainer

TimerLabel = Instance.new("TextLabel")
TimerLabel.Size = UDim2.new(1,0,0,26)
TimerLabel.Position = UDim2.new(0,0,0,3)
TimerLabel.BackgroundTransparency = 1
TimerLabel.TextColor3 = Color3.fromRGB(80,220,80)
TimerLabel.Font = Enum.Font.GothamBlack
TimerLabel.TextSize = 18
TimerLabel.Text = "⏱ -"
TimerLabel.Parent = TimerBar

local TimerTrack = Instance.new("Frame")
TimerTrack.Size = UDim2.new(1,-16,0,7)
TimerTrack.Position = UDim2.new(0,8,1,-12)
TimerTrack.BackgroundColor3 = Color3.fromRGB(60,60,68)
TimerTrack.BorderSizePixel  = 0
Instance.new("UICorner", TimerTrack).CornerRadius = UDim.new(1,0)
TimerTrack.Parent = TimerBar

TimerFill = Instance.new("Frame")
TimerFill.Size = UDim2.new(1,0,1,0)
TimerFill.BackgroundColor3 = Color3.fromRGB(80,220,80)
TimerFill.BorderSizePixel  = 0
Instance.new("UICorner", TimerFill).CornerRadius = UDim.new(1,0)
TimerFill.Parent = TimerTrack

local function timerColor(pct)
	if pct > 0.5 then
		local t = (pct-0.5)/0.5
		return Color3.fromRGB(math.floor(255*(1-t)+80*t), 220, math.floor(80*t))
	elseif pct > 0.25 then
		local t = (pct-0.25)/0.25
		return Color3.fromRGB(255, math.floor(165*t+80*(1-t)), 0)
	else
		local t = pct/0.25
		return Color3.fromRGB(255, math.floor(80*t), 0)
	end
end

local function startTimer(numEdges)
	timerDuration  = TIMER_BASE_SECS + TIMER_SECS_PER_EDGE * math.max(1, numEdges)
	timerRemaining = timerDuration
	timerActive    = true
	TimerBar.Visible = true
	local col = timerColor(1)
	TimerLabel.TextColor3      = col
	TimerFill.BackgroundColor3 = col
	TimerFill.Size = UDim2.new(1,0,1,0)
	TimerLabel.Text = "⏱ " .. tostring(math.ceil(timerRemaining))
end

local function stopTimer()
	timerActive      = false
	TimerBar.Visible = false
end

-- ============================================================
--  MINIMAP  (top right)
-- ============================================================
Minimap = Instance.new("Frame")
Minimap.Size = UDim2.new(0,300,0,300)
Minimap.Position = UDim2.new(1,-320,0,20)
Minimap.BackgroundColor3 = Color3.fromRGB(30,30,30)
Minimap.ClipsDescendants = true
Instance.new("UICorner", Minimap).CornerRadius = UDim.new(0,12)
Minimap.Parent = MainContainer

PlayerIcon = Instance.new("Frame")
PlayerIcon.Name = "PlayerIcon"
PlayerIcon.BackgroundTransparency = 1
PlayerIcon.Size  = UDim2.new(0,12,0,12)
PlayerIcon.ZIndex = 6
PlayerIcon.Parent = Minimap

local function addIconPart(color, sz, pos)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = color; f.Size = sz; f.Position = pos
	f.BorderSizePixel = 0; f.Parent = PlayerIcon
end
addIconPart(Color3.fromRGB(245,205,47), UDim2.new(0,8,0,8),   UDim2.new(0.5,0,0,-4))
addIconPart(Color3.fromRGB(13,105,172), UDim2.new(0,12,0,10), UDim2.new(0.5,0,0,4))
addIconPart(Color3.fromRGB(245,205,47), UDim2.new(0,4,0,10),  UDim2.new(0.5,-8,0,4))
addIconPart(Color3.fromRGB(245,205,47), UDim2.new(0,4,0,10),  UDim2.new(0.5,8,0,4))
addIconPart(Color3.fromRGB(75,151,75),  UDim2.new(0,12,0,8),  UDim2.new(0.5,0,0,14))

-- ============================================================
--  BOTTOM ROW
-- ============================================================
local BottomRow = Instance.new("Frame")
BottomRow.Size = UDim2.new(1,-40,0,40)
BottomRow.Position = UDim2.new(0,20,1,-60)
BottomRow.BackgroundTransparency = 1
BottomRow.Parent = MainContainer

BtnRestart = Instance.new("TextButton")
BtnRestart.Text = "↺ Reiniciar Rodada"
BtnRestart.Size = UDim2.new(0,150,1,0)
BtnRestart.Position = UDim2.new(0,0,0,0)
BtnRestart.BackgroundColor3 = Color3.fromRGB(50,50,50)
BtnRestart.TextColor3 = Color3.new(1,1,1)
BtnRestart.Font = Enum.Font.Code
BtnRestart.TextSize = 14
Instance.new("UICorner", BtnRestart).CornerRadius = UDim.new(0,8)
BtnRestart.Parent = BottomRow

ScoreOut = Instance.new("TextLabel")
ScoreOut.Text = "Pontuação total: 0"
ScoreOut.Size = UDim2.new(0,200,1,0)
ScoreOut.Position = UDim2.new(1,-200,0,0)
ScoreOut.BackgroundTransparency = 1
ScoreOut.TextColor3 = Color3.new(1,1,1)
ScoreOut.Font = Enum.Font.Code
ScoreOut.TextXAlignment = Enum.TextXAlignment.Right
ScoreOut.Parent = BottomRow

-- ============================================================
--  PATH HISTORY PANEL  (bottom right)
-- ============================================================
local MAX_HISTORY_LINES = 7
local LINE_HEIGHT       = 17

PathPanel = Instance.new("Frame")
PathPanel.AnchorPoint = Vector2.new(1,1)
PathPanel.Size = UDim2.new(0,215,0,30)
PathPanel.Position = UDim2.new(1,-175,1,-65)
PathPanel.BackgroundColor3 = Color3.fromRGB(20,20,26)
PathPanel.BackgroundTransparency = 0.15
PathPanel.BorderSizePixel = 0
Instance.new("UICorner", PathPanel).CornerRadius = UDim.new(0,10)
PathPanel.ClipsDescendants = true
PathPanel.Visible = false
PathPanel.ZIndex  = 5
PathPanel.Parent  = MainContainer

local PathTitle = Instance.new("TextLabel")
PathTitle.Text = "📍 HISTÓRICO"
PathTitle.Size = UDim2.new(1,-10,0,20)
PathTitle.Position = UDim2.new(0,8,0,3)
PathTitle.BackgroundTransparency = 1
PathTitle.TextColor3 = Color3.fromRGB(160,160,170)
PathTitle.Font = Enum.Font.Code; PathTitle.TextSize = 11
PathTitle.TextXAlignment = Enum.TextXAlignment.Left
PathTitle.ZIndex = 6; PathTitle.Parent = PathPanel

local PathDivider = Instance.new("Frame")
PathDivider.Size = UDim2.new(1,-16,0,1)
PathDivider.Position = UDim2.new(0,8,0,24)
PathDivider.BackgroundColor3 = Color3.fromRGB(80,80,90)
PathDivider.BorderSizePixel  = 0
PathDivider.ZIndex = 6; PathDivider.Parent = PathPanel

PathScroll = Instance.new("ScrollingFrame")
PathScroll.Size = UDim2.new(1,0,1,-28)
PathScroll.Position = UDim2.new(0,0,0,28)
PathScroll.BackgroundTransparency = 1
PathScroll.BorderSizePixel    = 0
PathScroll.ScrollBarThickness = 3
PathScroll.ScrollBarImageColor3 = Color3.fromRGB(100,100,120)
PathScroll.CanvasSize = UDim2.new(0,0,0,0)
PathScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
PathScroll.ZIndex = 6; PathScroll.Parent = PathPanel

local pathListLayout = Instance.new("UIListLayout")
pathListLayout.SortOrder = Enum.SortOrder.LayoutOrder
pathListLayout.Padding   = UDim.new(0,2)
pathListLayout.Parent    = PathScroll
local pathListPadding = Instance.new("UIPadding")
pathListPadding.PaddingLeft  = UDim.new(0,8)
pathListPadding.PaddingRight = UDim.new(0,8)
pathListPadding.Parent       = PathScroll

local function rebuildHistoryUI()
	for _, child in ipairs(PathScroll:GetChildren()) do
		if child:IsA("TextLabel") then child:Destroy() end
	end
	local startIdx = math.max(1, #pathHistory - MAX_HISTORY_LINES + 1)
	for i = startIdx, #pathHistory do
		local entry = pathHistory[i]
		local lbl   = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1,0,0,LINE_HEIGHT)
		lbl.BackgroundTransparency = 1
		lbl.TextColor3 = entry.isFinal and Color3.fromRGB(80,255,130) or Color3.fromRGB(210,210,220)
		lbl.Font = Enum.Font.Code; lbl.TextSize = 11
		lbl.Text = entry.text
		lbl.TextXAlignment = Enum.TextXAlignment.Left
		lbl.LayoutOrder = i; lbl.ZIndex = 7; lbl.Parent = PathScroll
	end
	local lineCount     = math.min(#pathHistory, MAX_HISTORY_LINES)
	local contentHeight = lineCount * (LINE_HEIGHT + 2) + 6
	PathPanel.Size      = UDim2.new(0,215,0, math.min(contentHeight+30,200))
	PathPanel.Visible   = #pathHistory > 0
	task.defer(function() PathScroll.CanvasPosition = Vector2.new(0, math.huge) end)
end

local function clearPathHistory()
	pathHistory = {}
	PathPanel.Visible = false
	rebuildHistoryUI()
end

local function addHistoryEntry(fromName, toName, cost, isFinal)
	local entry
	if isFinal then
		entry = {text = "🏁 " .. toName, isFinal = true}
	else
		entry = {text = fromName .. " → " .. toName .. " (" .. tostring(cost) .. ")", isFinal = false}
	end
	table.insert(pathHistory, entry)
	rebuildHistoryUI()
end

-- ============================================================
--  PENALTY FLASH
-- ============================================================
FlashOverlay = Instance.new("Frame")
FlashOverlay.Size = UDim2.new(1,0,1,0)
FlashOverlay.BackgroundColor3 = Color3.fromRGB(216,90,48)
FlashOverlay.BackgroundTransparency = 1
FlashOverlay.ZIndex = 10
FlashOverlay.Parent = ScreenGui

FlashText = Instance.new("TextLabel")
FlashText.Text = ""
FlashText.Size = UDim2.new(0,300,0,80)
FlashText.Position = UDim2.new(0.5,-150,0.5,-40)
FlashText.BackgroundColor3 = Color3.fromRGB(30,30,30)
FlashText.TextColor3 = Color3.fromRGB(216,90,48)
FlashText.Font = Enum.Font.Code; FlashText.TextSize = 30
FlashText.Visible = false
Instance.new("UICorner", FlashText).CornerRadius = UDim.new(0,10)
FlashText.Parent = FlashOverlay

-- ============================================================
--  MISSION COMPLETE OVERLAY
-- ============================================================
Overlay = Instance.new("Frame")
Overlay.Size = UDim2.new(1,0,1,0)
Overlay.BackgroundColor3 = Color3.new(0,0,0)
Overlay.BackgroundTransparency = 0.4
Overlay.Visible = false
Overlay.ZIndex  = 100
Overlay.Parent  = ScreenGui

OvBox = Instance.new("Frame")
OvBox.Size = UDim2.new(0,340,0,280)
OvBox.Position = UDim2.new(0.5,-170,0.5,-140)
OvBox.BackgroundColor3 = Color3.fromRGB(245,245,248)
OvBox.BorderSizePixel  = 0
Instance.new("UICorner", OvBox).CornerRadius = UDim.new(0,16)
local ovShadow = Instance.new("UIStroke", OvBox)
ovShadow.Color = Color3.fromRGB(200,200,200); ovShadow.Thickness = 1; ovShadow.Transparency = 0.8
OvBox.Parent = Overlay

OvIcon  = makeLabel(OvBox,"🎉",          Enum.Font.GothamBold,  44, Color3.fromRGB(30,30,30),  UDim2.new(0,0,0,20),   UDim2.new(1,0,0,60))
OvTitle = makeLabel(OvBox,"Mission Complete!", Enum.Font.GothamBlack, 24, Color3.fromRGB(20,20,20), UDim2.new(0,20,0,80),  UDim2.new(1,-40,0,30))
OvTitle.TextWrapped = true

OvBody = Instance.new("TextLabel")
OvBody.Text = "-"; OvBody.Size = UDim2.new(1,-40,0,90)
OvBody.Position = UDim2.new(0,20,0,120); OvBody.BackgroundTransparency = 1
OvBody.TextColor3 = Color3.fromRGB(60,60,60)
OvBody.Font = Enum.Font.GothamMedium; OvBody.TextSize = 15
OvBody.TextWrapped = true; OvBody.LineHeight = 1.2; OvBody.Parent = OvBox

OvNext = Instance.new("TextButton")
OvNext.Text = "Próxima Rodada →"
OvNext.Size = UDim2.new(0,180,0,44)
OvNext.Position = UDim2.new(0.5,-90,1,-60)
OvNext.BackgroundColor3 = Color3.fromRGB(29,158,117)
OvNext.TextColor3 = Color3.new(1,1,1)
OvNext.Font = Enum.Font.GothamBold; OvNext.TextSize = 16
Instance.new("UICorner", OvNext).CornerRadius = UDim.new(0,10)
OvNext.Parent = OvBox

-- ============================================================
--  TIMER FAILURE OVERLAY
-- ============================================================
FailOverlay = Instance.new("Frame")
FailOverlay.Size = UDim2.new(1,0,1,0)
FailOverlay.BackgroundColor3 = Color3.new(0,0,0)
FailOverlay.BackgroundTransparency = 0.4
FailOverlay.Visible = false
FailOverlay.ZIndex  = 110
FailOverlay.Parent  = ScreenGui

local FailBox = Instance.new("Frame")
FailBox.Size = UDim2.new(0,300,0,180)
FailBox.Position = UDim2.new(0.5,-150,0.5,-90)
FailBox.BackgroundColor3 = Color3.fromRGB(255,245,245)
FailBox.BorderSizePixel  = 0
Instance.new("UICorner", FailBox).CornerRadius = UDim.new(0,16)
Instance.new("UIStroke", FailBox).Color = Color3.fromRGB(220,80,80)
FailBox.Parent = FailOverlay

makeLabel(FailBox,"⏰",              Enum.Font.GothamBold,  50, Color3.fromRGB(200,50,50),  UDim2.new(0,0,0,15),   UDim2.new(1,0,0,50))
makeLabel(FailBox,"Missão Falhou!",  Enum.Font.GothamBlack, 24, Color3.fromRGB(200,50,50),  UDim2.new(0,0,0,70),   UDim2.new(1,0,0,30))
makeLabel(FailBox,"O tempo acabou. Tente novamente!", Enum.Font.GothamMedium, 14,
	Color3.fromRGB(100,100,100), UDim2.new(0,20,0,105), UDim2.new(1,-40,0,30))

FailRestartBtn = Instance.new("TextButton")
FailRestartBtn.Text = "Reiniciar Rodada"
FailRestartBtn.Size = UDim2.new(0,160,0,40)
FailRestartBtn.Position = UDim2.new(0.5,-80,1,-52)
FailRestartBtn.BackgroundColor3 = Color3.fromRGB(220,80,80)
FailRestartBtn.TextColor3 = Color3.new(1,1,1)
FailRestartBtn.Font = Enum.Font.GothamBold; FailRestartBtn.TextSize = 14
Instance.new("UICorner", FailRestartBtn).CornerRadius = UDim.new(0,10)
FailRestartBtn.Parent = FailBox

FailRestartBtn.MouseButton1Click:Connect(function()
	FailOverlay.Visible = false
	clearPathHistory()
	stopTimer()
	RestartRound:FireServer()
end)

-- ============================================================
--  HELPERS
-- ============================================================
local function clearEdges()
	for _, p in ipairs(edgeParts) do p:Destroy() end
	edgeParts = {}
end

function getNodeById(id)
	for _, n in ipairs(gameState.nodes or {}) do
		if n.id == id then return n end
	end
end

-- Find a node's BasePart in the Nodes folder by its partName.
-- Falls back to X-sorted index if WaitForChild misses (e.g. dynamic builds).
local sortedPartsCache = nil
local function findNodePart(node)
	if not node then return nil end
	-- Try by name first (fast path)
	local part = NodesFolder:FindFirstChild(node.partName)
	if part and part:IsA("BasePart") then return part end
	-- Rebuild sorted cache if needed
	if not sortedPartsCache then
		local parts = {}
		local function scan(parent)
			for _, child in ipairs(parent:GetChildren()) do
				if child:IsA("BasePart") and child.Name ~= "NodeTemplate" then
					table.insert(parts, child)
				elseif child:IsA("Folder") or child:IsA("Model") then
					scan(child)
				end
			end
		end
		scan(NodesFolder)
		table.sort(parts, function(a,b) return a.Position.X < b.Position.X end)
		sortedPartsCache = parts
	end
	return sortedPartsCache[node.id + 1]
end

local function invalidatePartsCache()
	sortedPartsCache = nil
end

-- ============================================================
--  3D EDGE DRAWING
-- ============================================================
local function draw3DEdges()
	clearEdges()
	if not gameState.edgeMap then return end
	for key, w in pairs(gameState.edgeMap) do
		local segs = string.split(key, "_")
		local uId  = tonumber(segs[1])
		local vId  = tonumber(segs[2])
		local n1   = getNodeById(uId)
		local n2   = getNodeById(vId)
		if not (n1 and n2) then continue end
		local p1   = Vector3.new(n1.x, n1.y, n1.z)
		local p2   = Vector3.new(n2.x, n2.y, n2.z)
		local dist = (p1-p2).Magnitude
		local ep   = Instance.new("Part")
		ep.Size       = Vector3.new(0.5,0.5,dist)
		ep.CFrame     = CFrame.lookAt(p1,p2) * CFrame.new(0,0,-dist/2)
		ep.Anchored   = true; ep.CanCollide = false; ep.CanQuery = false
		ep.Material   = Enum.Material.Neon
		ep.Name       = "edge_" .. key
		local onTrail = false
		if gameState.visited then
			for i = 2, #gameState.visited do
				local a,b = gameState.visited[i-1], gameState.visited[i]
				if (a==uId and b==vId) or (a==vId and b==uId) then onTrail=true; break end
			end
		end
		if onTrail then
			ep.Color = Color3.fromRGB(55,138,221); ep.Size = Vector3.new(1,1,dist)
		else
			ep.Color = Color3.fromRGB(150,150,150); ep.Transparency = 0.5
		end
		ep.Parent = Workspace
		table.insert(edgeParts, ep)
		local bg  = Instance.new("BillboardGui")
		bg.Size   = UDim2.new(0,60,0,30); bg.StudsOffset = Vector3.new(0,8,0); bg.AlwaysOnTop = true
		local txt = Instance.new("TextLabel")
		txt.Size = UDim2.new(1,0,1,0); txt.BackgroundTransparency = 0.2
		txt.BackgroundColor3 = Color3.fromRGB(40,40,40); txt.TextColor3 = Color3.new(1,1,1)
		txt.Font = Enum.Font.Code; txt.TextSize = 24; txt.Text = tostring(w)
		Instance.new("UICorner",txt).CornerRadius = UDim.new(0,4)
		txt.Parent = bg; bg.Parent = ep
	end
end

-- ============================================================
--  MINIMAP DRAWING
-- ============================================================
local function drawMinimap()
	for _, c in ipairs(Minimap:GetChildren()) do
		if not c:IsA("UICorner") and c.Name ~= "PlayerIcon" then c:Destroy() end
	end
	if not gameState.nodes then return end

	local mnX, mnZ =  math.huge,  math.huge
	local mxX, mxZ = -math.huge, -math.huge
	for _, n in ipairs(gameState.nodes) do
		if n.x < mnX then mnX = n.x end; if n.x > mxX then mxX = n.x end
		if n.z < mnZ then mnZ = n.z end; if n.z > mxZ then mxZ = n.z end
	end
	mnX=mnX-20; mxX=mxX+20; mnZ=mnZ-20; mxZ=mxZ+20
	local rX = math.max(mxX-mnX, 1)
	local rZ = math.max(mxZ-mnZ, 1)
	minimapMinX=mnX; minimapMinZ=mnZ; minimapRangeX=rX; minimapRangeZ=rZ

	if gameState.edgeMap then
		for key, w in pairs(gameState.edgeMap) do
			local segs = string.split(key,"_")
			local uId = tonumber(segs[1]); local vId = tonumber(segs[2])
			local n1 = getNodeById(uId); local n2 = getNodeById(vId)
			if not (n1 and n2) then continue end
			local p1x=(n1.x-mnX)/rX; local p1z=(n1.z-mnZ)/rZ
			local p2x=(n2.x-mnX)/rX; local p2z=(n2.z-mnZ)/rZ
			local onTrail = false
			if gameState.visited then
				for i=2,#gameState.visited do
					local a,b=gameState.visited[i-1],gameState.visited[i]
					if (a==uId and b==vId) or (a==vId and b==uId) then onTrail=true; break end
				end
			end
			local line = Instance.new("Frame")
			line.Name = "edge_"..key; line.BorderSizePixel = 0
			line.BackgroundColor3 = onTrail and Color3.fromRGB(55,138,221) or Color3.fromRGB(150,150,150)
			line.BackgroundTransparency = onTrail and 0 or 0.5
			line.ZIndex = onTrail and 2 or 1
			local dx=p2x-p1x; local dz=p2z-p1z
			local mag = math.sqrt(dx*dx+dz*dz) * Minimap.AbsoluteSize.X
			local angle = math.deg(math.atan2(dz,dx))
			local thick = onTrail and 3 or 1
			line.Size = UDim2.new(0,mag,0,thick)
			line.Position = UDim2.new((p1x+p2x)/2,0,(p1z+p2z)/2,0)
			line.AnchorPoint = Vector2.new(0.5,0.5); line.Rotation = angle; line.Parent = Minimap
			local costLbl = Instance.new("TextLabel")
			costLbl.Size = UDim2.new(0,18,0,13)
			costLbl.Position = UDim2.new((p1x+p2x)/2,0,(p1z+p2z)/2,0)
			costLbl.AnchorPoint = Vector2.new(0.5,0.5)
			costLbl.Text = tostring(w); costLbl.BackgroundColor3 = Color3.fromRGB(40,40,40)
			costLbl.TextColor3 = Color3.new(1,1,1); costLbl.Font = Enum.Font.Code
			costLbl.TextSize = 10; costLbl.ZIndex = 3
			Instance.new("UICorner",costLbl).CornerRadius = UDim.new(0,3)
			costLbl.Parent = Minimap
		end
	end

	for _, n in ipairs(gameState.nodes) do
		local px=(n.x-mnX)/rX; local pz=(n.z-mnZ)/rZ
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5,0.5); dot.ZIndex = 4
		Instance.new("UICorner",dot).CornerRadius = UDim.new(1,0)
		if gameState.playerPos == n.id then
			dot.BackgroundColor3=Color3.fromRGB(245,205,47); dot.Size=UDim2.new(0,14,0,14)
		elseif gameState.dst == n.id then
			dot.BackgroundColor3=Color3.fromRGB(80,255,120); dot.Size=UDim2.new(0,12,0,12)
		else
			dot.BackgroundColor3=Color3.fromRGB(55,138,221); dot.Size=UDim2.new(0,10,0,10)
		end
		dot.Position = UDim2.new(px,0,pz,0); dot.Parent = Minimap
		local lbl = Instance.new("TextLabel")
		lbl.Text=n.name; lbl.Size=UDim2.new(0,40,0,12)
		lbl.Position=UDim2.new(0.5,0,1,2); lbl.AnchorPoint=Vector2.new(0.5,0)
		lbl.BackgroundTransparency=1; lbl.TextColor3=Color3.new(1,1,1)
		lbl.Font=Enum.Font.Code; lbl.TextSize=10; lbl.ZIndex=5; lbl.Parent=dot
	end
end

-- ============================================================
--  NEIGHBOUR HIGHLIGHTS
-- ============================================================
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
				if v == edge.v then isVisited = true; break end
			end
		end
		if isVisited then continue end
		local n    = getNodeById(edge.v)
		local part = findNodePart(n)
		if not part then continue end
		local hl = Instance.new("Highlight")
		hl.Adornee = part; hl.FillTransparency = 1
		hl.OutlineColor = Color3.new(1,1,1); hl.OutlineTransparency = 0
		hl.Parent = part
		table.insert(activeHighlights, hl)
		TweenService:Create(hl, TweenInfo.new(1,Enum.EasingStyle.Sine,Enum.EasingDirection.InOut,-1,true),
			{OutlineTransparency=0.8}):Play()
	end
end

-- ============================================================
--  PROXIMITY PROMPTS  (the actual E-key interaction)
-- ============================================================
local function clearPrompts()
	for _, p in ipairs(activePrompts) do p:Destroy() end
	activePrompts = {}
end

local function applyPrompts()
	clearPrompts()
	if not gameState.playerPos then return end

	if gameState.mode == "FreeRoam" then
		for _, n in ipairs(gameState.nodes or {}) do
			if n.id ~= gameState.playerPos then
				local part = findNodePart(n)
				if not part then continue end
				local prompt = Instance.new("ProximityPrompt")
				prompt.ActionText = "Teleportar"
				prompt.ObjectText = n.name
				prompt.KeyboardKeyCode = Enum.KeyCode.E
				prompt.MaxActivationDistance = 50
				prompt.RequiresLineOfSight   = false
				prompt.Parent = part
				local capturedId = n.id
				prompt.Triggered:Connect(function() MoveRequest:FireServer(capturedId) end)
				table.insert(activePrompts, prompt)
			end
		end
		return
	end

	-- Dijkstra mode: prompts only on unvisited neighbours
	if not gameState.adj then return end
	local neighbors = gameState.adj[gameState.playerPos]
	if not neighbors then return end

	local visitedSet = {}
	for _, v in ipairs(gameState.visited or {}) do visitedSet[v] = true end

	for _, edge in ipairs(neighbors) do
		if visitedSet[edge.v] then continue end
		local n    = getNodeById(edge.v)
		local part = findNodePart(n)
		if not part then continue end
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Ir  (+" .. tostring(edge.w) .. ")"
		prompt.ObjectText = n and n.name or ("Nó " .. edge.v)
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.MaxActivationDistance = 50
		prompt.RequiresLineOfSight   = false
		prompt.Parent = part
		local capturedId = edge.v
		prompt.Triggered:Connect(function() MoveRequest:FireServer(capturedId) end)
		table.insert(activePrompts, prompt)
	end
end

-- ============================================================
--  normaliseAdj  (Roblox serialises integer keys as strings)
-- ============================================================
local function normaliseAdj(adj)
	if type(adj) ~= "table" then return adj end
	local out = {}
	for k, edges in pairs(adj) do
		local nk = tonumber(k)
		if nk then
			local normEdges = {}
			for _, edge in ipairs(edges) do
				table.insert(normEdges, {
					v = tonumber(edge.v) or edge.v,
					w = tonumber(edge.w) or edge.w,
				})
			end
			out[nk] = normEdges
		else
			out[k] = edges
		end
	end
	return out
end

-- ============================================================
--  UPDATE UI
-- ============================================================
UpdateUI.OnClientEvent:Connect(function(data)
	local prevPos = gameState and gameState.playerPos

	-- Normalise all numeric keys that Roblox may have stringified
	if data.adj      then data.adj = normaliseAdj(data.adj) end
	if data.visited  then for i,v in ipairs(data.visited)   do data.visited[i]     = tonumber(v) or v end end
	if data.optimalPath then for i,v in ipairs(data.optimalPath) do data.optimalPath[i] = tonumber(v) or v end end
	if data.src      then data.src      = tonumber(data.src)      or data.src      end
	if data.dst      then data.dst      = tonumber(data.dst)      or data.dst      end
	if data.playerPos then data.playerPos = tonumber(data.playerPos) or data.playerPos end

	-- Invalidate parts cache on new round (nodes may have been rebuilt by server)
	local isNewRound = data.visited and #data.visited == 1
	if isNewRound then invalidatePartsCache() end

	gameState = data

	if data.mode == "Menu" then
		StartMenu.Visible     = true
		MainContainer.Visible = false
		Overlay.Visible       = false
		FailOverlay.Visible   = false
		stopTimer()
		return
	end

	MainContainer.Visible = true
	StartMenu.Visible     = false

	if data.mode == "FreeRoam" then
		StatsPanel.Visible  = false
		MissionCard.Visible = false
		TimerBar.Visible    = false
		drawMinimap()
		applyPrompts()
		return
	end

	-- ── Dijkstra mode ──────────────────────────────────────────
	StatsPanel.Visible  = true
	MissionCard.Visible = true

	ValCost.Text  = tostring(data.playerCost   or 0)
	ValOpt.Text   = tostring(data.optimalCost  or "?")
	ValPen.Text   = "+" .. tostring(data.penaltyTotal or 0)
	ValRound.Text = tostring(data.roundNum or 1)
	ScoreOut.Text = "Pontuação total: " .. tostring(data.totalScore or 0)

	if data.mission then
		local srcNode  = getNodeById(data.src)
		local dstNode  = getNodeById(data.dst)
		local currNode = getNodeById(data.playerPos)
		if dstNode then
			MText.Text = data.mission.emoji .. " " .. data.mission.verb .. " " .. dstNode.name
		end
		if srcNode and dstNode then
			MSub.Text = string.format("De: %s %s  →  Para: %s %s",
				srcNode.name, srcNode.emoji, dstNode.name, dstNode.emoji)
		end
	end

	-- Timer: start fresh only on the first step of a round
	if isNewRound then
		clearPathHistory()
		stopTimer()
		if data.optimalPath and #data.optimalPath > 1 then
			startTimer(#data.optimalPath - 1)
		end
	end

	-- History entry for moves after the first step
	if not isNewRound and prevPos and data.playerPos and prevPos ~= data.playerPos then
		local edgeCost = 0
		if data.adj and data.adj[prevPos] then
			for _, edge in ipairs(data.adj[prevPos]) do
				if edge.v == data.playerPos then edgeCost = edge.w; break end
			end
		end
		local fromNode = getNodeById(prevPos)
		local toNode   = getNodeById(data.playerPos)
		if fromNode and toNode then
			addHistoryEntry(fromNode.name, toNode.name, edgeCost, data.playerPos == data.dst)
		end
	end

	applyNeighborHighlights()
	applyPrompts()
	draw3DEdges()
	drawMinimap()
	Overlay.Visible     = false
	FailOverlay.Visible = false
end)

-- ============================================================
--  PENALTY FLASH
-- ============================================================
PenaltyFlash.OnClientEvent:Connect(function(pen)
	FlashText.Text = "+" .. tostring(pen) .. " penalidade!"
	FlashText.Visible = true
	FlashOverlay.BackgroundTransparency = 0.8
	TweenService:Create(FlashOverlay, TweenInfo.new(0.8), {BackgroundTransparency=1}):Play()
	task.delay(0.8, function() FlashText.Visible = false end)
end)

-- ============================================================
--  ROUND END
-- ============================================================
RoundEnd.OnClientEvent:Connect(function(res)
	stopTimer()
	OvIcon.Text  = res.perfect and "🏆" or (res.diff <= 20 and "🎯" or "📚")
	OvTitle.Text = res.perfect and "Caminho Perfeito!" or "Missão Cumprida!"
	OvBody.Text  = string.format(
		"Seu custo: %d | Ideal: %d\nPenalidade: +%d\nPontuação da rodada: %d\n\n%s",
		res.playerCost, res.optimalCost, res.penaltyTotal, res.roundScore,
		res.perfect
			and "Você seguiu o caminho exato de Dijkstra! 🧠"
			or (res.diff == 0
				and "Custo ideal, mas deu algumas voltas!"
				or ("Você pagou " .. res.diff .. " a mais. Tente o caminho mais barato!")))
	Overlay.Visible = true
	clearPrompts()   -- remove prompts while overlay is showing
	if gameState.optimalPath then
		for i = 1, #gameState.optimalPath - 1 do
			local u = gameState.optimalPath[i]; local v = gameState.optimalPath[i+1]
			local k = string.format("%d_%d", math.min(u,v), math.max(u,v))
			local mLine = Minimap:FindFirstChild("edge_"..k)
			if mLine then mLine.BackgroundColor3 = Color3.fromRGB(255,215,0); mLine.ZIndex = 5 end
			local wLine = Workspace:FindFirstChild("edge_"..k)
			if wLine then wLine.Color = Color3.fromRGB(255,215,0) end
		end
	end
end)

-- ============================================================
--  BUTTONS
-- ============================================================
BtnRestart.MouseButton1Click:Connect(function()
	clearPathHistory(); stopTimer(); RestartRound:FireServer()
end)

OvNext.MouseButton1Click:Connect(function()
	clearPathHistory(); stopTimer(); NextRound:FireServer()
end)

-- ============================================================
--  RENDER LOOP
-- ============================================================
RunService.RenderStepped:Connect(function(dt)
	local char = player.Character
	if char and char:FindFirstChild("HumanoidRootPart") then
		local pos = char.HumanoidRootPart.Position
		local px  = (pos.X - minimapMinX) / minimapRangeX
		local pz  = (pos.Z - minimapMinZ) / minimapRangeZ
		PlayerIcon.Position = UDim2.new(px,0,pz,0)
	end

	if timerActive then
		timerRemaining = timerRemaining - dt
		local pct = math.max(timerRemaining, 0) / timerDuration
		local col = timerColor(pct)
		TimerLabel.TextColor3      = col
		TimerFill.BackgroundColor3 = col
		TimerFill.Size = UDim2.new(math.max(pct,0),0,1,0)
		TimerLabel.Text = "⏱ " .. tostring(math.ceil(math.max(timerRemaining,0)))
		if timerRemaining <= 0 then
			timerActive = false
			TimerFill.BackgroundColor3 = Color3.fromRGB(255,0,0)
			TimerLabel.Text = "⏱ 0 – TEMPO ESGOTADO!"
			FailOverlay.Visible = true
			clearPrompts()
		end
	end
end)