-- RagdollTrap.lua
-- Place inside: ServerScriptService
--
-- Creates invisible trigger zones (TrapParts) anywhere you put them in
-- Workspace inside a folder called "RagdollTraps".
--
-- When a player's character touches a trap part:
--   1. The Humanoid is forced into the ragdoll state (motor6D joints
--      disabled, loose BodyVelocity flings the character).
--   2. A screen-space "😵 STUNNED!" GUI is shown to the victim.
--   3. After STUN_DURATION seconds the character is recovered: joints
--      re-enabled, humanoid state restored, GUI removed.
--
-- HOW TO SET UP TRAPS IN STUDIO:
--   • Create a Folder in Workspace named "RagdollTraps".
--   • Inside it put any number of Parts (any size/shape/position).
--   • Set each part's Transparency to 1 and CanCollide to false.
--   • This script does that automatically for every part it finds,
--     so you only need to position them.
--   • Optionally set an attribute  TrapLabel (string) on a part to
--     show a custom message ("💀 Banana!", "⚡ Choque!", etc.).
--
-- The script also auto-refreshes when children are added to the folder,
-- so you can add traps at runtime without restarting.

local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")

-- ─────────────────────────────────────────────
-- CONFIG
-- ─────────────────────────────────────────────
local TRAPS_FOLDER_NAME = "RagdollTraps"
local STUN_DURATION     = 3.5    -- seconds the player stays ragdolled
local FLING_FORCE       = 35     -- upward/random fling velocity on stun
local COOLDOWN          = 5      -- seconds before the same player can be
                                 -- trapped again (prevents re-trigger spam)

-- ─────────────────────────────────────────────
-- STATE
-- ─────────────────────────────────────────────
local stunnedPlayers = {}   -- [player] = true while stunned / on cooldown

-- ─────────────────────────────────────────────
-- RAGDOLL HELPERS
-- ─────────────────────────────────────────────

-- Disables all Motor6D joints in the character so limbs go limp.
-- Returns a list of the disabled motors so we can re-enable them later.
local function disableMotors(character)
	local motors = {}
	for _, obj in ipairs(character:GetDescendants()) do
		if obj:IsA("Motor6D") and obj.Enabled then
			obj.Enabled = false
			table.insert(motors, obj)
		end
	end
	return motors
end

-- Re-enables the motors returned by disableMotors.
local function enableMotors(motors)
	for _, motor in ipairs(motors) do
		if motor and motor.Parent then
			motor.Enabled = true
		end
	end
end

-- Creates BallSocketConstraints between the same parts as each Motor6D
-- so limbs still collide physically while ragdolled. Returns a list of
-- the constraints to clean up on recovery.
local function addRagdollConstraints(character)
	local constraints = {}
	for _, obj in ipairs(character:GetDescendants()) do
		if obj:IsA("Motor6D") and not obj.Enabled then
			local a0 = Instance.new("Attachment")
			local a1 = Instance.new("Attachment")
			a0.CFrame = obj.C0;  a0.Parent = obj.Part0
			a1.CFrame = obj.C1;  a1.Parent = obj.Part1

			local bsc = Instance.new("BallSocketConstraint")
			bsc.Attachment0 = a0
			bsc.Attachment1 = a1
			bsc.LimitsEnabled = true
			bsc.TwistLimitsEnabled = false
			bsc.UpperAngle = 45
			bsc.Parent = obj.Part0

			table.insert(constraints, {bsc, a0, a1})
		end
	end
	return constraints
end

-- Destroys the BallSocketConstraints and their attachments.
local function removeRagdollConstraints(constraints)
	for _, group in ipairs(constraints) do
		for _, obj in ipairs(group) do
			if obj and obj.Parent then obj:Destroy() end
		end
	end
end

-- Flings the character in a random-ish upward direction.
local function flingCharacter(character)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local randomDir = Vector3.new(
		math.random(-100, 100) / 100,
		1,
		math.random(-100, 100) / 100
	).Unit
	local bv = Instance.new("BodyVelocity")
	bv.Velocity        = randomDir * FLING_FORCE
	bv.MaxForce        = Vector3.new(1e5, 1e5, 1e5)
	bv.P               = 1e4
	bv.Parent          = hrp
	game.Debris:AddItem(bv, 0.25)   -- remove after a short burst
end

