-- DijkstraClient.lua
-- Place inside: StarterPlayerScripts
--
-- v13 – New features:
--   • FREE ROAM: Added "💥 Modo Destruição" toggle button. When active,
--     the server unanchors all eligible BaseParts in the Workspace so
--     explosions and physics interactions can knock them around. Pressing
--     the button again ("🔧 Restaurar Tudo") asks the server to restore
--     all saved properties. The button auto-restores when the player
--     exits Free Roam back to the menu. State is synced across clients
--     via SetDestructible:FireAllClients.
--   • All v12 fixes retained.
--   • FIX: Start menu texts were overlapping. Redistributed all Y offsets
--     so BtnStart, BtnFreeRoam, freeRoamHint, modeLabel, mode buttons,
--     modeDescLbl, and infoLbl no longer collide.
--   • FIX: ProximityPrompt MaxActivationDistance reduced from 50 to 8
--     studs so the node pop-up only appears when the player is genuinely
--     close to the node, not from across the map.
--   • All v11 fixes retained.
--   • FIX: OvBody format string had a hardcoded '+' prefix on the diff value,
--     producing "Diferença: +0" on a perfect run and "Diferença: +-N" if diff
--     were ever negative. Now conditionally prepends '+' only when diff > 0.
--   • FIX: drawMinimap used Minimap.AbsoluteSize.X as the pixel scale for edge
--     lines, but AbsoluteSize is 0 before the first render frame, making all
--     minimap edges invisible on the very first draw call. Guarded with max(...,1).
--   • FIX: menu button hover tweens (BtnStart, BtnFreeRoam) didn't cancel the
--     in-flight tween before starting the opposite one. Rapid mouse-enter/leave
--     left buttons mid-tween. Now explicitly cancelled before each new tween.
--   • FIX: spawnTopDownLabels set BillboardGui.Adornee to a Model instance when
--     PrimaryPart was nil. BillboardGui.Adornee must be a BasePart — passing a
--     Model silently fails to display the label. Now walks descendants for the
--     first BasePart and skips the node entirely if none is found.
--   • All v10 fixes retained.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local Workspace         = game:GetService("Workspace")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Await remotes
local remotesFolder      = ReplicatedStorage:WaitForChild("DijkstraRemotes")
local SelectNode         = remotesFolder:WaitForChild("SelectNode")
local GameStateRemote    = remotesFolder:WaitForChild("GameState")
local ResetGame          = remotesFolder:WaitForChild("ResetGame")
local SetMode            = remotesFolder:WaitForChild("SetMode")
local SetDestructible    = remotesFolder:WaitForChild("SetDestructible")

local NodesFolder = Workspace:WaitForChild("Nodes")

-- ============================================================
--  COLOURS (single source of truth)
-- ============================================================
local COL = {
	OPTIMAL   = Color3.fromRGB(55,  200, 100),  -- green  – right choice
	WRONG     = Color3.fromRGB(220,  50,  50),   -- red    – wrong choice
	UNVISITED = Color3.fromRGB(140, 140, 150),   -- grey   – not yet walked
	GOLD      = Color3.fromRGB(255, 215,   0),   -- gold   – optimal path reveal
	PLAYER    = Color3.fromRGB(245, 205,  47),   -- yellow – player dot
	END_NODE  = Color3.fromRGB( 80, 255, 120),   -- green  – destination dot
	VISITED   = Color3.fromRGB( 55, 138, 221),   -- blue   – visited dot
}

-- ============================================================
--  SHARED STATE
-- ============================================================
local gameState        = {}
local edgeParts        = {}
local minimapMinX      = 0
local minimapMinZ      = 0
local minimapRangeX    = 1
local minimapRangeZ    = 1
local connectionLog    = {}   -- {from, to, cost, wasOptimal}
local activeHighlights = {}
local activePrompts    = {}
local timerDuration    = 60
local timerRemaining   = 0
local timerActive      = false

-- FIX: gate all GameStateRemote handling behind this flag so the
-- StartMenu is never bypassed by a server-initiated fire.
local gameStarted      = false

-- FIX: when the player presses the "⬅ Menu" button mid-round, gameStarted
-- intentionally stays true (so a respawn mid-game still re-syncs state).
-- But a respawn-triggered GameStateRemote fire while the StartMenu is open
-- was previously forcing MainContainer back into view, yanking the player
-- out of the menu against their will. This flag lets the handler keep
-- gameState in sync in the background without touching UI visibility.
local viewingMenu      = false

-- Free Roam mode: all game UI hidden, only a small "Menu" button visible.
local freeRoamActive   = false

-- Top-down camera
local topDownEnabled   = false
local TOP_DOWN_HEIGHT  = 120
local topDownZoom      = TOP_DOWN_HEIGHT
local TOP_DOWN_MIN     = 40
local TOP_DOWN_MAX     = 300
local topDownRotation  = 0              -- degrees applied as roll (0 = default / 360°)
local ROTATE_STEPS     = {0, 90, 180, 270}
local rotateIdx        = 1              -- index into ROTATE_STEPS

-- Forward declarations
local ScreenGui, MainContainer, StartMenu
local StatsPanel, MissionCard
local TimerBar, TimerLabel, TimerFill
local Minimap, PlayerIcon
local FlashOverlay
local Overlay, OvBox, OvIcon, OvTitle, OvBody, OvNext
local FailOverlay, FailRestartBtn
local ConnPanel, ConnScroll, ConnTitle
local ValCost, ValOpt, ValPen, ValRound, ValTotal
local BtnRestart, TopDownBtn, TopDownRotateBtn
local MText, MSub
local BtnFreeRoam         -- forward declaration for Free Roam button
local FreeRoamMenuBtn     -- the small "⬅ Menu" shown during free roam

-- ============================================================
--  TIMER CONSTANTS
-- ============================================================
local TIMER_BASE_SECS       = 20
local TIMER_SECS_PER_EDGE   = 15
local TIMER_PULSE_THRESHOLD = 0.25   -- start pulsing below 25% remaining
local timerPulseTween       = nil    -- looping tween handle; nil when inactive

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
	RightNode       = Instance.new("Sound"),
	WrongNode       = Instance.new("Sound"),
	Success         = Instance.new("Sound"),
	Fail            = Instance.new("Sound"),
	MissionComplete = Instance.new("Sound"),
	MissionFail     = Instance.new("Sound"),
}
sounds.RightNode.SoundId       = "rbxassetid://876939830";  sounds.RightNode.Volume       = 0.5
sounds.WrongNode.SoundId       = "rbxassetid://12222242";   sounds.WrongNode.Volume       = 0.7
sounds.Success.SoundId         = "rbxassetid://2865227271"; sounds.Success.Volume         = 0.8
sounds.Fail.SoundId            = "rbxassetid://12222242";   sounds.Fail.Volume            = 0.8
-- Mission complete: triumphant fanfare
sounds.MissionComplete.SoundId = "rbxassetid://4612375409"; sounds.MissionComplete.Volume = 0.9
-- Mission fail / time-up: dramatic failure sting
sounds.MissionFail.SoundId     = "rbxassetid://3314877134"; sounds.MissionFail.Volume     = 0.85
for _, s in pairs(sounds) do s.Parent = ScreenGui end

local ambiance = Instance.new("Sound")
ambiance.SoundId = "rbxassetid://4630467570"
ambiance.Looped  = true; ambiance.Volume = 0.15
ambiance.Parent  = Workspace
ambiance:Play()

local function playSound(sType)
	if sounds[sType] then
		if sType == "RightNode" then
			sounds[sType].PlaybackSpeed = 1 + (math.random() * 0.3 - 0.15)
		end
		sounds[sType]:Play()
	end
end

-- ============================================================
--  VISUAL EFFECTS
-- ============================================================
local function CreateFloatingText(text, color, position)
	local part = Instance.new("Part")
	part.Size = Vector3.new(1,1,1); part.Position = position
	part.Anchored = true; part.CanCollide = false; part.Transparency = 1
	part.Parent = Workspace
	local bg = Instance.new("BillboardGui")
	bg.Size = UDim2.new(0,200,0,50); bg.StudsOffset = Vector3.new(0,5,0)
	bg.AlwaysOnTop = true; bg.Parent = part
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.new(1,0,1,0); tl.BackgroundTransparency = 1
	tl.Text = text; tl.TextColor3 = color
	tl.TextStrokeTransparency = 0.3; tl.TextStrokeColor3 = Color3.new(0,0,0)
	tl.TextScaled = true; tl.Font = Enum.Font.GothamBlack; tl.Parent = bg
	TweenService:Create(bg, TweenInfo.new(1.2, Enum.EasingStyle.Back,  Enum.EasingDirection.Out), {StudsOffset=Vector3.new(0,9,0)}):Play()
	TweenService:Create(tl, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),  {TextTransparency=1, TextStrokeTransparency=1}):Play()
	game.Debris:AddItem(part, 1.5)
end

local function CreatePulse(position, color)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Size  = Vector3.new(0.2,2,2)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0,0,math.pi/2)
	part.Color = color or COL.OPTIMAL; part.Material = Enum.Material.Neon
	part.Anchored = true; part.CanCollide = false; part.Transparency = 0.2
	part.Parent = Workspace
	TweenService:Create(part, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{Size=Vector3.new(0.2,20,20), Transparency=1}):Play()
	game.Debris:AddItem(part, 0.7)
end

-- ============================================================
--  NODE HELPERS
-- ============================================================
local nodePartCache = {}

local function invalidatePartsCache() nodePartCache = {} end

