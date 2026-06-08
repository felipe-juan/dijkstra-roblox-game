local GraphGenerator = {}

-- Euclidean distance (XZ plane)
local function dist2D(a, b)
	local dx = a.x - b.x
	local dz = a.z - b.z
	return math.sqrt(dx*dx + dz*dz)
end

-- Helper to add an edge (only if not already present)
local function addEdge(adj, edgeMap, u, v, w)
	local key = string.format("%d_%d", math.min(u, v), math.max(u, v))
	if edgeMap[key] then return end   -- already exists, skip
	
	table.insert(adj[u], {v = v, w = w})
	table.insert(adj[v], {v = u, w = w})
	edgeMap[key] = w
end

function GraphGenerator.BuildGraph(nodesList)
	local adj = {}
	local edgeMap = {}
	
	-- Clean duplicate positions (keep first)
	local seen = {}
	local cleanList = {}
	for _, node in ipairs(nodesList) do
		local key = string.format("%.1f_%.1f", node.x, node.z)
		if not seen[key] then
			seen[key] = true
			table.insert(cleanList, node)
		else
			warn("GraphGenerator: Duplicate position ignored for node", node.id)
		end
	end
	nodesList = cleanList
	
	for _, node in ipairs(nodesList) do
		adj[node.id] = {}
	end
	
	-- 1. Build list of all possible edges (with distance)
	local allEdges = {}
	for i = 1, #nodesList do
		local u = nodesList[i]
		for j = i+1, #nodesList do
			local v = nodesList[j]
			local d = dist2D(u, v)
			-- Ignore extremely close nodes (< 10 studs)
			if d >= 10 then
				table.insert(allEdges, {
					u = u.id,
					v = v.id,
					dist = d,
				})
			end
		end
	end
	
	-- 2. Sort by distance (shortest first)
	table.sort(allEdges, function(a, b) return a.dist < b.dist end)
	
	-- 3. For each node, connect to its 3 nearest neighbours (local connectivity)
	local neighbourCount = {}
	for _, node in ipairs(nodesList) do
		neighbourCount[node.id] = 0
	end
	
	for _, edge in ipairs(allEdges) do
		local u, v = edge.u, edge.v
		if neighbourCount[u] < 3 and neighbourCount[v] < 3 then
			local w = math.random(1, 12) * 10
			addEdge(adj, edgeMap, u, v, w)
			neighbourCount[u] = neighbourCount[u] + 1
			neighbourCount[v] = neighbourCount[v] + 1
		end
	end
	
	-- 4. Kruskal to ensure full connectivity (using all remaining unused edges)
	local parent = {}
	for _, node in ipairs(nodesList) do
		parent[node.id] = node.id
	end
	local function find(i)
		if parent[i] == i then return i end
		parent[i] = find(parent[i])
		return parent[i]
	end
	
	-- First union all already added edges
	for key, _ in pairs(edgeMap) do
		local parts = string.split(key, "_")
		local u = tonumber(parts[1])
		local v = tonumber(parts[2])
		local ru, rv = find(u), find(v)
		if ru ~= rv then
			parent[ru] = rv
		end
	end
	
	-- Now run Kruskal on allEdges, adding any missing ones that connect components
	for _, edge in ipairs(allEdges) do
		local u, v = edge.u, edge.v
		local key = string.format("%d_%d", math.min(u, v), math.max(u, v))
		if edgeMap[key] == nil then   -- not yet added
			local ru, rv = find(u), find(v)
			if ru ~= rv then
				parent[ru] = rv
				local w = math.random(1, 18) * 10
				addEdge(adj, edgeMap, u, v, w)
			end
		end
	end
	
	-- 5. Extra random edges (cycles)
	local extraCount = math.random(5, 10)
	local addedExtra = 0
	-- Shuffle allEdges to pick randomly
	for i = #allEdges, 2, -1 do
		local j = math.random(i)
		allEdges[i], allEdges[j] = allEdges[j], allEdges[i]
	end
	for _, edge in ipairs(allEdges) do
		if addedExtra >= extraCount then break end
		local key = string.format("%d_%d", math.min(edge.u, edge.v), math.max(edge.u, edge.v))
		if edgeMap[key] == nil then
			local w = math.random(1, 18) * 10
			addEdge(adj, edgeMap, edge.u, edge.v, w)
			addedExtra = addedExtra + 1
		end
	end
	
	return adj, edgeMap
end

-- (Dijkstra, TracePath, GetBestNeighbors – unchanged)
function GraphGenerator.Dijkstra(nodesList, adj, startId, blocked)
	local dist = {}
	local prev = {}
	local vis = {}
	local blockedSet = {}
	if blocked then
		for _, id in ipairs(blocked) do blockedSet[id] = true end
	end

	for _, node in ipairs(nodesList) do
		dist[node.id] = math.huge
		prev[node.id] = -1
		vis[node.id] = false
	end

	if blockedSet[startId] then return dist, prev end
	dist[startId] = 0

	for i = 1, #nodesList do
		local u = -1
		for _, node in ipairs(nodesList) do
			local v = node.id
			if not vis[v] and (u == -1 or dist[v] < dist[u]) then
				u = v
			end
		end

		if u == -1 or dist[u] == math.huge then break end
		vis[u] = true

		for _, edge in ipairs(adj[u]) do
			local v = edge.v
			local w = edge.w
			if not blockedSet[v] then
				if dist[u] + w < dist[v] then
					dist[v] = dist[u] + w
					prev[v] = u
				end
			end
		end
	end

	return dist, prev
end

function GraphGenerator.TracePath(prev, destId)
	local p = {}
	local c = destId
	while c ~= -1 do
		table.insert(p, 1, c)
		c = prev[c]
	end
	return p
end

function GraphGenerator.GetBestNeighbors(nodesList, adj, currentId, destId, visited)
	local dist, _ = GraphGenerator.Dijkstra(nodesList, adj, destId, visited)
	local neighbors = adj[currentId] or {}

	local bestNodes = {}
	local bestVal = math.huge

	for _, edge in ipairs(neighbors) do
		local v = edge.v
		local w = edge.w

		local isVisited = false
		for _, visId in ipairs(visited) do
			if visId == v then isVisited = true break end
		end

		if not isVisited then
			local d = dist[v] or math.huge
			local total = w + d
			if total < bestVal then
				bestVal = total
				bestNodes = {v}
			elseif total == bestVal then
				table.insert(bestNodes, v)
			end
		end
	end

	return bestNodes
end

return GraphGenerator