-- ─────────────────────────────────────────────
-- STUN GUI (shown on the victim's screen)
-- ─────────────────────────────────────────────
local function showStunGui(player, label)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return end

	local sg = Instance.new("ScreenGui")
	sg.Name           = "RagdollStunGui"
	sg.ResetOnSpawn   = false
	sg.ZIndex         = 200

	local frame = Instance.new("Frame", sg)
	frame.Size                = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3    = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.55
	frame.BorderSizePixel     = 0

	local lbl = Instance.new("TextLabel", frame)
	lbl.Size                  = UDim2.new(1, 0, 0, 80)
	lbl.Position              = UDim2.new(0, 0, 0.4, 0)
	lbl.BackgroundTransparency = 1
	lbl.Text                  = label or "😵  ATORDOADO!"
	lbl.Font                  = Enum.Font.GothamBlack
	lbl.TextSize              = 52
	lbl.TextColor3            = Color3.fromRGB(255, 80, 80)
	lbl.TextStrokeColor3      = Color3.new(0, 0, 0)
	lbl.TextStrokeTransparency = 0.2

	local sub = Instance.new("TextLabel", frame)
	sub.Size                  = UDim2.new(1, 0, 0, 30)
	sub.Position              = UDim2.new(0, 0, 0.4, 80)
	sub.BackgroundTransparency = 1
	sub.Text                  = "recuperando em " .. STUN_DURATION .. "s..."
	sub.Font                  = Enum.Font.GothamMedium
	sub.TextSize              = 20
	sub.TextColor3            = Color3.fromRGB(220, 180, 180)

	sg.Parent = playerGui
	return sg
end

local function removeStunGui(player)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return end
	local sg = playerGui:FindFirstChild("RagdollStunGui")
	if sg then sg:Destroy() end
end

-- ─────────────────────────────────────────────
-- STUN LOGIC
-- ─────────────────────────────────────────────
local function stunPlayer(player, trapLabel)
	if stunnedPlayers[player] then return end
	local character = player.Character
	if not character then return end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return end

	stunnedPlayers[player] = true

	-- Enter ragdoll
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	local motors      = disableMotors(character)
	local constraints = addRagdollConstraints(character)
	flingCharacter(character)

	-- Show stun overlay
	local gui = showStunGui(player, trapLabel)

	-- Recover after STUN_DURATION
	task.delay(STUN_DURATION, function()
		-- Guard: player may have left or respawned
		if not player or not player.Parent then
			stunnedPlayers[player] = nil
			return
		end
		local char2 = player.Character
		if char2 == character then
			-- Same character: restore joints
			removeRagdollConstraints(constraints)
			enableMotors(motors)
			local hum2 = char2:FindFirstChildOfClass("Humanoid")
			if hum2 then
				hum2:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end
		-- Remove GUI regardless
		removeStunGui(player)

		-- Cooldown before the player can be trapped again
		task.delay(COOLDOWN, function()
			stunnedPlayers[player] = nil
		end)
	end)
end

-- ─────────────────────────────────────────────
-- TRAP SETUP
-- ─────────────────────────────────────────────
local function setupTrapPart(part)
	-- Make the part invisible and non-colliding so it's a hidden trigger
	part.Transparency = 1
	part.CanCollide   = false
	part.CanQuery     = false   -- don't block raycasts
	part.Anchored     = true
	part.Name         = part.Name  -- keep whatever name the designer gave it

	local trapLabel = part:GetAttribute("TrapLabel")  -- optional custom message

	part.Touched:Connect(function(hit)
		-- Identify which player touched it
		local character = hit.Parent
		if not character then return end
		local player = Players:GetPlayerFromCharacter(character)
		if not player then return end
		stunPlayer(player, trapLabel)
	end)

	print("[RagdollTrap] Trap registered: " .. part:GetFullName())
end

-- ─────────────────────────────────────────────
-- FOLDER WATCHER
-- ─────────────────────────────────────────────
local function watchFolder(folder)
	-- Set up existing parts
	for _, part in ipairs(folder:GetChildren()) do
		if part:IsA("BasePart") then
			setupTrapPart(part)
		end
	end

	-- Watch for new parts added at runtime (useful in Studio live mode)
	folder.ChildAdded:Connect(function(child)
		if child:IsA("BasePart") then
			task.wait()  -- let the part fully initialize
			setupTrapPart(child)
		end
	end)
end

-- Clean up stun state when a player respawns (their character changes)
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		-- On respawn, clear stun state so they aren't permanently immune
		task.delay(1, function()
			stunnedPlayers[player] = nil
		end)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	stunnedPlayers[player] = nil
end)

-- ─────────────────────────────────────────────
-- ENTRY POINT
-- ─────────────────────────────────────────────
local trapsFolder = Workspace:FindFirstChild(TRAPS_FOLDER_NAME)
if trapsFolder then
	watchFolder(trapsFolder)
else
	-- Folder doesn't exist yet — wait for it to appear (useful if the
	-- map loads after this script runs, e.g. in streaming-enabled games)
	warn("[RagdollTrap] Folder '" .. TRAPS_FOLDER_NAME .. "' not found in Workspace. "
		.. "Create it and add BaseParts inside to define trap zones. "
		.. "Watching for it to appear...")
	Workspace.ChildAdded:Connect(function(child)
		if child.Name == TRAPS_FOLDER_NAME then
			watchFolder(child)
		end
	end)
end

print("[RagdollTrap] Loaded. Traps folder: " .. TRAPS_FOLDER_NAME
	.. " | Stun: " .. STUN_DURATION .. "s | Cooldown: " .. COOLDOWN .. "s")