local function findNodePartByName(name)
	if nodePartCache[name] then return nodePartCache[name] end
	local part = NodesFolder:FindFirstChild(name)
	if part then nodePartCache[name] = part; return part end
	local function scan(folder)
		for _, child in ipairs(folder:GetChildren()) do
			if (child:IsA("BasePart") or child:IsA("Model")) and child.Name == name then
				nodePartCache[name] = child; return child
			elseif child:IsA("Folder") then
				local found = scan(child)
				if found then return found end
			end
		end
	end
	return scan(NodesFolder)
end

local function getNodePosition(name)
	local part = findNodePartByName(name)
	if not part then return Vector3.new(0,0,0) end
	-- CRITICAL FIX: Model:GetPrimaryPartCFrame() throws if PrimaryPart is unset.
	-- In random mode any node (not just curated start/end nodes) can be drawn
	-- on the minimap / 3D edges / top-down view, so a Model without a
	-- PrimaryPart would error here and break minimap/edge rendering for the
	-- whole round. GetPivot() works for Models regardless of PrimaryPart.
	if part:IsA("Model") then
		if part.PrimaryPart then
			return part:GetPrimaryPartCFrame().Position
		end
		return part:GetPivot().Position
	end
	return part.Position
end

-- Returns a BasePart suitable for ProximityPrompt / Highlight attachment.
-- If the node object is a Model, uses PrimaryPart or the first BasePart descendant.
local function getNodeBasePart(name)
	local obj = findNodePartByName(name)
	if not obj then return nil end
	if obj:IsA("BasePart") then return obj end
	if obj:IsA("Model") then
		if obj.PrimaryPart then return obj.PrimaryPart end
		for _, child in ipairs(obj:GetDescendants()) do
			if child:IsA("BasePart") then return child end
		end
	end
	return nil
end

-- ============================================================
--  LABEL HELPER
-- ============================================================
local function makeLabel(parent, text, font, size, color, pos, sz, zIdx)
	local l = Instance.new("TextLabel")
	l.Text = text; l.Font = font; l.TextSize = size; l.TextColor3 = color
	l.Position = pos; l.Size = sz; l.BackgroundTransparency = 1; l.ZIndex = zIdx or 1
	l.Parent = parent
	return l
end

-- ============================================================
--  MOVE-LOG LOOKUP  (client-side helper)
-- ============================================================
local function buildTrailMap(moveLog)
	local map = {}
	if not moveLog then return map end
	for _, entry in ipairs(moveLog) do
		local a, b = entry.from, entry.to
		local key  = a < b and (a .. "__" .. b) or (b .. "__" .. a)
		map[key] = entry.wasOptimal
	end
	return map
end

-- ============================================================
--  MAIN CONTAINER
-- ============================================================
MainContainer = Instance.new("Frame")
MainContainer.Size = UDim2.new(1,0,1,0)
MainContainer.BackgroundTransparency = 1
MainContainer.Visible = false; MainContainer.Parent = ScreenGui

-- ============================================================
--  START MENU
-- ============================================================
StartMenu = Instance.new("Frame")
StartMenu.Size = UDim2.new(1,0,1,0)
StartMenu.BackgroundColor3 = Color3.new(1,1,1)
StartMenu.Parent = ScreenGui

do
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new{
		ColorSequenceKeypoint.new(0, Color3.fromRGB(15,23,42)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(30,41,59)),
	}
	g.Rotation = 45; g.Parent = StartMenu
end

makeLabel(StartMenu,"IFBA com Djikistra",Enum.Font.GothamBlack,56,Color3.fromRGB(55,138,221),UDim2.new(0,4,0.2,4),UDim2.new(1,0,0,120),1)
makeLabel(StartMenu,"IFBA com Djikistra",Enum.Font.GothamBlack,56,Color3.new(1,1,1),UDim2.new(0,0,0.2,0),UDim2.new(1,0,0,120),2)
makeLabel(StartMenu,"Aprenda Grafos Jogando!",Enum.Font.GothamMedium,24,Color3.fromRGB(200,200,200),UDim2.new(0,0,0.2,80),UDim2.new(1,0,0,40))

local function makeMenuBtn(text, bgColor, posY)
	local btn = Instance.new("TextButton")
	btn.Text = text; btn.Font = Enum.Font.GothamBold; btn.TextSize = 24
	btn.TextColor3 = Color3.new(1,1,1); btn.BackgroundColor3 = bgColor
	btn.Size = UDim2.new(0,320,0,65); btn.Position = UDim2.new(0.5,-160,0.5,posY)
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0,12)
	btn.Parent = StartMenu; return btn
end

local BtnStart = makeMenuBtn("▶  Iniciar Jogo",  Color3.fromRGB(29,158,117), -140)
do
	-- FIX: cancel the in-flight tween before starting a new one so rapid
	-- mouse-enter/leave doesn't leave the button colour in a mid-tween state.
	local startTween
	BtnStart.MouseEnter:Connect(function()
		if startTween then startTween:Cancel() end
		startTween = TweenService:Create(BtnStart,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(39,188,137)})
		startTween:Play()
	end)
	BtnStart.MouseLeave:Connect(function()
		if startTween then startTween:Cancel() end
		startTween = TweenService:Create(BtnStart,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(29,158,117)})
		startTween:Play()
	end)
end

-- Free Roam button: positioned below Iniciar Jogo
BtnFreeRoam = makeMenuBtn("🌍  Exploração Livre", Color3.fromRGB(60,80,140), -60)
do
	local freeRoamTween
	BtnFreeRoam.MouseEnter:Connect(function()
		if freeRoamTween then freeRoamTween:Cancel() end
		freeRoamTween = TweenService:Create(BtnFreeRoam,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(80,110,180)})
		freeRoamTween:Play()
	end)
	BtnFreeRoam.MouseLeave:Connect(function()
		if freeRoamTween then freeRoamTween:Cancel() end
		freeRoamTween = TweenService:Create(BtnFreeRoam,TweenInfo.new(0.2),{BackgroundColor3=Color3.fromRGB(60,80,140)})
		freeRoamTween:Play()
	end)
end

-- Small descriptive hint under the free roam button
local freeRoamHint = makeLabel(StartMenu,
	"Explore o mapa sem objetivos, pontuação ou temporizador.",
	Enum.Font.GothamMedium, 13, Color3.fromRGB(130,130,155),
	UDim2.new(0.5,-160,0.5,16), UDim2.new(0,320,0,18), 2)
freeRoamHint.TextXAlignment = Enum.TextXAlignment.Center

local COLOR_SEL   = Color3.fromRGB(55,138,221)
local COLOR_UNSEL = Color3.fromRGB(45,45,60)

local function makeModeBtn(text, posX)
	local btn = Instance.new("TextButton")
	btn.Text = text; btn.Font = Enum.Font.GothamBold; btn.TextSize = 16
	btn.TextColor3 = Color3.new(1,1,1); btn.BackgroundColor3 = COLOR_UNSEL
	btn.Size = UDim2.new(0,155,0,46); btn.Position = UDim2.new(0.5,posX,0.5,0)
	btn.AutoButtonColor = false
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0,10)
	local s = Instance.new("UIStroke",btn); s.Thickness=1.5; s.Color=Color3.fromRGB(80,80,100); s.Transparency=0.4
	btn.Parent = StartMenu; return btn
end

local modeLabel = makeLabel(StartMenu,"MODO DE JOGO",Enum.Font.GothamBold,14,Color3.fromRGB(150,150,165),UDim2.new(0.5,-160,0.5,50),UDim2.new(0,320,0,20),2)
modeLabel.TextXAlignment = Enum.TextXAlignment.Center

local ModeNormalBtn = makeModeBtn("📍 Padrão",   -160)
local ModeRandomBtn = makeModeBtn("🔀 Aleatório",   5)

-- Reposition mode buttons to sit below the mode label
ModeNormalBtn.Position = UDim2.new(0.5,-160,0.5,76)
ModeRandomBtn.Position = UDim2.new(0.5,5,0.5,76)
local selectedMode  = "normal"

local function refreshModeButtons()
	ModeNormalBtn.BackgroundColor3 = selectedMode == "normal" and COLOR_SEL or COLOR_UNSEL
	ModeRandomBtn.BackgroundColor3 = selectedMode == "random" and COLOR_SEL or COLOR_UNSEL
end
refreshModeButtons()

ModeNormalBtn.MouseButton1Click:Connect(function() selectedMode="normal";  refreshModeButtons() end)
ModeRandomBtn.MouseButton1Click:Connect(function() selectedMode="random";  refreshModeButtons() end)

local modeDescLbl = makeLabel(StartMenu,
	"Padrão: mapa fixo, apenas os pesos mudam.\nAleatório: conexões, início e destino sorteados a cada rodada!",
	Enum.Font.GothamMedium,14,Color3.fromRGB(150,150,165),UDim2.new(0,0,0.5,132),UDim2.new(1,0,0,40),2)
modeDescLbl.TextWrapped = true

local infoLbl = makeLabel(StartMenu,"Escolha o caminho mais curto entre os nós do grafo!\nUse a tecla E ou toque nos nós para se mover.",
	Enum.Font.GothamMedium,16,Color3.fromRGB(160,160,170),UDim2.new(0,0,0.5,185),UDim2.new(1,0,0,50),2)
infoLbl.TextWrapped = true

-- ============================================================
--  STATS PANEL  (top left)
-- ============================================================
StatsPanel = Instance.new("Frame")
StatsPanel.Size = UDim2.new(0,392,0,80)
StatsPanel.Position = UDim2.new(0,20,0,20)
StatsPanel.BackgroundTransparency = 1; StatsPanel.Parent = MainContainer

