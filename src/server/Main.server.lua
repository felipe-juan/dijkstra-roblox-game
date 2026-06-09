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

local MoveRequest  = createEvent("MoveRequest")
local RestartRound = createEvent("RestartRound")
local NextRound    = createEvent("NextRound")
local UpdateUI     = createEvent("UpdateUI")
local PenaltyFlash = createEvent("PenaltyFlash")
local RoundEnd     = createEvent("RoundEnd")
local SetMode      = createEvent("SetMode")
local PlaySound    = createEvent("PlaySound")

-- Missions – you can translate the types here
local MISSIONS = {
	{emoji="📝", verb="Entregar prova para a", types={"sala"}},
	{emoji="🧻", verb="Repor papel higiênico no", types={"banheiro"}},
	{emoji="💐", verb="Regar as flores no", types={"patio"}},
	{emoji="👋", verb="Receber visitante na", types={"entrada"}},
	{emoji="📦", verb="Deixar suprimentos na", types={"sala"}},
}

local PlayerData = {}
local NodesList = {}
local NodeParts = {}

-- ============================================================
--  DYNAMIC NODE BUILDER
-- ============================================================
local function buildDynamicNodesList()
	NodesList = {}
	NodeParts = {}

	local nodesFolder = Workspace:FindFirstChild("Nodes")
	if not nodesFolder then
		warn("No 'Nodes' folder found in Workspace")
		return false
	end

	-- Gather all BaseParts (including those inside sub‑folders) that aren't the template
	local parts = {}
	local function collectParts(parent)
		for _, child in ipairs(parent:GetChildren()) do
			if child:IsA("BasePart") and child.Name ~= "NodeTemplate" then
				table.insert(parts, child)
			elseif child:IsA("Folder") or child:IsA("Model") then
				collectParts(child)
			end
		end
	end
	collectParts(nodesFolder)

	if #parts == 0 then
		warn("No node parts found in Workspace.Nodes (excluding 'NodeTemplate')")
		return false
	end

	-- Sort by X position so IDs are stable
	table.sort(parts, function(a, b) return a.Position.X < b.Position.X end)

	for i, part in ipairs(parts) do
		local id = i - 1

		local displayName = part:GetAttribute("DisplayName") or part.Name
		local nodeType    = part:GetAttribute("NodeType") or "sala"
		local emoji       = part:GetAttribute("Emoji") or "📍"

		local node = {
			id = id,
			name = displayName,
			partName = part.Name,   -- kept for legacy, not used for lookup
			type = nodeType,
			emoji = emoji,
			x = part.Position.X,
			y = part.Position.Y,
			z = part.Position.Z,
		}

		NodeParts[id] = part
		table.insert(NodesList, node)

		-- BillboardGui (unchanged)
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
		tl.Text = emoji .. " " .. displayName
		tl.TextColor3 = Color3.new(1,1,1)
		tl.TextStrokeTransparency = 0
		tl.TextScaled = true
		tl.Font = Enum.Font.GothamBold
		tl.Parent = bg
		bg.Parent = part
	end
	return true
end

-- ============================================================
--  ROUND LOGIC
-- ============================================================
local function initRound(player)
	local ok = buildDynamicNodesList()
	if not ok then
		UpdateUI:FireClient(player, { mode = "Menu", nodes = {}, errorMsg = "Nenhum nó encontrado no mapa!" })
		return
	end

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
			nodes = NodesList,
		})
		return
	end

	local adj, edgeMap = GraphGenerator.BuildGraph(NodesList)
	data.adj = adj
	data.edgeMap = edgeMap

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
	if #candidates == 0 then
		for _, n in ipairs(NodesList) do
			table.insert(candidates, n)
		end
	end
	if #candidates == 0 then
		UpdateUI:FireClient(player, { mode = "Menu", nodes = NodesList, errorMsg = "Nenhum nó disponível para missão!" })
		return
	end

	local dst = candidates[math.random(#candidates)]
	local dist, prev = GraphGenerator.Dijkstra(NodesList, adj, dst.id)

	local validSrc = {}
	local maxEdges = 0
	local furthestSrcs = {}
	for _, n in ipairs(NodesList) do
		local isMissionType = false
		for _, t in ipairs(missionTpl.types) do
			if n.type == t then isMissionType = true; break end
		end
		if not isMissionType or n.type == "courtyard" then
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
	elseif #furthestSrcs > 0 then
		src = furthestSrcs[math.random(#furthestSrcs)]
	else
		for _, n in ipairs(NodesList) do
			if n.id ~= dst.id then
				src = n
				break
			end
		end
	end
	if not src then
		UpdateUI:FireClient(player, { mode = "Menu", nodes = NodesList, errorMsg = "Não foi possível escolher uma origem!" })
		return
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

	for id, part in pairs(NodeParts) do
		if id == src.id then
			part.Color = Color3.fromRGB(245, 205, 47)
		elseif id == dst.id then
			part.Color = Color3.fromRGB(80, 255, 120)
		else
			part.Color = Color3.fromRGB(55, 138, 221)
		end
	end

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
		totalScore = data.totalScore,
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

	local neighbours = data.adj[data.playerPos]
	local isValid = false
	local cost = 0
	for _, edge in ipairs(neighbours) do
		if edge.v == destId then
			isValid = true
			cost = edge.w
			break
		end
	end

	local isVisited = table.find(data.visited, destId)
	if not isValid or isVisited then return end

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
		totalScore = data.totalScore,
	})

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
			totalScore = data.totalScore,
		})

		if perfect or diff <= 20 then
			PlaySound:FireClient(player, "Success")
		else
			PlaySound:FireClient(player, "Fail")
		end
	end
end)

Players.PlayerAdded:Connect(function(player)
	buildDynamicNodesList()
	UpdateUI:FireClient(player, { mode = "Menu", nodes = NodesList })
end)

for _, player in ipairs(Players:GetPlayers()) do
	buildDynamicNodesList()
	UpdateUI:FireClient(player, { mode = "Menu", nodes = NodesList })
end