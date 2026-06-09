local GraphGenerator = {}

-- Euclidean distance (XZ plane)
local function dist2D(a, b)
	local dx = a.x - b.x
	local dz = a.z - b.z
	return math.sqrt(dx * dx + dz * dz)
end

-- Safely add an undirected edge (weight must be a positive number)
local function addEdge(adj, edgeMap, u, v, w)
	local key = string.format("%d_%d", math.min(u, v), math.max(u, v))
	if edgeMap[key] then return end

	if type(w) ~= "number" or w <= 0 then
		w = math.random(1, 12) * 10
	end

	table.insert(adj[u], { v = v, w = w })
	table.insert(adj[v], { v = u, w = w })
	edgeMap[key] = w
end

local function degree(adj, id)
	return adj[id] and #adj[id] or 0
end

-- Maximum distance for extra random edges (studs)
local MAX_EXTRA_DIST = 250

function GraphGenerator.BuildGraph(nodesList)
	local adj = {}
	local edgeMap = {}

	-- Work with a copy
	local nodes = {}
	for _, n in ipairs(nodesList) do
		table.insert(nodes, { id = n.id, x = n.x, z = n.z })
	end
	if #nodes < 2 then
		return adj, edgeMap
	end

	for _, n in ipairs(nodes) do
		adj[n.id] = {}
	end

	-- =======================================================
	--  1. RANDOM SPANNING TREE  (guarantees connectivity)
	-- =======================================================
	local order = {}
	for i = 1, #nodes do order[i] = i end
	for i = #order, 2, -1 do
		local j = math.random(i)
		order[i], order[j] = order[j], order[i]
	end

	for i = 2, #order do
		local v = order[i]
		local u = order[math.random(1, i - 1)]
		local w = math.random(1, 12) * 10
		addEdge(adj, edgeMap, nodes[u].id, nodes[v].id, w)
	end

	-- =======================================================
	--  2. ENFORCE MINIMUM DEGREE = 3  (prevents dead ends)
	-- =======================================================
	for _, node in ipairs(nodes) do
		while degree(adj, node.id) < 3 do
			local bestDist = math.huge
			local bestNode = nil
			for _, other in ipairs(nodes) do
				if other.id ~= node.id then
					local key = string.format("%d_%d", math.min(node.id, other.id), math.max(node.id, other.id))
					if not edgeMap[key] then
						local d = dist2D(node, other)
						if d < bestDist then
							bestDist = d
							bestNode = other
						end
					end
				end
			end
			if bestNode then
				local w = math.random(1, 12) * 10
				addEdge(adj, edgeMap, node.id, bestNode.id, w)
			else
				-- already connected to everyone
				break
			end
		end
	end

	-- =======================================================
	--  3. EXTRA RANDOM EDGES  (cycles / multiple paths)
	-- =======================================================
	local allEdges = {}
	for i = 1, #nodes do
		for j = i + 1, #nodes do
			local u, v = nodes[i], nodes[j]
			local key = string.format("%d_%d", math.min(u.id, v.id), math.max(u.id, v.id))
			if not edgeMap[key] then
				local d = dist2D(u, v)
				if d <= MAX_EXTRA_DIST then
					table.insert(allEdges, { u = u.id, v = v.id })
				end
			end
		end
	end

	local extraCount = math.random(5, 10)
	for i = #allEdges, 2, -1 do
		local j = math.random(i)
		allEdges[i], allEdges[j] = allEdges[j], allEdges[i]
	end
	local added = 0
	for _, edge in ipairs(allEdges) do
		if added >= extraCount then break end
		local w = math.random(1, 18) * 10
		addEdge(adj, edgeMap, edge.u, edge.v, w)
		added = added + 1
	end

	-- =======================================================
	--  4. SAFETY SWEEP – repair any bad weights
	-- =======================================================
	for nodeId, edges in pairs(adj) do
		for i, edge in ipairs(edges) do
			if type(edge.w) ~= "number" or edge.w <= 0 then
				local key = string.format("%d_%d", math.min(nodeId, edge.v), math.max(nodeId, edge.v))
				local fixedW = edgeMap[key] or math.random(1, 12) * 10
				if type(fixedW) ~= "number" or fixedW <= 0 then
					fixedW = math.random(1, 12) * 10
				end
				adj[nodeId][i].w = fixedW
				edgeMap[key] = fixedW
			end
		end
	end

	return adj, edgeMap