local statList = Instance.new("UIListLayout")
statList.FillDirection = Enum.FillDirection.Horizontal
statList.SortOrder = Enum.SortOrder.LayoutOrder
statList.Padding = UDim.new(0,8); statList.Parent = StatsPanel

local function createStatCard(labelTxt, color)
	local Card = Instance.new("Frame")
	Card.Size = UDim2.new(0,88,1,0); Card.BackgroundColor3 = Color3.fromRGB(40,40,40)
	Instance.new("UICorner",Card).CornerRadius = UDim.new(0,10)
	local Lbl = Instance.new("TextLabel")
	Lbl.Text=labelTxt; Lbl.Size=UDim2.new(1,-8,0,18); Lbl.Position=UDim2.new(0,4,0,5)
	Lbl.BackgroundTransparency=1; Lbl.TextColor3=Color3.fromRGB(180,180,190)
	Lbl.Font=Enum.Font.Code; Lbl.TextSize=10; Lbl.TextXAlignment=Enum.TextXAlignment.Center
	Lbl.Parent=Card
	local Val = Instance.new("TextLabel")
	Val.Text="0"; Val.Size=UDim2.new(1,-8,0,40); Val.Position=UDim2.new(0,4,0,24)
	Val.BackgroundTransparency=1; Val.TextColor3=color or Color3.new(1,1,1)
	Val.Font=Enum.Font.GothamBlack; Val.TextSize=26
	Val.TextXAlignment=Enum.TextXAlignment.Center; Val.Parent=Card
	Card.Parent=StatsPanel; return Val
end

ValCost  = createStatCard("SEU CUSTO",  Color3.new(1,1,1))
ValOpt   = createStatCard("IDEAL",      Color3.fromRGB(29,158,117))
ValPen   = createStatCard("PENALIDADE", Color3.fromRGB(216,90,48))
ValRound = createStatCard("RODADA",     Color3.fromRGB(55,138,221))

-- ============================================================
--  TOTAL SCORE BAR
-- ============================================================
local TotalScoreBar = Instance.new("Frame")
TotalScoreBar.Size = UDim2.new(0,230,0,40); TotalScoreBar.Position = UDim2.new(0,20,0,106)
TotalScoreBar.BackgroundColor3 = Color3.fromRGB(30,30,38); TotalScoreBar.BorderSizePixel = 0
Instance.new("UICorner",TotalScoreBar).CornerRadius = UDim.new(0,10); TotalScoreBar.Parent = MainContainer

local totalLbl = makeLabel(TotalScoreBar,"PONTUAÇÃO TOTAL",Enum.Font.Code,12,Color3.fromRGB(170,170,180),UDim2.new(0,14,0,0),UDim2.new(0,140,1,0))
totalLbl.TextXAlignment = Enum.TextXAlignment.Left; totalLbl.TextYAlignment = Enum.TextYAlignment.Center

ValTotal = makeLabel(TotalScoreBar,"0",Enum.Font.GothamBlack,24,Color3.fromRGB(245,205,47),UDim2.new(1,-86,0,0),UDim2.new(0,72,1,0))
ValTotal.TextXAlignment = Enum.TextXAlignment.Right; ValTotal.TextYAlignment = Enum.TextYAlignment.Center

-- ============================================================
--  CONEXÕES PERCORRIDAS PANEL
-- ============================================================
-- Forward-declare here so the functions are reachable after the do-block
-- without resorting to the fragile _G global-table workaround.
local rebuildConnUI, clearConnLog, addConnEntry

do
	local CONN_LINE_H   = 24
	local CONN_MAX_SHOW = 10
	local CONN_PANEL_W  = 300
	local CONN_TOP      = 0.42

	ConnPanel = Instance.new("Frame")
	ConnPanel.Name = "ConnPanel"; ConnPanel.AnchorPoint = Vector2.new(0, 0.5)
	ConnPanel.Size = UDim2.new(0,CONN_PANEL_W,0,40); ConnPanel.Position = UDim2.new(0,20,CONN_TOP,0)
	ConnPanel.BackgroundColor3 = Color3.fromRGB(18,18,24); ConnPanel.BackgroundTransparency = 0.1
	ConnPanel.BorderSizePixel = 0; ConnPanel.ClipsDescendants = true
	ConnPanel.Visible = false; ConnPanel.ZIndex = 5
	Instance.new("UICorner",ConnPanel).CornerRadius = UDim.new(0,10)
	ConnPanel.Parent = MainContainer

	local stroke = Instance.new("UIStroke",ConnPanel)
	stroke.Color=Color3.fromRGB(60,80,120); stroke.Thickness=1; stroke.Transparency=0.5

	ConnTitle = Instance.new("TextLabel")
	ConnTitle.Text = "🔗  CONEXÕES PERCORRIDAS"; ConnTitle.Size = UDim2.new(1,-12,0,22)
	ConnTitle.Position = UDim2.new(0,8,0,5); ConnTitle.BackgroundTransparency = 1
	ConnTitle.TextColor3 = Color3.fromRGB(130,160,220); ConnTitle.Font = Enum.Font.GothamBold
	ConnTitle.TextSize = 12; ConnTitle.TextXAlignment = Enum.TextXAlignment.Left
	ConnTitle.ZIndex = 6; ConnTitle.Parent = ConnPanel

	local divider = Instance.new("Frame")
	divider.Size=UDim2.new(1,-16,0,1); divider.Position=UDim2.new(0,8,0,29)
	divider.BackgroundColor3=Color3.fromRGB(60,80,120); divider.BorderSizePixel=0
	divider.ZIndex=6; divider.Parent=ConnPanel

	ConnScroll = Instance.new("ScrollingFrame")
	ConnScroll.Size=UDim2.new(1,0,1,-32); ConnScroll.Position=UDim2.new(0,0,0,32)
	ConnScroll.BackgroundTransparency=1; ConnScroll.BorderSizePixel=0
	ConnScroll.ScrollBarThickness=4; ConnScroll.ScrollBarImageColor3=Color3.fromRGB(80,100,160)
	ConnScroll.CanvasSize=UDim2.new(0,0,0,0); ConnScroll.AutomaticCanvasSize=Enum.AutomaticSize.Y
	ConnScroll.ZIndex=6; ConnScroll.Parent=ConnPanel

	local connLayout = Instance.new("UIListLayout")
	connLayout.SortOrder=Enum.SortOrder.LayoutOrder; connLayout.Padding=UDim.new(0,2)
	connLayout.Parent=ConnScroll

	local connPad = Instance.new("UIPadding")
	connPad.PaddingLeft=UDim.new(0,8); connPad.PaddingRight=UDim.new(0,8)
	connPad.PaddingTop=UDim.new(0,4); connPad.PaddingBottom=UDim.new(0,6)
	connPad.Parent=ConnScroll

	local ROW_OPT_BG   = Color3.fromRGB(20, 55, 30)
	local ROW_WRONG_BG = Color3.fromRGB(60, 15, 15)
	local ROW_OPT_TXT  = Color3.fromRGB(120, 255, 150)
	local ROW_WRONG_TXT= Color3.fromRGB(255, 110, 110)
	local BADGE_OPT    = Color3.fromRGB(40,  170,  80)
	local BADGE_WRONG  = Color3.fromRGB(200,  40,  40)

	rebuildConnUI = function()
		for _, c in ipairs(ConnScroll:GetChildren()) do
			if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
		end

		local total = #connectionLog
		ConnPanel.Visible = total > 0
		if total == 0 then return end

		local startIdx = math.max(1, total - CONN_MAX_SHOW + 1)
		for i = startIdx, total do
			local entry  = connectionLog[i]
			local isLast = (i == total)
			local isOpt  = entry.wasOptimal

			local row = Instance.new("Frame")
			row.Size = UDim2.new(1,0,0,CONN_LINE_H)
			row.BackgroundColor3 = isOpt and ROW_OPT_BG or ROW_WRONG_BG
			row.BackgroundTransparency = isLast and 0.1 or 0.4
			row.BorderSizePixel = 0; row.LayoutOrder = i; row.ZIndex = 7
			Instance.new("UICorner",row).CornerRadius = UDim.new(0,4)
			row.Parent = ConnScroll

			local accent = Instance.new("Frame")
			accent.Size = UDim2.new(0,3,1,-4); accent.Position = UDim2.new(0,0,0,2)
			accent.BackgroundColor3 = isOpt and COL.OPTIMAL or COL.WRONG
			accent.BorderSizePixel = 0
			Instance.new("UICorner",accent).CornerRadius = UDim.new(0,2)
			accent.ZIndex = 9; accent.Parent = row

			local pathTxt = Instance.new("TextLabel")
			pathTxt.Text = (isOpt and "✔  " or "✘  ") .. entry.from .. "  →  " .. entry.to
			pathTxt.Size = UDim2.new(1,-58,1,0); pathTxt.Position = UDim2.new(0,10,0,0)
			pathTxt.BackgroundTransparency = 1
			pathTxt.TextColor3 = isOpt and ROW_OPT_TXT or ROW_WRONG_TXT
			pathTxt.Font = Enum.Font.GothamBold; pathTxt.TextSize = 13
			pathTxt.TextXAlignment = Enum.TextXAlignment.Left
			pathTxt.ZIndex = 8; pathTxt.Parent = row

			local costBadge = Instance.new("TextLabel")
			costBadge.Text = "[" .. tostring(entry.cost) .. "]"
			costBadge.Size = UDim2.new(0,48,1,-6); costBadge.Position = UDim2.new(1,-52,0,3)
			costBadge.BackgroundColor3 = isOpt and BADGE_OPT or BADGE_WRONG
			costBadge.BackgroundTransparency = 0.2
			costBadge.TextColor3 = Color3.new(1,1,1)
			costBadge.Font = Enum.Font.GothamBlack; costBadge.TextSize = 13
			costBadge.ZIndex = 8
			Instance.new("UICorner",costBadge).CornerRadius = UDim.new(0,3)
			costBadge.Parent = row
		end

		local visLines   = math.min(total, CONN_MAX_SHOW)
		local bodyHeight = visLines * (CONN_LINE_H + 2) + 10
		ConnPanel.Size = UDim2.new(0,CONN_PANEL_W,0, math.min(bodyHeight + 40, 290))

		task.defer(function()
			ConnScroll.CanvasPosition = Vector2.new(0, math.huge)
		end)
	end

	clearConnLog = function()
		connectionLog = {}; ConnPanel.Visible = false; rebuildConnUI()
	end

	addConnEntry = function(from, to, cost, wasOptimal)
		table.insert(connectionLog, {from=from, to=to, cost=cost, wasOptimal=wasOptimal})
		rebuildConnUI()
	end
