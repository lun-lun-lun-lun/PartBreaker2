--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local VoxelVisualizationClient = {}

local GREEDY_MODE = "Greedy"
local ATTACHED_MODE = "Attached"
local UPDATE_INTERVAL = 0.25

type OriginalVisual = {
	color: Color3,
	material: Enum.Material,
	transparency: number,
}

local localPlayer = Players.LocalPlayer
local started = false
local activeMode = nil :: string?
local heartbeatConnection = nil :: RBXScriptConnection?
local elapsedSinceUpdate = 0
local random = Random.new(math.floor(os.clock() * 1000000) % 2147483647)
local boundTools: { [Tool]: boolean } = {}
local originals: { [BasePart]: OriginalVisual } = {}
local colorsByKey: { [string]: Color3 } = {}

local function isVisualizerTool(instance: Instance): boolean
	return instance:IsA("Tool")
		and instance:GetAttribute("PartBreaker2VisualizerTool") == true
		and typeof(instance:GetAttribute("PartBreaker2VisualizerMode")) == "string"
end

local function randomColor(): Color3
	return Color3.fromHSV(random:NextNumber(), random:NextNumber(0.65, 0.95), random:NextNumber(0.82, 1))
end

local function getColorForKey(key: string): Color3
	local color = colorsByKey[key]
	if color then
		return color
	end

	color = randomColor()
	colorsByKey[key] = color
	return color
end

local function getGroupKey(part: BasePart, mode: string): string?
	if mode == GREEDY_MODE then
		local greedyGroupId = part:GetAttribute("PartBreaker2GreedyGroupId")
		if typeof(greedyGroupId) == "number" then
			return `greedy:{greedyGroupId}`
		end

		return nil
	end

	local assemblyId = part:GetAttribute("PartBreaker2AssemblyId")
	if typeof(assemblyId) == "number" then
		return `attached:{assemblyId}`
	end

	return nil
end

local function isVisualizableVoxelPart(instance: Instance): boolean
	return instance:IsA("BasePart")
		and instance.Parent ~= nil
		and instance:GetAttribute("VoxelPart") == true
end

local function storeOriginal(part: BasePart)
	if originals[part] then
		return
	end

	originals[part] = {
		color = part.Color,
		material = part.Material,
		transparency = part.Transparency,
	}
end

local function restoreOriginals()
	for part, original in originals do
		if part.Parent ~= nil then
			part.Color = original.color
			part.Material = original.material
			part.Transparency = original.transparency
		end
	end

	table.clear(originals)
end

local function pruneOriginals()
	for part in originals do
		if not isVisualizableVoxelPart(part) then
			originals[part] = nil
		end
	end
end

local function applyVisualization()
	local mode = activeMode
	if not mode then
		return
	end

	pruneOriginals()

	for _, descendant in Workspace:GetDescendants() do
		if not isVisualizableVoxelPart(descendant) then
			continue
		end

		local part = descendant :: BasePart
		local key = getGroupKey(part, mode)
		if not key then
			continue
		end

		storeOriginal(part)
		part.Color = getColorForKey(key)
		part.Material = Enum.Material.Neon
		local original = originals[part]
		if original then
			part.Transparency = math.min(original.transparency, 0.12)
		end
	end
end

local function stopHeartbeat()
	if heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
	elapsedSinceUpdate = 0
end

local function startHeartbeat()
	if heartbeatConnection then
		return
	end

	heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
		elapsedSinceUpdate += deltaTime
		if elapsedSinceUpdate < UPDATE_INTERVAL then
			return
		end

		elapsedSinceUpdate = 0
		applyVisualization()
	end)
end

local function setMode(mode: string?)
	if activeMode == mode then
		activeMode = nil
		stopHeartbeat()
		restoreOriginals()
		table.clear(colorsByKey)
		return
	end

	restoreOriginals()
	table.clear(colorsByKey)
	activeMode = mode

	if activeMode then
		applyVisualization()
		startHeartbeat()
	else
		stopHeartbeat()
	end
end

local function bindTool(tool: Tool)
	if boundTools[tool] then
		return
	end
	boundTools[tool] = true

	tool.Activated:Connect(function()
		local mode = tool:GetAttribute("PartBreaker2VisualizerMode")
		if typeof(mode) ~= "string" then
			return
		end

		setMode(mode)
	end)

	tool.Destroying:Connect(function()
		boundTools[tool] = nil
	end)
end

local function scanContainer(container: Instance?)
	if not container then
		return
	end

	for _, child in container:GetChildren() do
		if isVisualizerTool(child) then
			bindTool(child :: Tool)
		end
	end
end

local function watchContainer(container: Instance?)
	if not container then
		return
	end

	scanContainer(container)
	container.ChildAdded:Connect(function(child)
		if isVisualizerTool(child) then
			bindTool(child :: Tool)
		end
	end)
end

function VoxelVisualizationClient.start()
	if started then
		return
	end
	started = true

	watchContainer(localPlayer:WaitForChild("Backpack", 10))
	watchContainer(localPlayer.Character)

	localPlayer.CharacterAdded:Connect(function(character)
		watchContainer(character)
	end)
end

return VoxelVisualizationClient
