-- DijkstraServer.lua
-- Place inside: ServerScriptService
--
-- v15 – Bug fixes:
--   • FIX: Player was stuck in sit pose after teleporting (reset or respawn).
--     Added unseatCharacter() which clears Humanoid.Sit and ejects the
--     character from any Seat/VehicleSeat before the CFrame teleport.
--     A task.wait() gives the physics engine one tick to process the eject.
--     Applied to both ResetGameRemote and CharacterAdded handlers.
--   • All v14 fixes retained.
--
-- v14 – Bug fixes:
--   • FIX (PERF): getBestNeighbor previously re-ran a full O(n²) Dijkstra
--     from endId on every single call, and was called TWICE per player move
--     (once in SelectNodeRemote, once inside buildPayload). distFromEnd is now
--     computed once per round in initPlayerState, cached on the state object,
--     and passed into getBestNeighbor — eliminating 2 redundant Dijkstras/move.
--   • FIX: tracePath now has a step-count guard (maxSteps = #prev + 2) to
--     prevent a theoretical infinite loop if the prev[] array were ever
--     corrupted. The old unbounded while-loop was unsafe.
--   • FIX: loadGraph now warns when multiple nodes have IsStart=true or
--     IsEnd=true (previously the last one silently won, hiding map authoring
--     mistakes).
--   • FIX: state.visited (raw ID array) was appended to on every move but
--     never read — buildPayload derives visited names from visitedSet.
--     Removed the redundant table.insert to stop unbounded memory growth.
--   • All v13 fixes retained.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")

-- ─────────────────────────────────────────────
-- CONFIG
-- ─────────────────────────────────────────────
local CONFIG = {
	NODES_FOLDER    = "Nodes",
	START_TAG       = "IsStart",
	END_TAG         = "IsEnd",
	CONN_TAG        = "Connections",
	EXTRA_EDGE_MIN  = 3,    -- extra edges added on top of spanning tree (random mode)
	EXTRA_EDGE_MAX  = 7,
	MIN_PATH_HOPS   = 2,    -- random mode: minimum hops from start→end
}

-- ─────────────────────────────────────────────
-- REMOTES
-- ─────────────────────────────────────────────
local remotesFolder = Instance.new("Folder")
remotesFolder.Name   = "DijkstraRemotes"
remotesFolder.Parent = ReplicatedStorage

local function makeRemote(name)
	local r = Instance.new("RemoteEvent")
	r.Name = name; r.Parent = remotesFolder
	return r
end

local SelectNodeRemote    = makeRemote("SelectNode")
local GameStateRemote     = makeRemote("GameState")
local ResetGameRemote     = makeRemote("ResetGame")
local SetModeRemote       = makeRemote("SetMode")
local SetDestructibleRemote = makeRemote("SetDestructible")

-- ─────────────────────────────────────────────
-- UTILITIES
-- ─────────────────────────────────────────────
local function randWeight()
	-- Always returns a positive integer in [10, 150]; never 0 or nil
	return math.max(10, math.random(1, 15) * 10)
end

local function shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
end

-- BFS hop distances from srcId. Returns dist[id] = hops (unreachable = nil).
local function bfsHops(adj, srcId)
	local dist  = { [srcId] = 0 }
	local queue = { srcId }
	local head  = 1
	while head <= #queue do
		local u = queue[head]; head = head + 1
		for _, edge in ipairs(adj[u]) do
			local v = edge[1]
			if dist[v] == nil then
				dist[v] = dist[u] + 1
				table.insert(queue, v)
			end
		end
	end
	return dist
end

-- Returns the node index with the highest degree (used as connectivity hub).
local function findHub(adj, n)
	local best, bestDeg = 1, 0
	for i = 1, n do
		local deg = #adj[i]
		if deg > bestDeg then bestDeg = deg; best = i end
	end
	return best
end

-- ─────────────────────────────────────────────
-- GRAPH LOADING
-- ─────────────────────────────────────────────
local INF = math.huge

local function loadGraph(mode)
	mode = mode or "normal"

	local nodesFolder = Workspace:FindFirstChild(CONFIG.NODES_FOLDER)
	assert(nodesFolder, "No folder '" .. CONFIG.NODES_FOLDER .. "' found in Workspace!")

	-- ── Collect nodes ────────────────────────────────────────
	local nodes    = {}
	local nameToId = {}
	local startId  = nil
	local endId    = nil
	local rawConns = {}

	for _, part in ipairs(nodesFolder:GetChildren()) do
		if part:IsA("BasePart") or part:IsA("Model") then
			local name = part.Name
			table.insert(nodes, name)
			local id = #nodes
			nameToId[name] = id

			local sv = part:FindFirstChild(CONFIG.START_TAG)
			if sv and sv:IsA("BoolValue") and sv.Value then
				if startId then
					warn("[Server] Multiple nodes have IsStart=true; '"
						.. name .. "' overrides previous. Check your map!")
				end
				startId = id
			end

			local ev = part:FindFirstChild(CONFIG.END_TAG)
			if ev and ev:IsA("BoolValue") and ev.Value then
				if endId then
					warn("[Server] Multiple nodes have IsEnd=true; '"
						.. name .. "' overrides previous. Check your map!")
				end
				endId = id
			end

			local cv = part:FindFirstChild(CONFIG.CONN_TAG)
			rawConns[name] = (cv and cv:IsA("StringValue")) and cv.Value or ""
		end
	end

	local n = #nodes
	assert(n >= 2, "Need at least 2 nodes in the Nodes folder!")

	-- ── Adjacency helpers ────────────────────────────────────
	local adj        = {}
	local addedPairs = {}
	for i = 1, n do adj[i] = {} end

	local function edgeKey(u, v)
		return u < v and (u .. "_" .. v) or (v .. "_" .. u)
	end

	local function addEdge(u, v, w)
		if u == v then return end
		-- Guard: weight must be a valid positive integer
		if type(w) ~= "number" or w <= 0 or w ~= math.floor(w) then
			w = randWeight()
		end
		local key = edgeKey(u, v)
		if addedPairs[key] then return end
		addedPairs[key] = true
		table.insert(adj[u], {v, w})
		table.insert(adj[v], {u, w})
	end

	-- Parse Connections tags → set of candidate pairs (used by both modes)
	local tagPairs    = {}
	local tagPairSet  = {}
	for name, connStr in pairs(rawConns) do
		if connStr ~= "" then
			local uId = nameToId[name]
			for entry in connStr:gmatch("[^,]+") do
				local nbName = entry:match("^%s*(.-)%s*:%s*%d+%s*$")
					or entry:match("^%s*(.-)%s*$")
				if nbName and nbName ~= "" then
					local vId = nameToId[nbName]
					if vId and uId ~= vId then
						local key = edgeKey(uId, vId)
						if not tagPairSet[key] then
							tagPairSet[key] = true
							table.insert(tagPairs, {uId, vId})
						end
					elseif not nameToId[nbName] then
						warn("[Server] Unknown neighbour '" .. nbName .. "' on node '" .. name .. "'")
					end
				end
			end
		end
	end

	-- ── Build graph ──────────────────────────────────────────
	if mode == "random" then

		-- Step 1: random spanning tree — guarantees full connectivity.
		local order = {}
		for i = 1, n do order[i] = i end
		shuffle(order)
		for i = 2, n do
			local j = math.random(1, i - 1)
			addEdge(order[i], order[j], randWeight())
		end

		-- Step 2: extra edges.
		-- First try the designer-curated tagPairs pool; if that runs dry,
		-- fall back to random pairs to always meet the extraTarget count.
		local extraPool = {}
		for _, p in ipairs(tagPairs) do
			if not addedPairs[edgeKey(p[1], p[2])] then
				table.insert(extraPool, p)
			end
		end
		shuffle(extraPool)

		local extraTarget = math.random(CONFIG.EXTRA_EDGE_MIN, CONFIG.EXTRA_EDGE_MAX)
		local added = 0

		-- Curated pairs first
		for _, p in ipairs(extraPool) do
			if added >= extraTarget then break end
			if not addedPairs[edgeKey(p[1], p[2])] then
				addEdge(p[1], p[2], randWeight())
				added = added + 1
			end
		end

		-- Random-pair fallback when curated pool is exhausted
		if added < extraTarget then
			local attempts = 0
			while added < extraTarget and attempts < n * n do
				attempts = attempts + 1
				local u = math.random(1, n)
				local v = math.random(1, n)
				if u ~= v and not addedPairs[edgeKey(u, v)] then
					addEdge(u, v, randWeight())
					added = added + 1
				end
			end
		end

		-- Step 3: guarantee every node has degree >= 2.
		-- Run in a loop until stable so that emergency-promoted nodes are
		-- also checked (a newly added edge might itself have a low-degree peer).
		-- CRITICAL FIX: the original version of this loop could spin forever.
		-- For very small graphs (e.g. n == 2) it is mathematically impossible
		-- for every node to reach degree >= 2 (max possible degree is n-1),
		-- so "stabilised" could never become true AND no new edge could ever
		-- be added either — an infinite loop that hangs the server thread.
		-- We now (a) track whether any edge was actually added during a pass
		-- and bail out if a pass makes no progress, and (b) cap the number
		-- of passes as a hard safety net.
		local stabilised = false
		local maxPasses  = n + 5
		local pass       = 0
		while not stabilised do
			pass = pass + 1
			stabilised = true
			local progressMade = false
			for i = 1, n do
				if #adj[i] < 2 then
					stabilised = false
					local degBefore = #adj[i]
					-- Try curated pairs for node i first
					for _, p in ipairs(tagPairs) do
						if #adj[i] >= 2 then break end
						local u, v = p[1], p[2]
						if (u == i or v == i) and not addedPairs[edgeKey(u, v)] then
							addEdge(u, v, randWeight())
						end
					end
					-- Hard fallback: connect to highest-degree hub (not self)
					if #adj[i] < 2 then
						local hub = findHub(adj, n)
						if hub ~= i and not addedPairs[edgeKey(i, hub)] then
							addEdge(i, hub, randWeight())
						else
							-- Last resort: sequential scan
							for j = 1, n do
								if #adj[i] >= 2 then break end
								if j ~= i and not addedPairs[edgeKey(i, j)] then
									addEdge(i, j, randWeight())
								end
							end
						end
					end
					if #adj[i] > degBefore then progressMade = true end
				end
			end
			if not stabilised and not progressMade then
				warn("[Server] Cannot bring all nodes to degree >= 2 (graph has only "
					.. n .. " node(s); max possible degree is " .. (n - 1)
					.. "). Continuing with current connectivity.")
				break
			end
			if pass > maxPasses then
				warn("[Server] Degree >= 2 stabilisation exceeded " .. maxPasses .. " passes; continuing.")
				break
			end
		end

		-- Step 4: final BFS connectivity check — after all edge-building steps,
		-- any node still unreachable from node 1 gets a direct edge to the hub.
		local reachable = bfsHops(adj, 1)
		for i = 1, n do
			if reachable[i] == nil then
				warn("[Server] Node " .. nodes[i] .. " still unreachable after build; connecting to hub.")
				local hub = findHub(adj, n)
				addEdge(i, hub ~= i and hub or 1, randWeight())
			end
		end

		-- Step 5: repair any bad weights in the adjacency lists.
		-- Iterate every entry in every list and fix in-place; since both
		-- directions share the same numeric values (not the same table),
		-- we must repair each direction independently.
		for i = 1, n do
			for _, edge in ipairs(adj[i]) do
				if type(edge[2]) ~= "number" or edge[2] <= 0 then
					edge[2] = randWeight()
				else
					edge[2] = math.floor(edge[2])
				end
			end
		end

		-- Step 6: pick start and end nodes with a meaningful path between them.
		-- Retry up to 100 times to find a pair with at least MIN_PATH_HOPS between them.
		local hopDist
		local attempts = 0
		local maxAttempts = math.max(100, n * n)
		repeat
			attempts = attempts + 1
			startId = math.random(1, n)
			repeat endId = math.random(1, n) until endId ~= startId
			hopDist = bfsHops(adj, startId)
		until (hopDist[endId] or 0) >= CONFIG.MIN_PATH_HOPS or attempts >= maxAttempts

		if (hopDist[endId] or 0) < CONFIG.MIN_PATH_HOPS then
			warn("[Server] Could not find start/end pair with >= " .. CONFIG.MIN_PATH_HOPS
				.. " hops after " .. maxAttempts .. " attempts; using last picked pair.")
		end
		-- Safety: ensure startId/endId are always valid integers
		startId = startId or 1
		endId   = endId   or (startId == 1 and 2 or 1)

	else
		-- ── NORMAL MODE ──────────────────────────────────────
		assert(startId,         "No node has IsStart = true!")
		assert(endId,           "No node has IsEnd = true!")
		assert(startId ~= endId,"Start and End nodes must be different!")

		for _, p in ipairs(tagPairs) do
			addEdge(p[1], p[2], randWeight())
		end

		-- Connect any isolated nodes
		for i = 1, n do
			if #adj[i] == 0 then
				-- Find any non-isolated node to connect to; fall back to node index 2 (or 1 if n==1)
				local target = nil
				for j = 1, n do
					if j ~= i and #adj[j] > 0 then target = j; break end
				end
				if not target then
					target = (i == 1) and 2 or 1
				end
				if target and target ~= i then
					addEdge(i, target, randWeight())
					warn("[Server] Node '" .. nodes[i] .. "' was isolated; emergency edge added.")
				end
			end
		end
	end

	return {
		nodes    = nodes,
		nameToId = nameToId,
		adj      = adj,
		n        = n,
		startId  = startId,
		endId    = endId,
		mode     = mode,
	}
end

-- ─────────────────────────────────────────────
-- DIJKSTRA
-- ─────────────────────────────────────────────
local function dijkstra(adj, srcId, n)
	local dist    = {}
	local prev    = {}
	local visited = {}
	for i = 1, n do
		dist[i] = INF; prev[i] = -1; visited[i] = false
	end
	dist[srcId] = 0

	for _ = 1, n do
		local u
		for v = 1, n do
			if not visited[v] and (u == nil or dist[v] < dist[u]) then u = v end
		end
		if u == nil or dist[u] == INF then break end
		visited[u] = true
		for _, edge in ipairs(adj[u]) do
			local v, w = edge[1], edge[2]
			if dist[u] + w < dist[v] then
				dist[v] = dist[u] + w; prev[v] = u
			end
		end
	end

	return dist, prev
end

local function tracePath(prev, endId)
	local path  = {}
	local cur   = endId
	local steps = 0
	local maxSteps = #prev + 2  -- can never need more steps than there are nodes
	while cur ~= -1 and steps <= maxSteps do
		table.insert(path, 1, cur)
		cur   = prev[cur]
		steps = steps + 1
	end
	return path
end

-- Best unvisited neighbour from curPos toward endId.
-- distFromEnd must be pre-computed via dijkstra(adj, endId, n) and cached on the
-- state; passing it in avoids re-running O(n²) Dijkstra on every move.
local function getBestNeighbor(adj, curPos, endId, visitedSet, distFromEnd)
	local bestId    = nil
	local bestTotal = INF

	for _, edge in ipairs(adj[curPos]) do
		local vId, w = edge[1], edge[2]
		if not visitedSet[vId] then
			local rem   = distFromEnd[vId] or INF
			local total = w + (rem == INF and 999999 or rem)
			if total < bestTotal then
				bestTotal = total
				bestId    = vId
			end
		end
	end

	return bestId
end

-- ─────────────────────────────────────────────
-- PLAYER STATE
-- ─────────────────────────────────────────────
local playerStates = {}
local playerModes  = {}

local function getNodePart(nodeName)
	local folder = Workspace:FindFirstChild(CONFIG.NODES_FOLDER)
	return folder and folder:FindFirstChild(nodeName)
end

-- CRITICAL FIX: Model:GetPrimaryPartCFrame() throws an error if the Model's
-- PrimaryPart is unset. In random mode ANY node can become the start node
-- (not just a curated/tested IsStart node), so a Model without a PrimaryPart
-- would throw here, aborting ResetGameRemote / CharacterAdded BEFORE
-- GameStateRemote:FireClient ever runs — leaving the client stuck with no
-- game state. GetPivot() works for Models regardless of PrimaryPart.
-- Ejects the character from any Seat/VehicleSeat it may be occupying,
-- then waits one physics tick so the engine actually unseats before we
-- move the HumanoidRootPart.  Without this the character stays frozen in
-- the sit pose and the teleport has no effect on the occupying seat.
local function unseatCharacter(character)
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Sit = false
	end
	-- Also kick any Seat/VehicleSeat that still holds this character
	for _, obj in ipairs(Workspace:GetDescendants()) do
		if (obj:IsA("Seat") or obj:IsA("VehicleSeat")) and obj.Occupant then
			local occChar = obj.Occupant.Parent
			if occChar == character then
				obj:Sit(nil)   -- eject occupant
			end
		end
	end
end

local function getPartPosition(part)
	if not part then return nil end
	if part:IsA("BasePart") then return part.Position end
	if part:IsA("Model") then
		if part.PrimaryPart then
			return part:GetPrimaryPartCFrame().Position
		end
		return part:GetPivot().Position
	end
	return nil
end

local function initPlayerState(player)
	local prev       = playerStates[player]
	local totalScore = prev and prev.totalScore or 0
	local mode       = playerModes[player] or "normal"

	-- Increment round number: always increment from the previous round,
	-- except on the very first round (no previous state).
	local roundNum = prev and (prev.roundNum + 1) or 1

	local graph = loadGraph(mode)

	-- Verify start→end reachability; retry once if not reachable.
	local dist, prevMap = dijkstra(graph.adj, graph.startId, graph.n)
	if dist[graph.endId] == INF then
		warn("[Server] Start→End unreachable after graph build; regenerating...")
		graph = loadGraph(mode)
		dist, prevMap = dijkstra(graph.adj, graph.startId, graph.n)
	end

	local optimalCost = dist[graph.endId]
	local optimalPath = tracePath(prevMap, graph.endId)

	-- Cache the reverse-Dijkstra from endId once per round.
	-- getBestNeighbor needs this on every move; recomputing it every call
	-- was O(n²) per move — wasteful for large graphs.
	local distFromEnd = dijkstra(graph.adj, graph.endId, graph.n)

	if optimalCost == INF then
		warn("[Server] Still unreachable after retry. Game may not complete correctly.")
	end

	local state = {
		graph        = graph,
		playerPos    = graph.startId,
		visited      = { graph.startId },
		visitedSet   = { [graph.startId] = true },
		visitedOrder = { graph.startId },
		moveLog      = {},
		playerCost   = 0,
		optimalCost  = optimalCost,
		optimalPath  = optimalPath,
		distFromEnd  = distFromEnd,   -- cached for getBestNeighbor
		penaltyTotal = 0,
		roundScore   = 0,
		done         = false,
		mode         = mode,
		totalScore   = totalScore,
		roundNum     = roundNum,
	}

	playerStates[player] = state
	return state
end

-- ─────────────────────────────────────────────
-- PAYLOAD BUILDER
-- ─────────────────────────────────────────────
local function buildPayload(state)
	local g = state.graph

	-- Edge list (unique undirected edges)
	local edgeList = {}
	local seenEdge = {}
	for uId = 1, g.n do
		for _, edge in ipairs(g.adj[uId]) do
			local vId, w = edge[1], edge[2]
			local key = uId < vId and (uId .. "-" .. vId) or (vId .. "-" .. uId)
			if not seenEdge[key] then
				seenEdge[key] = true
				table.insert(edgeList, { g.nodes[uId], g.nodes[vId], w })
			end
		end
	end

	-- Visited set (names)
	local visitedNames = {}
	for id in pairs(state.visitedSet) do
		table.insert(visitedNames, g.nodes[id])
	end

	-- Optimal path (names)
	local optPathNames = {}
	for _, id in ipairs(state.optimalPath) do
		table.insert(optPathNames, g.nodes[id])
	end

	-- Current neighbours: prefer unvisited nodes, but if all are visited
	-- fall back to ALL adjacent nodes so the player is never fully stuck.
	local neighbors     = {}
	local hasUnvisited  = false
	for _, edge in ipairs(g.adj[state.playerPos]) do
		if not state.visitedSet[edge[1]] then hasUnvisited = true; break end
	end
	for _, edge in ipairs(g.adj[state.playerPos]) do
		local vId, w = edge[1], edge[2]
		if hasUnvisited then
			-- Normal case: only offer unvisited neighbours
			if not state.visitedSet[vId] then
				table.insert(neighbors, { g.nodes[vId], w })
			end
		else
			-- Fallback: offer all neighbours (player is in a visited pocket)
			-- Exclude the end node if it was already reached to avoid re-triggering done
			if not state.done then
				table.insert(neighbors, { g.nodes[vId], w })
			end
		end
	end

	-- Visited order (names)
	local visitedOrderNames = {}
	for _, id in ipairs(state.visitedOrder) do
		table.insert(visitedOrderNames, g.nodes[id])
	end

	-- Best next node from current position
	local bestId   = getBestNeighbor(g.adj, state.playerPos, g.endId, state.visitedSet, state.distFromEnd)
	local bestName = bestId and g.nodes[bestId] or nil

	return {
		nodes        = g.nodes,
		edges        = edgeList,
		startName    = g.nodes[g.startId],
		endName      = g.nodes[g.endId],
		playerPos    = g.nodes[state.playerPos],
		visited      = visitedNames,
		visitedOrder = visitedOrderNames,
		moveLog      = state.moveLog,
		playerCost   = state.playerCost,
		optimalCost  = state.optimalCost,
		optimalPath  = optPathNames,
		neighbors    = neighbors,
		done         = state.done,
		steps        = #state.visitedOrder - 1,
		penaltyTotal = state.penaltyTotal,
		roundScore   = state.roundScore,
		totalScore   = state.totalScore,
		roundNum     = state.roundNum,
		bestNext     = bestName,
		mode         = state.mode,
	}
end

-- ─────────────────────────────────────────────
-- DESTRUCTIBLE MODE
-- ─────────────────────────────────────────────
-- When enabled, every anchored BasePart in the Workspace (outside of
-- characters, the Nodes folder, and parts tagged DontDestroy) becomes
-- physics-enabled so explosions can knock them around.
-- Original properties are saved so we can fully restore on toggle-off.

-- Tags that protect a part from being made destructible
local PROTECTED_TAGS = { DontDestroy = true }

-- Parts that were made destructible this session: { part, origProps }
local destructibleParts = {}
local destructibleActive = false

local function isProtectedPart(part)
	-- Skip character parts
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		if char and part:IsDescendantOf(char) then return true end
	end
	-- Skip the Nodes folder
	local nodesFolder = Workspace:FindFirstChild(CONFIG.NODES_FOLDER)
	if nodesFolder and part:IsDescendantOf(nodesFolder) then return true end
	-- Skip Terrain and Camera
	if part:IsA("Terrain") then return true end
	-- Skip parts with DontDestroy attribute or tag
	if part:GetAttribute("DontDestroy") then return true end
	-- Skip parts that are already unanchored & non-collide (likely already dynamic or decorative)
	-- We still include them if they are anchored, because that's what we want to unanchor.
	return false
end

local function enableDestructible()
	destructibleParts = {}
	for _, obj in ipairs(Workspace:GetDescendants()) do
		if obj:IsA("BasePart") and obj.Anchored and not isProtectedPart(obj) then
			-- Save original state
			local saved = {
				part         = obj,
				Anchored     = obj.Anchored,
				CanCollide   = obj.CanCollide,
				Massless     = obj.Massless,
				CustomPhysicalProperties = obj.CustomPhysicalProperties,
			}
			table.insert(destructibleParts, saved)
			-- Make physics-active
			obj.Anchored   = false
			obj.CanCollide = true
			obj.Massless   = false
		end
	end
	destructibleActive = true
end

local function disableDestructible()
	for _, saved in ipairs(destructibleParts) do
		local part = saved.part
		-- Part may have been destroyed by an explosion — guard with pcall
		local ok, err = pcall(function()
			if part and part.Parent then
				part.Anchored   = saved.Anchored
				part.CanCollide = saved.CanCollide
				part.Massless   = saved.Massless
				-- Snap back to saved CFrame if the part drifted far
				-- We don't save CFrame because for most parts we want
				-- them to stay where they fell (the user wanted chaos).
				-- If you want hard-reset, uncomment the next line:
				-- part.CFrame = saved.CFrame
			end
		end)
		if not ok then
			warn("[Destructible] Could not restore part: " .. tostring(err))
		end
	end
	destructibleParts  = {}
	destructibleActive = false
end

SetDestructibleRemote.OnServerEvent:Connect(function(player, enable)
	-- Only allow in free roam (no active game state) or always allow — your call.
	-- Current policy: any player can toggle it (it's a sandbox feature).
	if enable then
		enableDestructible()
	else
		disableDestructible()
	end
	-- Broadcast the new state to ALL clients so their button stays in sync
	SetDestructibleRemote:FireAllClients(destructibleActive)
end)

-- ─────────────────────────────────────────────
-- REMOTE HANDLERS
-- ─────────────────────────────────────────────

SelectNodeRemote.OnServerEvent:Connect(function(player, nodeName)
	local state = playerStates[player]
	if not state or state.done then return end

	local g   = state.graph
	local vId = g.nameToId[nodeName]
	if not vId then return end

	-- Validate: must be an adjacent node.
	-- Normally the destination must also be unvisited; however if ALL
	-- neighbours are already visited the player would be permanently stuck,
	-- so we allow moving to visited neighbours as a fallback in that case.
	local hasUnvisitedNeighbor = false
	for _, edge in ipairs(g.adj[state.playerPos]) do
		if not state.visitedSet[edge[1]] then hasUnvisitedNeighbor = true; break end
	end

	local valid      = false
	local edgeWeight = 0
	for _, edge in ipairs(g.adj[state.playerPos]) do
		if edge[1] == vId then
			-- Accept if: unvisited OR all neighbours are visited (fallback)
			if not state.visitedSet[vId] or not hasUnvisitedNeighbor then
				valid = true; edgeWeight = edge[2]; break
			end
		end
	end
	if not valid then return end

	-- Determine optimality BEFORE moving
	local bestId     = getBestNeighbor(g.adj, state.playerPos, g.endId, state.visitedSet, state.distFromEnd)
	local wasOptimal = (bestId == nil or vId == bestId)

	if not wasOptimal then
		state.penaltyTotal = state.penaltyTotal + math.max(1, edgeWeight)
	end

	-- Record move in log
	table.insert(state.moveLog, {
		from       = g.nodes[state.playerPos],
		to         = g.nodes[vId],
		cost       = edgeWeight,
		wasOptimal = wasOptimal,
	})

	-- Apply movement
	state.visitedSet[vId] = true
	-- NOTE: state.visited (the array) is intentionally not updated here;
	-- buildPayload derives visitedNames from visitedSet which is authoritative.
	table.insert(state.visitedOrder, vId)
	state.playerPos  = vId
	state.playerCost = state.playerCost + edgeWeight

	if vId == g.endId then
		state.done = true
		local roundScore   = math.max(0, state.optimalCost * 2 - state.playerCost - state.penaltyTotal)
		state.roundScore   = roundScore
		state.totalScore   = state.totalScore + roundScore
	end

	GameStateRemote:FireClient(player, buildPayload(state))
end)

SetModeRemote.OnServerEvent:Connect(function(player, mode)
	if mode ~= "random" and mode ~= "normal" then mode = "normal" end
	playerModes[player] = mode
end)

ResetGameRemote.OnServerEvent:Connect(function(player)
	-- Fix: initPlayerState is also responsible for teleporting the character
	-- to the start node. Mode has already been set by SetModeRemote before
	-- this fires (client sends SetMode first, then ResetGame).
	local state     = initPlayerState(player)
	local character = player.Character
	local startPart = getNodePart(state.graph.nodes[state.graph.startId])
	if startPart and character and character:FindFirstChild("HumanoidRootPart") then
		local pos = getPartPosition(startPart)
		if pos then
			-- FIX: unseat the character first so it leaves any chair/vehicle
			-- before being teleported. Without this the player stays frozen
			-- in the sit pose even after the CFrame is moved.
			unseatCharacter(character)
			task.wait()  -- one physics tick for the engine to process the eject
			character.HumanoidRootPart.CFrame = CFrame.new(pos + Vector3.new(0, 5, 0))
		end
	end
	GameStateRemote:FireClient(player, buildPayload(state))
end)

-- ─────────────────────────────────────────────
-- PLAYER LIFECYCLE
-- ─────────────────────────────────────────────
-- FIX: We no longer auto-start the game on CharacterAdded. The client's
-- "Start" button sends SetMode then ResetGame, which triggers initPlayerState
-- and fires GameStateRemote. This prevents the StartMenu from being skipped.
--
-- We still need to teleport the character to the start node when they
-- respawn mid-game (e.g., fell off the map), but only if a game is in
-- progress (playerStates[player] exists and is not nil).
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		task.wait(1)
		local state = playerStates[player]
		-- Only teleport if the player already has an active game state.
		-- Do NOT fire GameStateRemote here — the client manages visibility.
		if state then
			local startPart = getNodePart(state.graph.nodes[state.graph.startId])
			if startPart and character:FindFirstChild("HumanoidRootPart") then
				local pos = getPartPosition(startPart)
				if pos then
					-- FIX: unseat before teleporting so the character fully
					-- exits any chair/vehicle before the CFrame is applied.
					-- This also covers the "still sitting after dying" bug,
					-- since Roblox respawns the character while the old one
					-- may still be listed as a seat occupant.
					unseatCharacter(character)
					task.wait()
					character.HumanoidRootPart.CFrame = CFrame.new(pos + Vector3.new(0, 5, 0))
				end
			end
			-- Re-send current game state so UI re-syncs after respawn
			GameStateRemote:FireClient(player, buildPayload(state))
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	playerStates[player] = nil
	playerModes[player]  = nil
end)

print("[DijkstraServer] v16 Loaded. Waiting for players...")