end

-- ============================================================
--  MISSION CARD  (top centre)
-- ============================================================
MissionCard = Instance.new("Frame")
MissionCard.Size=UDim2.new(0,320,0,80); MissionCard.Position=UDim2.new(0.5,-160,0,20)
MissionCard.BackgroundColor3=Color3.fromRGB(40,40,40)
Instance.new("UICorner",MissionCard).CornerRadius=UDim.new(0,10)
MissionCard.Parent=MainContainer

makeLabel(MissionCard,"MISSÃO ATUAL",Enum.Font.Code,12,Color3.fromRGB(200,200,200),UDim2.new(0,0,0,5),UDim2.new(1,0,0,20))
MText = makeLabel(MissionCard,"-",Enum.Font.GothamBold,16,Color3.new(1,1,1),UDim2.new(0,10,0,25),UDim2.new(1,-20,0,28))
MSub  = makeLabel(MissionCard,"De ? → Para ?",Enum.Font.Code,12,Color3.fromRGB(210,210,210),UDim2.new(0,10,0,55),UDim2.new(1,-20,0,20))
MSub.TextStrokeTransparency=0.6; MSub.TextStrokeColor3=Color3.new(0,0,0)

-- ============================================================
--  COUNTDOWN TIMER
-- ============================================================
TimerBar = Instance.new("Frame")
TimerBar.Name="TimerBar"; TimerBar.Size=UDim2.new(0,320,0,42); TimerBar.Position=UDim2.new(0.5,-160,0,108)
TimerBar.BackgroundColor3=Color3.fromRGB(35,35,42); TimerBar.BorderSizePixel=0
Instance.new("UICorner",TimerBar).CornerRadius=UDim.new(0,10)
TimerBar.Visible=false; TimerBar.Parent=MainContainer

TimerLabel = Instance.new("TextLabel")
TimerLabel.Size=UDim2.new(1,0,0,26); TimerLabel.Position=UDim2.new(0,0,0,3)
TimerLabel.BackgroundTransparency=1; TimerLabel.TextColor3=Color3.fromRGB(80,220,80)
TimerLabel.Font=Enum.Font.GothamBlack; TimerLabel.TextSize=18; TimerLabel.Text="⏱ -"
TimerLabel.Parent=TimerBar

local TimerTrack = Instance.new("Frame")
TimerTrack.Size=UDim2.new(1,-16,0,7); TimerTrack.Position=UDim2.new(0,8,1,-12)
TimerTrack.BackgroundColor3=Color3.fromRGB(60,60,68); TimerTrack.BorderSizePixel=0
Instance.new("UICorner",TimerTrack).CornerRadius=UDim.new(1,0); TimerTrack.Parent=TimerBar

TimerFill = Instance.new("Frame")
TimerFill.Size=UDim2.new(1,0,1,0); TimerFill.BackgroundColor3=Color3.fromRGB(80,220,80)
TimerFill.BorderSizePixel=0; Instance.new("UICorner",TimerFill).CornerRadius=UDim.new(1,0)
TimerFill.Parent=TimerTrack

local function timerColor(pct)
	if pct > 0.5 then
		local t=(pct-0.5)/0.5; return Color3.fromRGB(math.floor(255*(1-t)+80*t),220,math.floor(80*t))
	elseif pct > 0.25 then
		local t=(pct-0.25)/0.25; return Color3.fromRGB(255,math.floor(165*t+80*(1-t)),0)
	else
		local t=pct/0.25; return Color3.fromRGB(255,math.floor(80*t),0)
	end
end

local function startTimer(numEdges)
	timerDuration=TIMER_BASE_SECS+TIMER_SECS_PER_EDGE*math.max(1,numEdges)
	timerRemaining=timerDuration; timerActive=true; TimerBar.Visible=true
	local col=timerColor(1); TimerLabel.TextColor3=col; TimerFill.BackgroundColor3=col
	TimerFill.Size=UDim2.new(1,0,1,0); TimerLabel.Text="⏱ "..tostring(math.ceil(timerRemaining))
end

local function stopTimerPulse()
	if timerPulseTween then
		timerPulseTween:Cancel(); timerPulseTween = nil
		TimerBar.BackgroundColor3 = Color3.fromRGB(35,35,42)
	end
end

local function stopTimer()
	timerActive=false; TimerBar.Visible=false
	stopTimerPulse()
end

-- ============================================================
--  MINIMAP  (top right)
-- ============================================================
Minimap = Instance.new("Frame")
Minimap.Size=UDim2.new(0,260,0,260); Minimap.Position=UDim2.new(1,-280,0,20)
Minimap.BackgroundColor3=Color3.fromRGB(25,25,30); Minimap.ClipsDescendants=true
Instance.new("UICorner",Minimap).CornerRadius=UDim.new(0,12); Minimap.Parent=MainContainer

local minimapTitle = Instance.new("TextLabel")
minimapTitle.Text="🗺  MAPA"; minimapTitle.Size=UDim2.new(1,0,0,18)
minimapTitle.BackgroundTransparency=1; minimapTitle.TextColor3=Color3.fromRGB(180,180,190)
minimapTitle.Font=Enum.Font.Code; minimapTitle.TextSize=11; minimapTitle.ZIndex=10
minimapTitle.Parent=Minimap

PlayerIcon = Instance.new("Frame")
PlayerIcon.Name="PlayerIcon"; PlayerIcon.BackgroundTransparency=1
PlayerIcon.Size=UDim2.new(0,12,0,12); PlayerIcon.AnchorPoint=Vector2.new(0.5,0.5)
PlayerIcon.ZIndex=12; PlayerIcon.Parent=Minimap

local piDot = Instance.new("Frame")
piDot.Size=UDim2.new(1,0,1,0); piDot.BackgroundColor3=COL.PLAYER
Instance.new("UICorner",piDot).CornerRadius=UDim.new(1,0)
piDot.ZIndex=12; piDot.Parent=PlayerIcon

-- ============================================================
--  BOTTOM BAR
-- ============================================================
local BottomRow = Instance.new("Frame")
BottomRow.Size=UDim2.new(0,590,0,40); BottomRow.Position=UDim2.new(0,20,1,-60)
BottomRow.BackgroundTransparency=1; BottomRow.Parent=MainContainer

BtnRestart = Instance.new("TextButton")
BtnRestart.Text="↺ Reiniciar"; BtnRestart.Size=UDim2.new(0,140,1,0)
BtnRestart.Position=UDim2.new(0,0,0,0); BtnRestart.BackgroundColor3=Color3.fromRGB(50,50,50)
BtnRestart.TextColor3=Color3.new(1,1,1); BtnRestart.Font=Enum.Font.Code; BtnRestart.TextSize=14
Instance.new("UICorner",BtnRestart).CornerRadius=UDim.new(0,8); BtnRestart.Parent=BottomRow

TopDownBtn = Instance.new("TextButton")
TopDownBtn.Text="📷 Vista Topo [V]"; TopDownBtn.Size=UDim2.new(0,180,1,0)
TopDownBtn.Position=UDim2.new(0,150,0,0); TopDownBtn.BackgroundColor3=Color3.fromRGB(40,40,60)
TopDownBtn.TextColor3=Color3.fromRGB(180,180,220); TopDownBtn.Font=Enum.Font.Code; TopDownBtn.TextSize=13
Instance.new("UICorner",TopDownBtn).CornerRadius=UDim.new(0,8); TopDownBtn.Parent=BottomRow

TopDownRotateBtn = Instance.new("TextButton")
TopDownRotateBtn.Text="↻ 360° [R]"; TopDownRotateBtn.Size=UDim2.new(0,120,1,0)
TopDownRotateBtn.Position=UDim2.new(0,340,0,0); TopDownRotateBtn.BackgroundColor3=Color3.fromRGB(30,30,42)
TopDownRotateBtn.TextColor3=Color3.fromRGB(90,90,110); TopDownRotateBtn.Font=Enum.Font.Code; TopDownRotateBtn.TextSize=13
Instance.new("UICorner",TopDownRotateBtn).CornerRadius=UDim.new(0,8); TopDownRotateBtn.Parent=BottomRow

