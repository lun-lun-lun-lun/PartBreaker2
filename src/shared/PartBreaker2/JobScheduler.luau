--!strict
--!native

local RunService = game:GetService("RunService")

local Types = require(script.Parent.Types)

local JobScheduler = {}
JobScheduler.__index = JobScheduler

type RuntimeBudgets = Types.RuntimeBudgets
type RuntimeStats = Types.RuntimeStats
type BudgetKey = Types.BudgetKey
type BudgetContext = Types.BudgetContext

type WorkItem = {
	thread: thread,
	name: string,
}

export type Scheduler = typeof(setmetatable(
	{} :: {
		queue: { WorkItem },
		head: number,
		processing: boolean,
		budgets: { [string]: number },
		remaining: { [string]: number },
		stats: RuntimeStats,
		connection: RBXScriptConnection?,
		context: BudgetContext,
	},
	JobScheduler
))

local DEFAULT_BUDGETS = {
	tasks = 4,
	records = 3,
	voxelTests = 6000,
	connectivityVisits = 8000,
	greedyVisits = 10000,
	partsCommitted = 96,
	supportQueries = 80,
	weldOps = 160,
}

local BUDGET_FIELDS: { [string]: string } = {
	tasks = "maxTasksPerFrame",
	records = "maxRecordsPerFrame",
	voxelTests = "maxVoxelTestsPerFrame",
	connectivityVisits = "maxConnectivityVisitsPerFrame",
	greedyVisits = "maxGreedyVisitsPerFrame",
	partsCommitted = "maxPartsCommittedPerFrame",
	supportQueries = "maxSupportQueriesPerFrame",
	weldOps = "maxWeldOpsPerFrame",
}

local function normalizeBudgets(config: RuntimeBudgets?): { [string]: number }
	local budgets = {}
	for key, defaultValue in DEFAULT_BUDGETS do
		local field = BUDGET_FIELDS[key]
		local configured = if config then (config :: any)[field] else nil
		budgets[key] = if typeof(configured) == "number" and configured > 0 then math.floor(configured) else defaultValue
	end
	return budgets
end

local function makeContext(self: Scheduler): BudgetContext
	local context = {} :: any
	local scheduler = self

	function context.consume(_context: BudgetContext, key: BudgetKey, amount: number?)
		local budgetKey = key :: string
		local requested = amount or 1
		if requested <= 0 then
			return
		end

		while true do
			local remaining = scheduler.remaining[budgetKey]
			if remaining == nil then
				return
			end

			if remaining >= requested then
				scheduler.remaining[budgetKey] = remaining - requested
				return
			end

			scheduler.stats.budgetYields += 1
			coroutine.yield()
		end
	end

	context.stats = scheduler.stats
	return context :: BudgetContext
end

local function resetRemaining(self: Scheduler)
	for key, amount in self.budgets do
		self.remaining[key] = amount
	end
end

function JobScheduler.new(stats: RuntimeStats, budgets: RuntimeBudgets?): Scheduler
	local self = setmetatable({
		queue = {},
		head = 1,
		processing = false,
		budgets = normalizeBudgets(budgets),
		remaining = {},
		stats = stats,
		connection = nil,
		context = nil :: any,
	}, JobScheduler) :: Scheduler

	self.context = makeContext(self)
	self.connection = RunService.Heartbeat:Connect(function()
		self:step()
	end)

	return self
end

function JobScheduler.configure(self: Scheduler, budgets: RuntimeBudgets?)
	self.budgets = normalizeBudgets(budgets)
end

function JobScheduler.enqueue(self: Scheduler, name: string, work: (BudgetContext) -> ())
	self.queue[#self.queue + 1] = {
		name = name,
		thread = coroutine.create(work),
	}
	self.stats.jobsQueued += 1
	self.stats.queueLength = self:pendingCount()
end

function JobScheduler.pendingCount(self: Scheduler): number
	return math.max(0, #self.queue - self.head + 1)
end

function JobScheduler.step(self: Scheduler)
	if self.processing then
		return
	end

	self.processing = true
	resetRemaining(self)

	while self.head <= #self.queue do
		if (self.remaining["tasks"] or 0) <= 0 then
			break
		end
		self.remaining["tasks"] -= 1

		local item = self.queue[self.head]
		local success, err = coroutine.resume(item.thread, self.context)
		if not success then
			warn(`PartBreaker2 job "{item.name}" failed: {err}`)
			self.head += 1
			continue
		end

		if coroutine.status(item.thread) == "dead" then
			self.stats.jobsCompleted += 1
			self.queue[self.head] = nil :: any
			self.head += 1
		else
			break
		end
	end

	if self.head > #self.queue then
		table.clear(self.queue)
		self.head = 1
	end

	self.stats.queueLength = self:pendingCount()
	self.processing = false
end

function JobScheduler.flush(self: Scheduler, maxFrames: number?)
	local frameLimit = maxFrames or 10000
	local frames = 0

	while self.head <= #self.queue and frames < frameLimit do
		self:step()
		frames += 1
	end
end

function JobScheduler.destroy(self: Scheduler)
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	table.clear(self.queue)
	self.head = 1
	self.stats.queueLength = 0
end

return JobScheduler
