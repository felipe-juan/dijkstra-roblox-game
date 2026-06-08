local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local GraphGenerator = require(ReplicatedStorage.Shared.GraphGenerator)

local Events = ReplicatedStorage:FindFirstChild("Events")
if not Events then
	Events = Instance.new("Folder")
	Events.Name = "Events"
	Events.Parent = ReplicatedStorage
end

local function createEvent(name)
	local ev = Events:FindFirstChild(name)
	if not ev then
		ev = Instance.new("RemoteEvent")
		ev.Name = name
		ev.Parent = Events
	end
	return ev
end

local MoveRequest = createEvent("MoveRequest")
local RestartRound = createEvent("RestartRound")
local NextRound = createEvent("NextRound")
local UpdateUI = createEvent("UpdateUI")
local PenaltyFlash = createEvent("PenaltyFlash")
local RoundEnd = createEvent("RoundEnd")
local SetMode = createEvent("SetMode")
local PlaySound = createEvent("PlaySound")

local MISSIONS = {
	{emoji="📝", verb="Entregar prova para a", types={"classroom"}},
	{emoji="🧻", verb="Repor papel higiênico no", types={"bathroom"}},
	{emoji="💐", verb="Regar as flores no", types={"courtyard"}},
	{emoji="👋", verb="Receber visitante na", types={"entrance"}},
	{emoji="📦", verb="Deixar suprimentos na", types={"classroom"}}
}

local HTML_NODES = {
  {id=0, x=60,  y=180, partName='Entrance', name='Entrada',   emoji='🚪', type='entrance'},
  {id=1, x=160, y=60,  partName='H001',     name='H001',       emoji='📋', type='classroom'},
  {id=2, x=160, y=180, partName='H002',     name='H002',       emoji='📋', type='classroom'},
  {id=3, x=160, y=300, partName='H003',     name='H003',       emoji='📋', type='classroom'},
  {id=4, x=280, y=60,  partName='H004',     name='H004',       emoji='📋', type='classroom'},
  {id=5, x=280, y=180, partName='Courtyard',name='Pátio',  emoji='🌸', type='courtyard'},
  {id=6, x=280, y=300, partName='H005',     name='H005',       emoji='📋', type='classroom'},
  {id=7, x=400, y=60,  partName='H006',     name='H006',       emoji='📋', type='classroom'},
  {id=8, x=400, y=180, partName='H007',     name='H007',       emoji='📋', type='classroom'},
  {id=9, x=400, y=300, partName='Bathroom', name='Banheiro',   emoji='🚻', type='bathroom'},
  {id=10,x=520, y=60,  partName='H008',     name='H008',       emoji='📋', type='classroom'},
  {id=11,x=520, y=180, partName='H009',     name='H009',       emoji='📋', type='classroom'},
  {id=12,x=520, y=300, partName='H010',     name='H010',       emoji='📋', type='classroom'},
}

local PlayerData = {}
local NodesList = {}
local NodeParts = {}

local function buildNodesList()
	NodesList = {}
	NodeParts = {}
	local nodesFolder = Workspace:FindFirstChild("Nodes")
	if not nodesFolder then
		nodesFolder = Instance.new("Folder")
		nodesFolder.Name = "Nodes"
		nodesFolder.Parent = Workspace
	end
	
	local template = nodesFolder:FindFirstChild("NodeTemplate")
	
	for _, n in ipairs(HTML_NODES) do
		local xPos = n.x
		local zPos = n.y
		
		local pName = n.partName or n.name
		local part = nodesFolder:FindFirstChild(pName)
		if not part then
			-- Create from template if available, otherwise fallback
			if template and template:IsA("BasePart") then
				part = template:Clone()
			else
				part = Instance.new("Part")
				part.Shape = Enum.PartType.Ball
				part.Size = Vector3.new(8, 8, 8)
				part.Color = Color3.fromRGB(55, 138, 221)
				part.Material = Enum.Material.Neon
				part.Anchored = true
				part.CanCollide = false
			end
			part.Name = pName
			part.Position = Vector3.new(xPos, 5, zPos)
			part.Parent = nodesFolder
		end
		
		-- Create a copy of the node
		local nodeCopy = {
			id = n.id,
			name = n.name,
			partName = pName,
			type = n.type,
			emoji = n.emoji,
			x = part.Position.X,
			y = part.Position.Y,
			z = part.Position.Z
		}
		
		NodeParts[n.id] = part
		
		-- Ensure billboard GUI
		local bg = part:FindFirstChild("NodeBillboard")
		if bg then bg:Destroy() end
		bg = Instance.new("BillboardGui")
		bg.Name = "NodeBillboard"
		bg.Size = UDim2.new(0, 100, 0, 50)
		bg.StudsOffset = Vector3.new(0, 4, 0)
		bg.AlwaysOnTop = true
		
		local tl = Instance.new("TextLabel")
		tl.Size = UDim2.new(1, 0, 1, 0)
		tl.BackgroundTransparency = 1
		tl.Text = n.emoji .. " " .. n.name
		tl.TextColor3 = Color3.new(1,1,1)
		tl.TextStrokeTransparency = 0
		tl.TextScaled = true
		tl.Font = Enum.Font.GothamBold
		tl.Parent = bg
		
		bg.Parent = part
		
		table.insert(NodesList, nodeCopy)
	end
	
	if template then template:Destroy() end