local MenuBtn = Instance.new("TextButton")
MenuBtn.Text="⬅ Menu"; MenuBtn.Size=UDim2.new(0,110,1,0); MenuBtn.Position=UDim2.new(0,470,0,0)
MenuBtn.BackgroundColor3=Color3.fromRGB(50,50,60); MenuBtn.TextColor3=Color3.new(1,1,1)
MenuBtn.Font=Enum.Font.Code; MenuBtn.TextSize=14
Instance.new("UICorner",MenuBtn).CornerRadius=UDim.new(0,8); MenuBtn.Parent=BottomRow

-- ============================================================
--  TOP-DOWN CAMERA
-- ============================================================
local topDownLabels = {}

local function clearTopDownLabels()
	for _, bg in ipairs(topDownLabels) do
		if bg and bg.Parent then bg:Destroy() end
	end
	topDownLabels = {}
end

local function spawnTopDownLabels()
	clearTopDownLabels()
	if not gameState.nodes then return end
	for _, name in ipairs(gameState.nodes) do
		local part = findNodePartByName(name)
		-- FIX: use guard instead of `continue` (not valid in Roblox Lua 5.1)
		if part then
			local bg = Instance.new("BillboardGui")
			bg.Name           = "TopDownNodeLabel"
			bg.Size           = UDim2.new(0, 80, 0, 26)
			bg.StudsOffset    = Vector3.new(0, 7, 0)
			bg.AlwaysOnTop    = true
			bg.LightInfluence = 0
			-- FIX: BillboardGui.Adornee must be a BasePart, not a Model.
			-- The previous code passed the Model itself when PrimaryPart was nil,
			-- which silently fails to render the label.
			local adornee
			if part:IsA("BasePart") then
				adornee = part
			elseif part:IsA("Model") then
				adornee = part.PrimaryPart
				if not adornee then
					for _, d in ipairs(part:GetDescendants()) do
						if d:IsA("BasePart") then adornee = d; break end
					end
				end
			end
			if not adornee then
				-- No usable BasePart found; skip this label
			else
			bg.Adornee        = adornee
			bg.Parent         = Workspace

			local bg2 = Instance.new("Frame")
			bg2.Size = UDim2.new(1, 0, 1, 0)
			bg2.BackgroundColor3 = Color3.fromRGB(20, 20, 28)
			bg2.BackgroundTransparency = 0.25
			bg2.BorderSizePixel = 0
			Instance.new("UICorner", bg2).CornerRadius = UDim.new(0, 5)
			bg2.Parent = bg

			local lbl = Instance.new("TextLabel")
			lbl.Size                  = UDim2.new(1, -6, 1, 0)
			lbl.Position              = UDim2.new(0, 3, 0, 0)
			lbl.BackgroundTransparency= 1
			lbl.Text                  = name
			lbl.TextColor3            = Color3.new(1, 1, 1)
			lbl.TextStrokeColor3      = Color3.fromRGB(20, 20, 28)
			lbl.TextStrokeTransparency= 0.3
			lbl.Font                  = Enum.Font.GothamBold
			lbl.TextSize              = 14
			lbl.TextScaled            = false
			lbl.ZIndex                = 2
			lbl.Parent                = bg2

			table.insert(topDownLabels, bg)
			end -- if adornee
		end -- if part
	end
end

local function getMapCenter()
	if not gameState.nodes then return Vector3.new(0,0,0) end
	local sx,sy,sz,c = 0,0,0,0
	for _, name in ipairs(gameState.nodes) do
		local pos=getNodePosition(name); sx=sx+pos.X; sy=sy+pos.Y; sz=sz+pos.Z; c=c+1
	end
	if c==0 then return Vector3.new(0,0,0) end
	return Vector3.new(sx/c, sy/c, sz/c)
end

local function applyTopDownCamera()
	local cam = Workspace.CurrentCamera
	if cam.CameraType ~= Enum.CameraType.Scriptable then return end
	local rot = CFrame.Angles(0, 0, math.rad(topDownRotation))
	local char = player.Character
	if char and char:FindFirstChild("HumanoidRootPart") then
		local p = char.HumanoidRootPart.Position
		local target = CFrame.new(Vector3.new(p.X, p.Y+topDownZoom, p.Z), p) * rot
		cam.CFrame = cam.CFrame:Lerp(target, 0.08)
	else
		local c = getMapCenter()
		cam.CFrame = CFrame.new(Vector3.new(c.X,c.Y+topDownZoom,c.Z), c) * rot
	end
end

local function setTopDown(enabled)
	topDownEnabled = enabled
	local cam = Workspace.CurrentCamera
	if enabled then
		cam.CameraType = Enum.CameraType.Scriptable
		TopDownBtn.BackgroundColor3       = Color3.fromRGB(55,138,221)
		TopDownBtn.TextColor3             = Color3.new(1,1,1)
		TopDownBtn.Text                   = "📷 Vista Normal [V]"
		TopDownRotateBtn.BackgroundColor3 = Color3.fromRGB(40,80,55)
		TopDownRotateBtn.TextColor3       = Color3.fromRGB(160,230,180)
		applyTopDownCamera()
		spawnTopDownLabels()
	else
		cam.CameraType = Enum.CameraType.Custom
		task.defer(function()
			local char2 = player.Character
			if char2 and char2:FindFirstChild("HumanoidRootPart") then
				local hrp = char2.HumanoidRootPart
				cam.CFrame = CFrame.new(
					hrp.Position + Vector3.new(0, 5, 10),
					hrp.Position
				)
			end
		end)
		topDownZoom     = TOP_DOWN_HEIGHT
		rotateIdx       = 1
		topDownRotation = 0
		TopDownBtn.BackgroundColor3       = Color3.fromRGB(40,40,60)
		TopDownBtn.TextColor3             = Color3.fromRGB(180,180,220)
		TopDownBtn.Text                   = "📷 Vista Topo [V]"
		TopDownRotateBtn.BackgroundColor3 = Color3.fromRGB(30,30,42)
		TopDownRotateBtn.TextColor3       = Color3.fromRGB(90,90,110)
		TopDownRotateBtn.Text             = "↻ 360° [R]"
		clearTopDownLabels()
	end
end

local function cycleTopDownRotation()
	if not topDownEnabled then return end
	rotateIdx = (rotateIdx % #ROTATE_STEPS) + 1
	topDownRotation = ROTATE_STEPS[rotateIdx]
	local display = topDownRotation == 0 and 360 or topDownRotation
	TopDownRotateBtn.Text = "↻ " .. display .. "° [R]"
end

TopDownBtn.MouseButton1Click:Connect(function() setTopDown(not topDownEnabled) end)
TopDownRotateBtn.MouseButton1Click:Connect(cycleTopDownRotation)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.V then setTopDown(not topDownEnabled) end
	if input.KeyCode == Enum.KeyCode.R and topDownEnabled then cycleTopDownRotation() end
end)

UserInputService.InputChanged:Connect(function(input)
	if not topDownEnabled then return end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		topDownZoom = math.clamp(topDownZoom - input.Position.Z * 15, TOP_DOWN_MIN, TOP_DOWN_MAX)
	end
end)

-- ============================================================
--  OVERLAYS
-- ============================================================
FlashOverlay = Instance.new("Frame")
FlashOverlay.Size=UDim2.new(1,0,1,0); FlashOverlay.BackgroundTransparency=1; FlashOverlay.ZIndex=10
FlashOverlay.Parent=ScreenGui

Overlay = Instance.new("Frame")
Overlay.Size=UDim2.new(1,0,1,0); Overlay.BackgroundTransparency=1
Overlay.Visible=false; Overlay.ZIndex=100; Overlay.Parent=ScreenGui

OvBox = Instance.new("Frame")
OvBox.Size=UDim2.new(0,380,0,340); OvBox.Position=UDim2.new(0.5,-190,0.5,-170)
OvBox.BackgroundColor3=Color3.fromRGB(245,245,248); OvBox.BorderSizePixel=0
Instance.new("UICorner",OvBox).CornerRadius=UDim.new(0,16)
local ovS=Instance.new("UIStroke",OvBox); ovS.Color=Color3.fromRGB(200,200,200); ovS.Thickness=1; ovS.Transparency=0.8
OvBox.Parent=Overlay

OvIcon  = makeLabel(OvBox,"🎉",Enum.Font.GothamBold,44,Color3.fromRGB(30,30,30),UDim2.new(0,0,0,20),UDim2.new(1,0,0,60))
OvTitle = makeLabel(OvBox,"Missão Completa!",Enum.Font.GothamBlack,24,Color3.fromRGB(20,20,20),UDim2.new(0,20,0,80),UDim2.new(1,-40,0,30))
OvTitle.TextWrapped=true

OvBody = Instance.new("TextLabel")
OvBody.Text="-"; OvBody.Size=UDim2.new(1,-40,0,140); OvBody.Position=UDim2.new(0,20,0,118)
OvBody.BackgroundTransparency=1; OvBody.TextColor3=Color3.fromRGB(60,60,60)
OvBody.Font=Enum.Font.GothamMedium; OvBody.TextSize=15; OvBody.TextWrapped=true
OvBody.LineHeight=1.3; OvBody.Parent=OvBox

OvNext = Instance.new("TextButton")
OvNext.Text="Jogar Novamente →"; OvNext.Size=UDim2.new(0,220,0,44); OvNext.Position=UDim2.new(0.5,-110,1,-60)
OvNext.BackgroundColor3=Color3.fromRGB(29,158,117); OvNext.TextColor3=Color3.new(1,1,1)
OvNext.Font=Enum.Font.GothamBold; OvNext.TextSize=16
Instance.new("UICorner",OvNext).CornerRadius=UDim.new(0,10); OvNext.Parent=OvBox

