--!strict

local VoxelDebrisClient = require(script:WaitForChild("VoxelDebrisClient"))
local VoxelDestructionTestClient = require(script:WaitForChild("VoxelDestructionTestClient"))
local VoxelVisualizationClient = require(script:WaitForChild("VoxelVisualizationClient"))

VoxelDebrisClient.start()
VoxelDestructionTestClient.start()
VoxelVisualizationClient.start()