end

-- ============================================================
--  Dijkstra, TracePath  (unchanged)
-- ============================================================
function GraphGenerator.Dijkstra(nodesList, adj, startId, blocked)
	local dist, prev, vis, blockedSet = {}, {}, {}, {}
	if blocked then
		for _, id in ipairs(blocked) do blockedSet[id] = true end
	end
	for _, node in ipairs(nodesList) do
		dist[node.id] = math.huge
		prev[node.id] = -1
		vis[node.id]  = false
	end
	if blockedSet[startId] then return dist, prev end
	dist[startId] = 0

	for _ = 1, #nodesList do
		-- Pick the unvisited node with the smallest tentative distance
		local u = -1
		for _, node in ipairs(nodesList) do
			local v = node.id
			if not vis[v] and (u == -1 or dist[v] < dist[u]) then u = v end
		end
		if u == -1 or dist[u] == math.huge then break end
		vis[u] = true

		-- Relax edges
		for _, edge in ipairs(adj[u] or {}) do
			local v, w = edge.v, edge.w
			if not blockedSet[v] and type(w) == "number" and w > 0 then
				local newDist = dist[u] + w
				if newDist < (dist[v] or math.huge) then
					dist[v] = newDist
					prev[v] = u
				end
			end
		end
	end
	return dist, prev
end

function GraphGenerator.TracePath(prev, destId)
	local path, current, guard = {}, destId, {}
	while current ~= -1 do
		if guard[current] then
			warn("GraphGenerator: TracePath cycle detected, aborting")
			break
		end
		guard[current] = true
		table.insert(path, 1, current)
		current = prev[current]
	end
	return path
end

-- ============================================================
--  GetBestNeighbors  (REWRITTEN – always returns options)
-- ============================================================
function GraphGenerator.GetBestNeighbors(nodesList, adj, currentId, destId, visited)
	-- Build visitedSet (always exclude destination if visited,
	-- because we need a path *to* it)
	local visitedSet = {}
	for _, id in ipairs(visited) do
		visitedSet[id] = true
	end

	-- Blocked nodes for Dijkstra: all visited except destination
	local blocked = {}
	for _, id in ipairs(visited) do
		if id ~= destId then
			table.insert(blocked, id)
		end
	end

	-- Run Dijkstra from destination (gives dist[v] = cost from v to dest
	-- while avoiding visited nodes)
	local dist, _ = GraphGenerator.Dijkstra(nodesList, adj, destId, blocked)

	local neighbors = adj[currentId] or {}

	-- --- 1) Standard optimal selection (unvisited neighbors) ---
	local bestNodes = {}
	local bestVal = math.huge
	for _, edge in ipairs(neighbors) do
		local v, w = edge.v, edge.w
		if type(w) == "number" and w > 0 and not visitedSet[v] then
			local d = dist[v] or math.huge
			local total = w + d
			if total < bestVal then
				bestVal = total
				bestNodes = { v }
			elseif total == bestVal then
				table.insert(bestNodes, v)
			end
		end
	end

	if #bestNodes > 0 then
		return bestNodes
	end

	-- --- 2) Fallback: return ALL unvisited neighbors (even if they
	--     don't lead to the goal) so the player always has a choice ---
	local unvisited = {}
	for _, edge in ipairs(neighbors) do
		local v, w = edge.v, edge.w
		if type(w) == "number" and w > 0 and not visitedSet[v] then
			table.insert(unvisited, v)
		end
	end
	if #unvisited > 0 then
		return unvisited
	end

	-- --- 3) Last resort: return ALL neighbors (including visited ones)
	--     The game may then apply a heavy penalty or force a restart ---
	local all = {}
	for _, edge in ipairs(neighbors) do
		local v, w = edge.v, edge.w
		if type(w) == "number" and w > 0 then
			table.insert(all, v)
		end
	end
	return all
end

return GraphGenerator