FailOverlay = Instance.new("Frame")
FailOverlay.Size=UDim2.new(1,0,1,0); FailOverlay.BackgroundTransparency=1
FailOverlay.Visible=false; FailOverlay.ZIndex=110; FailOverlay.Parent=ScreenGui

local FailBox = Instance.new("Frame")
FailBox.Size=UDim2.new(0,300,0,180); FailBox.Position=UDim2.new(0.5,-150,0.5,-90)
FailBox.BackgroundColor3=Color3.fromRGB(255,245,245); FailBox.BorderSizePixel=0
Instance.new("UICorner",FailBox).CornerRadius=UDim.new(0,16)
Instance.new("UIStroke",FailBox).Color=Color3.fromRGB(220,80,80); FailBox.Parent=FailOverlay

makeLabel(FailBox,"⏰",Enum.Font.GothamBold,50,Color3.fromRGB(200,50,50),UDim2.new(0,0,0,15),UDim2.new(1,0,0,50))
makeLabel(FailBox,"Missão Falhou!",Enum.Font.GothamBlack,24,Color3.fromRGB(200,50,50),UDim2.new(0,0,0,70),UDim2.new(1,0,0,30))
makeLabel(FailBox,"O tempo acabou. Tente novamente!",Enum.Font.GothamMedium,14,Color3.fromRGB(100,100,100),UDim2.new(0,20,0,105),UDim2.new(1,-40,0,30))

FailRestartBtn = Instance.new("TextButton")
FailRestartBtn.Text="↺ Tentar Novamente"; FailRestartBtn.Size=UDim2.new(0,180,0,40)
FailRestartBtn.Position=UDim2.new(0.5,-90,1,-52); FailRestartBtn.BackgroundColor3=Color3.fromRGB(220,80,80)
FailRestartBtn.TextColor3=Color3.new(1,1,1); FailRestartBtn.Font=Enum.Font.GothamBold; FailRestartBtn.TextSize=14
Instance.new("UICorner",FailRestartBtn).CornerRadius=UDim.new(0,10); FailRestartBtn.Parent=FailBox

-- ============================================================
--  FREE ROAM MENU BUTTON (shown only during Free Roam)
-- ============================================================
-- This is a minimal floating button so the player can return to
-- the start menu at any time without any other game UI visible.
FreeRoamMenuBtn = Instance.new("TextButton")
FreeRoamMenuBtn.Text              = "⬅  Menu"
FreeRoamMenuBtn.Size              = UDim2.new(0, 120, 0, 40)
FreeRoamMenuBtn.Position          = UDim2.new(0, 20, 1, -60)
FreeRoamMenuBtn.BackgroundColor3  = Color3.fromRGB(30, 30, 42)
FreeRoamMenuBtn.TextColor3        = Color3.fromRGB(200, 200, 220)
FreeRoamMenuBtn.Font              = Enum.Font.GothamBold
FreeRoamMenuBtn.TextSize          = 14
FreeRoamMenuBtn.ZIndex            = 50
FreeRoamMenuBtn.Visible           = false
Instance.new("UICorner", FreeRoamMenuBtn).CornerRadius = UDim.new(0, 10)
local frmStroke = Instance.new("UIStroke", FreeRoamMenuBtn)
frmStroke.Color = Color3.fromRGB(80, 80, 120); frmStroke.Thickness = 1; frmStroke.Transparency = 0.4
FreeRoamMenuBtn.Parent = ScreenGui

-- ============================================================
--  FREE ROAM DESTRUCTIBLE BUTTON
-- ============================================================
-- Visible only during Free Roam. Toggles server-side destructible mode
-- so explosions can knock all anchored parts around. Press again to
-- restore everything.
local destructibleActive = false

local FreeRoamDestroyBtn = Instance.new("TextButton")
FreeRoamDestroyBtn.Text             = "💥 Modo Destruição"
FreeRoamDestroyBtn.Size             = UDim2.new(0, 180, 0, 40)
FreeRoamDestroyBtn.Position         = UDim2.new(0, 150, 1, -60)  -- right of Menu btn
FreeRoamDestroyBtn.BackgroundColor3 = Color3.fromRGB(100, 30, 30)
FreeRoamDestroyBtn.TextColor3       = Color3.fromRGB(255, 200, 200)
FreeRoamDestroyBtn.Font             = Enum.Font.GothamBold
FreeRoamDestroyBtn.TextSize         = 14
FreeRoamDestroyBtn.ZIndex           = 50
FreeRoamDestroyBtn.Visible          = false
Instance.new("UICorner", FreeRoamDestroyBtn).CornerRadius = UDim.new(0, 10)
local frdStroke = Instance.new("UIStroke", FreeRoamDestroyBtn)
frdStroke.Color = Color3.fromRGB(200, 60, 60); frdStroke.Thickness = 1.5; frdStroke.Transparency = 0.3
FreeRoamDestroyBtn.Parent = ScreenGui

-- Visual feedback: update button appearance based on current state
local function refreshDestroyBtn()
	if destructibleActive then
		FreeRoamDestroyBtn.BackgroundColor3 = Color3.fromRGB(200, 50,  20)
		FreeRoamDestroyBtn.TextColor3       = Color3.fromRGB(255, 255, 200)
		FreeRoamDestroyBtn.Text             = "🔧 Restaurar Tudo"
		frdStroke.Color                     = Color3.fromRGB(255, 120, 40)
	else
		FreeRoamDestroyBtn.BackgroundColor3 = Color3.fromRGB(100, 30,  30)
		FreeRoamDestroyBtn.TextColor3       = Color3.fromRGB(255, 200, 200)
		FreeRoamDestroyBtn.Text             = "💥 Modo Destruição"
		frdStroke.Color                     = Color3.fromRGB(200, 60,  60)
	end
end

FreeRoamDestroyBtn.MouseButton1Click:Connect(function()
	destructibleActive = not destructibleActive
	SetDestructible:FireServer(destructibleActive)
	-- Optimistic update — server will confirm via FireAllClients
	refreshDestroyBtn()
end)

-- Server confirmation: sync button state if another client toggled it
SetDestructible.OnClientEvent:Connect(function(serverState)
	destructibleActive = serverState
	refreshDestroyBtn()
end)


local function clearEdges()
	for _, p in ipairs(edgeParts) do p:Destroy() end; edgeParts = {}
end
local function clearHighlights()
	for _, h in ipairs(activeHighlights) do h:Destroy() end; activeHighlights = {}
end
local function clearPrompts()
	for _, p in ipairs(activePrompts) do p:Destroy() end; activePrompts = {}
end
local function buildVisitedSet()
	local s={}; for _, n in ipairs(gameState.visited or {}) do s[n]=true end; return s
end

-- ============================================================
--  3D EDGE DRAWING
-- ============================================================
local function draw3DEdges()
	clearEdges()
	if not gameState.edges then return end

	local trailMap = buildTrailMap(gameState.moveLog)

	local visitedOrder = gameState.visitedOrder or {}
	local walkedSet = {}
	for i = 2, #visitedOrder do
		local a, b = visitedOrder[i-1], visitedOrder[i]
		local key  = a < b and (a.."__"..b) or (b.."__"..a)
		walkedSet[key] = true
	end

	local optSet = {}
	if gameState.done and gameState.optimalPath then
		local op = gameState.optimalPath
		for i = 2, #op do
			local a, b = op[i-1], op[i]
			local key = a < b and (a.."__"..b) or (b.."__"..a)
			optSet[key] = true
		end
	end

	for _, edge in ipairs(gameState.edges) do
		local n1, n2, w = edge[1], edge[2], edge[3]
		local p1 = getNodePosition(n1); local p2 = getNodePosition(n2)
		local dist = (p1-p2).Magnitude
		if dist >= 0.1 then

		local key     = n1 < n2 and (n1.."__"..n2) or (n2.."__"..n1)
		local walked  = walkedSet[key]
		local isOpt   = trailMap[key]

		local edgeColor, edgeThick, edgeTrans
		if gameState.done and optSet[key] then
			edgeColor = COL.GOLD; edgeThick = 1.2; edgeTrans = 0
		elseif walked and isOpt == true then
			edgeColor = COL.OPTIMAL; edgeThick = 1; edgeTrans = 0
		elseif walked and isOpt == false then
			edgeColor = COL.WRONG; edgeThick = 1; edgeTrans = 0
		else
			edgeColor = COL.UNVISITED; edgeThick = 0.5; edgeTrans = 0.55
		end

		local ep = Instance.new("Part")
		ep.Size     = Vector3.new(edgeThick, edgeThick, dist)
		ep.CFrame   = CFrame.lookAt(p1,p2) * CFrame.new(0,0,-dist/2)
		ep.Anchored = true; ep.CanCollide = false; ep.CanQuery = false
		ep.Material = Enum.Material.Neon
		ep.Color    = edgeColor; ep.Transparency = edgeTrans
		ep.Name     = "dijkstraEdge_" .. key
		ep.Parent   = Workspace
		table.insert(edgeParts, ep)

		local bg  = Instance.new("BillboardGui")
		bg.Size   = UDim2.new(0,60,0,30); bg.StudsOffset = Vector3.new(0,8,0); bg.AlwaysOnTop = true
		local txt = Instance.new("TextLabel")
		txt.Size=UDim2.new(1,0,1,0); txt.BackgroundTransparency=0.2
		txt.BackgroundColor3=Color3.fromRGB(40,40,40); txt.TextColor3=Color3.new(1,1,1)
		txt.Font=Enum.Font.Code; txt.TextSize=24; txt.Text=tostring(w)
		Instance.new("UICorner",txt).CornerRadius=UDim.new(0,4)
		txt.Parent=bg; bg.Parent=ep
		end -- if dist >= 0.1
	end