end

buildNodesList()

local function initRound(player)
	local data = PlayerData[player.UserId]
	if not data then
		data = { totalScore = 0, roundNum = 1, mode = "Dijkstra" }
		PlayerData[player.UserId] = data
	end
	
	data.done = false
	
	if data.mode == "FreeRoam" then
		data.adj = {}
		data.edgeMap = {}
		data.playerPos = 1
		data.visited = {}
		UpdateUI:FireClient(player, {
			mode = "FreeRoam",
			nodes = NodesList
		})
		return
	end
	
	local adj, edgeMap = GraphGenerator.BuildGraph(NodesList)
	data.adj = adj
	data.edgeMap = edgeMap
	
	-- Pick mission
	local missionTpl = MISSIONS[math.random(#MISSIONS)]
	local candidates = {}
	for _, n in ipairs(NodesList) do
		for _, t in ipairs(missionTpl.types) do
			if n.type == t then
				table.insert(candidates, n)
				break
			end
		end
	end
	
	local dst = candidates[math.random(#candidates)]
	local dist, prev = GraphGenerator.Dijkstra(NodesList, adj, dst.id)
	
	local validSrc = {}
	local maxEdges = 0
	local furthestSrcs = {}
	
	for _, n in ipairs(NodesList) do
		local isTplType = false
		for _, t in ipairs(missionTpl.types) do
			if n.type == t then isTplType = true break end
		end
		if not isTplType or n.type == "courtyard" then
			if n.id ~= dst.id then
				local path = GraphGenerator.TracePath(prev, n.id)
				local edges = #path - 1
				
				if edges >= 3 then
					table.insert(validSrc, n)
				end
				
				if edges > maxEdges then
					maxEdges = edges
					furthestSrcs = {n}
				elseif edges == maxEdges then
					table.insert(furthestSrcs, n)
				end
			end
		end
	end
	
	local src
	if #validSrc > 0 then
		src = validSrc[math.random(#validSrc)]
	else
		src = furthestSrcs[math.random(#furthestSrcs)]
	end
	
	data.mission = missionTpl
	data.src = src.id
	data.dst = dst.id
	data.playerPos = src.id
	data.visited = {src.id}
	data.playerCost = 0
	data.penaltyTotal = 0
	
	local dist2, prev2 = GraphGenerator.Dijkstra(NodesList, adj, src.id)
	data.optimalCost = dist2[dst.id]
	data.optimalPath = GraphGenerator.TracePath(prev2, dst.id)
	
	-- Reset all node colors, then color the start and dest nodes
	for id, part in pairs(NodeParts) do
		if id == src.id then
			part.Color = Color3.fromRGB(245, 205, 47) -- Yellow for start
		elseif id == dst.id then
			part.Color = Color3.fromRGB(80, 255, 120) -- Green for destination!
		else
			part.Color = Color3.fromRGB(55, 138, 221) -- Default Blue
		end
	end
	
	-- Teleport player
	local char = player.Character
	if char and char:FindFirstChild("HumanoidRootPart") and NodeParts[src.id] then
		char.HumanoidRootPart.CFrame = NodeParts[src.id].CFrame + Vector3.new(0, 5, 0)
	end
	
	UpdateUI:FireClient(player, {
		mode = "Dijkstra",
		nodes = NodesList,
		adj = adj,
		edgeMap = edgeMap,
		src = data.src,
		dst = data.dst,
		mission = data.mission,
		playerPos = data.playerPos,
		visited = data.visited,
		playerCost = data.playerCost,
		penaltyTotal = data.penaltyTotal,
		optimalCost = data.optimalCost,
		optimalPath = data.optimalPath,
		roundNum = data.roundNum,
		totalScore = data.totalScore
	})
end

SetMode.OnServerEvent:Connect(function(player, mode)
	if not PlayerData[player.UserId] then
		PlayerData[player.UserId] = { totalScore = 0, roundNum = 1 }
	end
	PlayerData[player.UserId].mode = mode
	initRound(player)
end)

RestartRound.OnServerEvent:Connect(function(player)
	if PlayerData[player.UserId] then
		initRound(player)
	end
end)

NextRound.OnServerEvent:Connect(function(player)
	if PlayerData[player.UserId] then
		PlayerData[player.UserId].roundNum = PlayerData[player.UserId].roundNum + 1
		initRound(player)
	end
end)

MoveRequest.OnServerEvent:Connect(function(player, destId)
	local data = PlayerData[player.UserId]
	if not data or data.done then return end
	
	if data.mode == "FreeRoam" then
		if NodeParts[destId] then
			local char = player.Character
			if char and char:FindFirstChild("HumanoidRootPart") then
				char.HumanoidRootPart.CFrame = NodeParts[destId].CFrame + Vector3.new(0, 5, 0)
			end
		end
		return
	end
	
	-- Check if valid neighbor and unvisited
	local neighbors = data.adj[data.playerPos]
	local isValid = false
	local cost = 0
	for _, edge in ipairs(neighbors) do
		if edge.v == destId then
			isValid = true
			cost = edge.w
			break
		end
	end
	
	local isVisited = table.find(data.visited, destId)
	
	if not isValid or isVisited then return end
	
	-- Check for penalty
	local bestNexts = GraphGenerator.GetBestNeighbors(NodesList, data.adj, data.playerPos, data.dst, data.visited)
	local isOptimal = false
	for _, b in ipairs(bestNexts) do
		if destId == b then isOptimal = true break end
	end
	
	if #bestNexts > 0 and not isOptimal then
		local pen = math.max(1, cost)
		data.penaltyTotal = data.penaltyTotal + pen
		PenaltyFlash:FireClient(player, pen)
		PlaySound:FireClient(player, "Oof")
	else
		if destId ~= data.dst then
			PlaySound:FireClient(player, "RightNode")
		end
	end
	
	table.insert(data.visited, destId)
	data.playerPos = destId
	data.playerCost = data.playerCost + cost
	
	-- Update client
	UpdateUI:FireClient(player, {
		mode = "Dijkstra",
		nodes = NodesList,
		adj = data.adj,
		edgeMap = data.edgeMap,
		src = data.src,
		dst = data.dst,
		mission = data.mission,
		playerPos = data.playerPos,
		visited = data.visited,
		playerCost = data.playerCost,
		penaltyTotal = data.penaltyTotal,
		optimalCost = data.optimalCost,
		optimalPath = data.optimalPath,
		roundNum = data.roundNum,
		totalScore = data.totalScore
	})
	
	-- Teleport player to new node
	local char = player.Character
	if char and char:FindFirstChild("HumanoidRootPart") and NodeParts[destId] then
		char.HumanoidRootPart.CFrame = NodeParts[destId].CFrame + Vector3.new(0, 5, 0)
	end
	
	if destId == data.dst then
		data.done = true
		local diff = data.playerCost - data.optimalCost
		local perfect = (diff == 0 and data.penaltyTotal == 0)
		local roundScore = math.max(0, data.optimalCost * 2 - data.playerCost - data.penaltyTotal)
		data.totalScore = data.totalScore + roundScore
		RoundEnd:FireClient(player, {
			diff = diff,
			perfect = perfect,
			roundScore = roundScore,
			playerCost = data.playerCost,
			optimalCost = data.optimalCost,
			penaltyTotal = data.penaltyTotal,
			totalScore = data.totalScore
		})
		
		if perfect or diff <= 20 then
			PlaySound:FireClient(player, "Success")
		else
			PlaySound:FireClient(player, "Fail")
		end
	end
end)


Players.PlayerAdded:Connect(function(player)
	-- Show start menu on client side initially, so don't start round immediately
	UpdateUI:FireClient(player, { mode = "Menu", nodes = NodesList })
end)

for _, player in ipairs(Players:GetPlayers()) do
	UpdateUI:FireClient(player, { mode = "Menu", nodes = NodesList })
end