end

-- ============================================================
--  MINIMAP DRAWING
-- ============================================================
local function drawMinimap()
	for _, c in ipairs(Minimap:GetChildren()) do
		if not c:IsA("UICorner") and c.Name~="PlayerIcon" and c~=minimapTitle then c:Destroy() end
	end
	if not gameState.nodes then return end

	local nodePos = {}
	local mnX, mnZ =  math.huge,  math.huge
	local mxX, mxZ = -math.huge, -math.huge
	for _, name in ipairs(gameState.nodes) do
		local pos = getNodePosition(name)
		nodePos[name] = {x=pos.X, z=pos.Z}
		if pos.X<mnX then mnX=pos.X end; if pos.X>mxX then mxX=pos.X end
		if pos.Z<mnZ then mnZ=pos.Z end; if pos.Z>mxZ then mxZ=pos.Z end
	end
	mnX=mnX-20; mxX=mxX+20; mnZ=mnZ-20; mxZ=mxZ+20
	local rX=math.max(mxX-mnX,1); local rZ=math.max(mxZ-mnZ,1)
	minimapMinX=mnX; minimapMinZ=mnZ; minimapRangeX=rX; minimapRangeZ=rZ

	local trailMap = buildTrailMap(gameState.moveLog)

	local visitedOrder = gameState.visitedOrder or {}
	local walkedSet = {}
	for i = 2, #visitedOrder do
		local a, b = visitedOrder[i-1], visitedOrder[i]
		local key = a < b and (a.."__"..b) or (b.."__"..a)
		walkedSet[key] = true
	end

	local optSet = {}
	if gameState.done and gameState.optimalPath then
		local op = gameState.optimalPath
		for i = 2, #op do
			local a, b = op[i-1], op[i]
			local key = a < b and (a.."__"..b) or (b.."__"..a)
			optSet[key] = true
		end
	end

	if gameState.edges then
		for _, edge in ipairs(gameState.edges) do
			local n1, n2, w = edge[1], edge[2], edge[3]
			local np1=nodePos[n1]; local np2=nodePos[n2]
			if np1 and np2 then
			local p1x=1-(np1.x-mnX)/rX; local p1z=1-(np1.z-mnZ)/rZ
			local p2x=1-(np2.x-mnX)/rX; local p2z=1-(np2.z-mnZ)/rZ

			local key    = n1<n2 and (n1.."__"..n2) or (n2.."__"..n1)
			local walked = walkedSet[key]
			local isOpt  = trailMap[key]

			local lineColor, thick, trans, zIdx
			if gameState.done and optSet[key] then
				lineColor=COL.GOLD; thick=3; trans=0; zIdx=4
			elseif walked and isOpt==true then
				lineColor=COL.OPTIMAL; thick=3; trans=0; zIdx=3
			elseif walked and isOpt==false then
				lineColor=COL.WRONG; thick=3; trans=0; zIdx=3
			else
				lineColor=COL.UNVISITED; thick=1; trans=0.5; zIdx=1
			end

			local dx=p2x-p1x; local dz=p2z-p1z
			local mapSize = math.max(Minimap.AbsoluteSize.X, 1)  -- FIX: AbsoluteSize is 0 before first render
			local mag=math.sqrt(dx*dx+dz*dz)*mapSize
			local angle=math.deg(math.atan2(dz,dx))

			local line=Instance.new("Frame")
			line.BorderSizePixel=0; line.BackgroundColor3=lineColor
			line.BackgroundTransparency=trans; line.ZIndex=zIdx
			line.Size=UDim2.new(0,mag,0,thick)
			line.Position=UDim2.new((p1x+p2x)/2,0,(p1z+p2z)/2,0)
			line.AnchorPoint=Vector2.new(0.5,0.5); line.Rotation=angle; line.Parent=Minimap

			local costLbl=Instance.new("TextLabel")
			costLbl.Size=UDim2.new(0,24,0,13)
			costLbl.Position=UDim2.new((p1x+p2x)/2,0,(p1z+p2z)/2,0)
			costLbl.AnchorPoint=Vector2.new(0.5,0.5)
			costLbl.Text=tostring(w); costLbl.BackgroundColor3=Color3.fromRGB(40,40,40)
			costLbl.TextColor3=Color3.new(1,1,1); costLbl.Font=Enum.Font.Code
			costLbl.TextSize=10; costLbl.ZIndex=5
			Instance.new("UICorner",costLbl).CornerRadius=UDim.new(0,3)
			costLbl.Parent=Minimap
			end -- if np1 and np2
		end
	end

	local visitedSet = buildVisitedSet()
	for _, name in ipairs(gameState.nodes) do
		local np = nodePos[name]
		if np then
		local px=1-(np.x-mnX)/rX; local pz=1-(np.z-mnZ)/rZ
		local dot=Instance.new("Frame")
		dot.AnchorPoint=Vector2.new(0.5,0.5); dot.ZIndex=6
		Instance.new("UICorner",dot).CornerRadius=UDim.new(1,0)
		local isPlayer = name==gameState.playerPos
		local isEnd    = name==gameState.endName
		if isPlayer then
			dot.BackgroundColor3=COL.PLAYER; dot.Size=UDim2.new(0,14,0,14)
		elseif isEnd then
			dot.BackgroundColor3=COL.END_NODE; dot.Size=UDim2.new(0,12,0,12)
		elseif visitedSet[name] then
			dot.BackgroundColor3=COL.VISITED; dot.Size=UDim2.new(0,10,0,10)
		else
			dot.BackgroundColor3=Color3.fromRGB(100,100,110); dot.Size=UDim2.new(0,8,0,8)
		end
		dot.Position=UDim2.new(px,0,pz,0); dot.Parent=Minimap
		local lbl=Instance.new("TextLabel")
		lbl.Text=name; lbl.Size=UDim2.new(0,50,0,12)
		lbl.Position=UDim2.new(0.5,0,1,2); lbl.AnchorPoint=Vector2.new(0.5,0)
		lbl.BackgroundTransparency=1; lbl.TextColor3=Color3.new(1,1,1)
		lbl.Font=Enum.Font.Code; lbl.TextSize=10; lbl.ZIndex=7; lbl.Parent=dot
		end -- if np
	end
end

-- ============================================================
--  NEIGHBOUR HIGHLIGHTS
-- ============================================================
local function applyNeighborHighlights()
	clearHighlights()
	if not gameState.neighbors then return end
	for _, nb in ipairs(gameState.neighbors) do
		local part = getNodeBasePart(nb[1])
		if part then
		local hl = Instance.new("Highlight")
		hl.Adornee=part; hl.FillTransparency=1
		hl.OutlineColor=Color3.new(1,1,1); hl.OutlineTransparency=0; hl.Parent=part
		table.insert(activeHighlights, hl)
		TweenService:Create(hl,TweenInfo.new(1,Enum.EasingStyle.Sine,Enum.EasingDirection.InOut,-1,true),
			{OutlineTransparency=0.8}):Play()
		end -- if part
	end
end

-- ============================================================
--  PROXIMITY PROMPTS
-- ============================================================
local function applyPrompts()
	clearPrompts()
	if not gameState.neighbors then return end
	for _, nb in ipairs(gameState.neighbors) do
		local name, cost = nb[1], nb[2]
		local part = getNodeBasePart(name)
		if part then
			local prompt = Instance.new("ProximityPrompt")
			prompt.ActionText="Ir  (+"..tostring(cost)..")"
			prompt.ObjectText=name
			prompt.KeyboardKeyCode=Enum.KeyCode.E
			prompt.MaxActivationDistance=8; prompt.RequiresLineOfSight=false
			prompt.Parent=part
			local cn = name
			prompt.Triggered:Connect(function() SelectNode:FireServer(cn) end)
			table.insert(activePrompts, prompt)
		end -- if part
	end
end

-- ============================================================
--  FEEDBACK FLASH
-- ============================================================
local function triggerFeedbackFlash(isOptimal, edgeCost)
	local char = player.Character
	if not char or not char:FindFirstChild("HumanoidRootPart") then return end
	local rootPos = char.HumanoidRootPart.Position
	local headPos = (char:FindFirstChild("Head") and char.Head.Position)
		or (rootPos + Vector3.new(0,2,0))

	local flashColor = isOptimal and Color3.fromRGB(100,255,150) or COL.WRONG

	local f = Instance.new("Frame")
	f.Size=UDim2.new(1,0,1,0); f.BackgroundColor3=flashColor
	f.BackgroundTransparency=0.85; f.ZIndex=9; f.Parent=ScreenGui
	TweenService:Create(f,TweenInfo.new(isOptimal and 0.5 or 0.6, Enum.EasingStyle.Cubic),{BackgroundTransparency=1}):Play()
	game.Debris:AddItem(f, 0.7)

	if isOptimal then
		CreateFloatingText("✔ ÓTIMO!", COL.OPTIMAL, headPos)
		CreatePulse(rootPos - Vector3.new(0,2.5,0), COL.OPTIMAL)
		playSound("RightNode")
	else
		local offset = Vector3.new(math.random(-2,2), 0, math.random(-2,2))
		CreateFloatingText("✘ ERROU! +" .. tostring(edgeCost), COL.WRONG, headPos + offset)
		CreatePulse(rootPos - Vector3.new(0,2.5,0), COL.WRONG)
		playSound("WrongNode")
	end
end

-- ============================================================
--  GAME STATE HANDLER
-- ============================================================
local prevPlayerPos = nil
local prevPenalty   = 0

GameStateRemote.OnClientEvent:Connect(function(data)
	-- FIX: ignore server-initiated fires until the player explicitly starts.
	-- This prevents CharacterAdded respawn fires from bypassing the StartMenu.
	-- Also silently ignore if the player is in free roam.
	if not gameStarted or freeRoamActive then return end

	local isNewRound = data.visitedOrder and #data.visitedOrder == 1

	if isNewRound then
		-- FIX: reset prevPlayerPos BEFORE any further processing so the
		-- first movement of the new round is correctly detected below.
		prevPlayerPos = nil
		prevPenalty   = 0
		invalidatePartsCache()
		clearConnLog()
		stopTimer()
	end

	local prevPos  = prevPlayerPos
	prevPlayerPos  = data.playerPos
	gameState      = data

	-- Show game UI, unless the player intentionally opened the Menu screen
	-- (a respawn mid-round can still fire this event; we keep gameState in
	-- sync in the background but don't yank the player out of the menu).
	if not viewingMenu then
		StartMenu.Visible = false; MainContainer.Visible = true
		Overlay.Visible   = false
	end
	-- FIX: don't blindly hide the timeout FailOverlay on every payload.
	-- The server doesn't enforce the timer, so a player can keep moving
	-- after time runs out; previously that next move's GameStateRemote
	-- event would silently dismiss the "time's up" overlay. Only clear it
	-- when the round actually ends or a new round begins.
	if isNewRound or data.done then
		FailOverlay.Visible = false
	end

	-- Stats
	ValCost.Text  = tostring(data.playerCost  or 0)
	ValOpt.Text   = tostring(data.optimalCost or "?")
	ValPen.Text   = "+" .. tostring(data.penaltyTotal or 0)
	ValRound.Text = tostring(data.roundNum    or 1)
	ValTotal.Text = tostring(data.totalScore  or 0)

	-- Mission card
	if data.startName and data.endName then
		local modeTxt = (data.mode=="random") and "🔀 Aleatório" or "📍 Padrão"
		MText.Text = "🎯 Chegue até:  " .. data.endName
		MSub.Text  = "De: "..(data.startName or "?").."  →  Para: "..(data.endName or "?").."   |   Modo: "..modeTxt
	end

	-- Timer: only start on a fresh round with a valid path
	if isNewRound and data.optimalPath and #data.optimalPath > 1 then
		startTimer(#data.optimalPath - 1)
	end

	-- Movement detection: sync connectionLog from authoritative server moveLog
	if not isNewRound and prevPos and data.playerPos and prevPos ~= data.playerPos then
		connectionLog = {}
		local ml = data.moveLog or {}
		for _, entry in ipairs(ml) do
			table.insert(connectionLog, {
				from       = entry.from,
				to         = entry.to,
				cost       = entry.cost,
				wasOptimal = entry.wasOptimal,
			})
		end
		rebuildConnUI()

		local lastMove = ml[#ml]
		if lastMove then
			triggerFeedbackFlash(lastMove.wasOptimal, lastMove.cost)
		end
		prevPenalty = data.penaltyTotal or 0
	end

	applyNeighborHighlights()
	applyPrompts()
	draw3DEdges()
	drawMinimap()

	if topDownEnabled then applyTopDownCamera() end

	-- End-of-round overlay
	if data.done then
		stopTimer()
		if topDownEnabled then setTopDown(false) end

		local diff       = (data.playerCost or 0) - (data.optimalCost or 0)
		local perfect    = (diff == 0 and (data.penaltyTotal or 0) == 0)
		local roundScore = data.roundScore or 0
		local totalScore = data.totalScore or 0

		OvIcon.Text  = perfect and "🏆" or (diff <= math.max(1,(data.optimalCost or 1)*0.2) and "🎯" or "📚")
		OvTitle.Text = perfect and "Caminho Perfeito!" or "Destino Alcançado!"
		-- FIX: diff is always >= 0 (player can't beat Dijkstra), but guard the sign
		-- prefix so the display never reads "Diferença: +-1" or "+0" on a perfect run.
		local diffStr = (diff > 0) and ("+" .. diff) or tostring(diff)
		OvBody.Text  = string.format(
			"Seu custo: %d\nIdeal: %d  |  Diferença: %s\nPenalidade: +%d\nScore da rodada: %d\nPlacar total: %d\n\n%s",
			data.playerCost or 0, data.optimalCost or 0, diffStr,
			data.penaltyTotal or 0, roundScore, totalScore,
			perfect and "Você seguiu o caminho exato de Dijkstra! 🧠"
				or (diff==0 and "Custo ótimo, mas tomou desvios!"
					or ("Você pagou "..diff.." a mais. Tente o caminho mais barato!"))
		)
		Overlay.Visible=true; clearPrompts(); clearHighlights()
		playSound(perfect and "Success" or "Fail")
		-- Dedicated overlay sounds for mission complete / fail screens
		task.delay(0.15, function()
			playSound(perfect and "MissionComplete" or "MissionFail")
		end)
		drawMinimap()
	end
end)

-- ============================================================
--  FREE ROAM
-- ============================================================
local function enterFreeRoam()
	freeRoamActive = true
	gameStarted    = false      -- prevent stale GameStateRemote events from showing game UI
	viewingMenu    = false

	-- Hide everything game-related
	StartMenu.Visible         = false
	MainContainer.Visible     = false
	Overlay.Visible           = false
	FailOverlay.Visible       = false

	-- Restore normal camera just in case top-down was active
	if topDownEnabled then setTopDown(false) end
	stopTimer()

	-- Remove any lingering 3D decorations from a previous game session
	clearEdges()
	clearHighlights()
	clearPrompts()

	-- Show only the tiny return button and the destroy toggle
	FreeRoamMenuBtn.Visible     = true
	FreeRoamDestroyBtn.Visible  = true
end

local function exitFreeRoam()
	-- If destructible mode is still active when leaving, auto-restore
	if destructibleActive then
		destructibleActive = false
		SetDestructible:FireServer(false)
		refreshDestroyBtn()
	end
	freeRoamActive              = false
	FreeRoamMenuBtn.Visible     = false
	FreeRoamDestroyBtn.Visible  = false
	StartMenu.Visible           = true
	MainContainer.Visible       = false
end

FreeRoamMenuBtn.MouseButton1Click:Connect(exitFreeRoam)

-- ============================================================
--  BUTTONS
-- ============================================================
local function requestNewRound()
	prevPlayerPos=nil; prevPenalty=0
	Overlay.Visible=false; FailOverlay.Visible=false
	ResetGame:FireServer()
end

BtnRestart.MouseButton1Click:Connect(requestNewRound)
OvNext.MouseButton1Click:Connect(requestNewRound)
FailRestartBtn.MouseButton1Click:Connect(requestNewRound)

BtnFreeRoam.MouseButton1Click:Connect(enterFreeRoam)

MenuBtn.MouseButton1Click:Connect(function()
	MainContainer.Visible=false; StartMenu.Visible=true
	freeRoamActive=false; FreeRoamMenuBtn.Visible=false; FreeRoamDestroyBtn.Visible=false
	stopTimer(); if topDownEnabled then setTopDown(false) end
	viewingMenu = true
	-- Note: gameStarted stays true so respawn fires are still handled
end)

BtnStart.MouseButton1Click:Connect(function()
	-- FIX: set the flag BEFORE firing remotes, so the response from
	-- ResetGame is processed correctly.
	gameStarted = true
	viewingMenu = false
	StartMenu.Visible=false; MainContainer.Visible=true
	SetMode:FireServer(selectedMode); ResetGame:FireServer()
end)

-- ============================================================
--  RENDER LOOP
-- ============================================================
RunService.RenderStepped:Connect(function(dt)
	-- Only update minimap player icon when the game UI is visible
	if not freeRoamActive and gameStarted and MainContainer.Visible then
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			local pos = char.HumanoidRootPart.Position
			PlayerIcon.Position = UDim2.new(
				math.clamp(1-(pos.X-minimapMinX)/minimapRangeX,0,1), 0,
				math.clamp(1-(pos.Z-minimapMinZ)/minimapRangeZ,0,1), 0)
		end
	end

	if topDownEnabled then applyTopDownCamera() end

	if timerActive then
		timerRemaining = timerRemaining - dt
		local pct = math.max(timerRemaining,0)/timerDuration
		local col = timerColor(pct)
		TimerLabel.TextColor3=col; TimerFill.BackgroundColor3=col
		TimerFill.Size=UDim2.new(math.max(pct,0),0,1,0)
		TimerLabel.Text="⏱ "..tostring(math.ceil(math.max(timerRemaining,0)))
		-- Start pulsing the bar background when time is critically low
		if pct <= TIMER_PULSE_THRESHOLD and timerPulseTween == nil then
			timerPulseTween = TweenService:Create(
				TimerBar,
				TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ BackgroundColor3 = Color3.fromRGB(110, 15, 15) }
			)
			timerPulseTween:Play()
		end
		if timerRemaining <= 0 then
			timerActive=false
			TimerFill.BackgroundColor3=Color3.fromRGB(255,0,0)
			TimerLabel.Text="⏱ 0 – TEMPO ESGOTADO!"
			-- FIX: only show fail overlay if the round hasn't already ended
			-- normally (data.done). Without this guard, a race between the
			-- last-move server event and the render loop could show both
			-- the success overlay and the fail overlay simultaneously.
			if not gameState.done then
				FailOverlay.Visible=true; clearPrompts(); clearHighlights()
				playSound("MissionFail")
			end
		end
	end
end)

print("[DijkstraClient] v15 Loaded.")
