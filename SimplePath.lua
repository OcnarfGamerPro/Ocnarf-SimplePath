--[[
-------------------------------------------------------------------

Created by: @V3N0M_Z
Reference: https://v3n0m-z.github.io/RBLX-SimplePath/
License: MIT

Most comments (and some code edits) by: Ocnarf

---------------------------------------------------------------------
]]


-- default settings
local DEFAULT_SETTINGS = {

	TIME_VARIANCE = 0.07; -- min time between each Run call for each Path -- If you make this value lower (e.g. 0), I recommend u increase the value of COMPARISON_CHECKS to something like 4+ otherwise the agent is gonna be bouncing

	COMPARISON_CHECKS = 1; -- the number that _position._count has to be GTE in order to trigger the Error event with AgentStuck error type 

	JUMP_WHEN_STUCK = true; -- determines if the agent should jump when it is stuck (works directly with COMPARISON_CHECK)
}

---------------------------------------------------------------------

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")


local function output(func, msg) -- custom output func 
	func(((func == error and "SimplePath Error: ") or "SimplePath: ")..msg)
end


local Path = {
	
	StatusType = { -- path statuses
		Idle = "Idle";
		Active = "Active";
	};
	
	ErrorType = { -- used to determine the type of error received from an Error event
		LimitReached = "LimitReached"; -- when elapsed time between Run calls is less than Settings.TIME_VARIANCE
		TargetUnreachable = "TargetUnreachable"; -- This error should be called WaypointUnreachable since it errors when the MoveToFinished times out (agent couldnt reach next waypoint)
		ComputationError = "ComputationError"; -- pathfinding computation failed
		AgentStuck = "AgentStuck"; -- Agent stuck (possibly due to an obstruction of some kind). When the agent does not move for Settings.COMPARISON_CHECKS + 1 consecutive Path.Run calls
	};
	
}


-- this function will only return non nil when ur trying to get an event from Path or its LastError or its Status or anything belonging to the Path class including it's status and error types and functions
-- so basically the last "or Path[index]" is just like setting Path.__index = Path
Path.__index = function(table, index) -- table is the Path object
	
	if index == "Stopped" and not table._humanoid then -- if u try to index the Stopped event for a Path with no humanoid it errors
		output(error, "Attempt to use Path.Stopped on a non-humanoid.")
	end
	
	return (table._events[index] and table._events[index].Event)
		or (index == "LastError" and table._lastError)
		or (index == "Status" and table._status)
		or Path[index]
end


--Used to visualize waypoints
local visualWaypoint = Instance.new("Part")
visualWaypoint.Size = Vector3.new(0.3, 0.3, 0.3)
visualWaypoint.Anchored = true
visualWaypoint.CanCollide = false
visualWaypoint.Material = Enum.Material.Neon
visualWaypoint.Shape = Enum.PartType.Ball


--[[ PRIVATE FUNCTIONS ]]--

local function declareError(self, errorType) -- self is the Path object
	self._lastError = errorType
	self._events.Error:Fire(errorType) -- fires the Error event
end

--Create visual waypoints
local function createVisualWaypoints(waypoints)
	
	local visualWaypoints = {}
	
	for _, waypoint in ipairs(waypoints) do
		
		local visualWaypointClone = visualWaypoint:Clone() -- clones the original visual part
		visualWaypointClone.Position = waypoint.Position 
		visualWaypointClone.Parent = workspace 
		visualWaypointClone.Color =
			(waypoint == waypoints[#waypoints] and Color3.fromRGB(0, 255, 0))
			or (waypoint.Action == Enum.PathWaypointAction.Jump and Color3.fromRGB(255, 0, 0))
			or Color3.fromRGB(255, 139, 0) -- sets color to green if the waypoint is the last one, red if it isn't last and its action is to jump and else, orange
		
		table.insert(visualWaypoints, visualWaypointClone)
	end
	
	return visualWaypoints
end

--Destroy visual waypoints
local function destroyVisualWaypoints(waypoints)
	
	if waypoints then
		for _, waypoint in ipairs(waypoints) do
			waypoint:Destroy()
		end
	end
	
	return
end

--Get initial waypoint for non-humanoid
-- Only called in one place, the Run function, in order to get the current waypoint for non humanoid. Idk why this is even a thing
local function getNonHumanoidWaypoint(self)
	--Account for multiple waypoints that are sometimes in the same place
	for i = 2, #self._waypoints do
		-- if feel like this is logically flawed because imagine that
		-- the first 100 waypoints are 0.1 studs away from their lower neighbor and then waypoint 101 is >0.1 studs away from waypoint 100 so then this if statement is finally passed
		-- and it returns the index of waypoint 101. That waypoint 101 is very far away from the very first waypoint
		if (self._waypoints[i].Position - self._waypoints[i - 1].Position).Magnitude > 0.1 then -- if the distance between two consecutive waypoints is greater than 0.1 then return that waypoint index
			return i
		end
		
	end
	
	return 2 -- if no consecutive waypoints passed the test, it just returns the 2nd waypoint
end

--Make NPC jump
local function setJumpState(self)
	
	pcall(function()
		-- if the agent humanoid isn't already jumping nor falling then it should jump
		if self._humanoid:GetState() ~= Enum.HumanoidStateType.Jumping and self._humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then 
			self._humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
		
	end)
end

--Primary move function
-- Only fired in one place, the moveToFinished function, in order to move he humanoid to the waypoint
local function move(self)
	
	if self._waypoints[self._currentWaypoint].Action == Enum.PathWaypointAction.Jump then -- if the action is to jump then it jumps
		setJumpState(self)
	end
	
	self._humanoid:MoveTo(self._waypoints[self._currentWaypoint].Position) -- make the humanoid walk to the current waypoint
end

--Disconnect MoveToFinished connection when pathfinding ends
-- only fired in the moveToFinshed function when either the last waypoint is reached or moveToFinished fired but didn't actually reach. It is also fired when the Path object is destroyed
local function disconnectMoveConnection(self)
	self._moveConnection:Disconnect()
	self._moveConnection = nil
end

--Fire the WaypointReached event
local function invokeWaypointReached(self)
	local lastWaypoint = self._waypoints[self._currentWaypoint - 1]
	local nextWaypoint = self._waypoints[self._currentWaypoint]
	self._events.WaypointReached:Fire(self._agent, lastWaypoint, nextWaypoint)
end

local function moveToFinished(self, reached)

	--Stop execution if Path is destroyed
	if not getmetatable(self) then return end

	--Handle case for non-humanoids (and return so it doesnt also do the case for humanoids)
	if not self._humanoid then
		
		-- if the next waypoint is before the last waypoint or is the last waypoint
		if reached and self._currentWaypoint + 1 <= #self._waypoints then 
			invokeWaypointReached(self) -- fires the waypoint reached event
			self._currentWaypoint += 1
			
		elseif reached then --Target reached, pathfinding ends (self._currentWaypoint + 1 > #self._waypoints (aka there are no more waypoints ahead))
			
			-- destroy visuals, set target to nil, fire Reached event
			self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
			self._target = nil
			self._events.Reached:Fire(self._agent, self._waypoints[self._currentWaypoint])
			
		else
			
			-- destroy visuals, set target to nil, fire Error event with TargetUnreachable error type
			self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
			self._target = nil
			declareError(self, self.ErrorType.TargetUnreachable)
		end
		
		return
	end

	if reached and self._currentWaypoint + 1 <= #self._waypoints then --Waypoint reached
		
		-- if the next waypoint is not the last waypoint 
		if self._currentWaypoint + 1 < #self._waypoints then
			invokeWaypointReached(self) -- just fires the waypoint reached event
		end
		self._currentWaypoint += 1
		
		move(self) -- humanoid:MoveTo waypoint (or jump to)
		
	elseif reached then --Target reached, pathfinding ends (self._currentWaypoint + 1 equals #self._waypoints)
		
		disconnectMoveConnection(self) -- disconnects the _moveConnection 
		
		self._status = Path.StatusType.Idle -- sets status to idle since it reached the last waypoint
		self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints) -- destroys the visuals
		
		self._events.Reached:Fire(self._agent, self._waypoints[self._currentWaypoint]) -- fires the reached function
		
	else --Target unreachable (more specifically the waypoint is unreachable)
		
		disconnectMoveConnection(self) -- disconnects the _moveConnection
		
		self._status = Path.StatusType.Idle -- sets status to idle
		self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints) -- remove visuals
		
		declareError(self, self.ErrorType.TargetUnreachable) -- fire the error event with TargetUnreachable (the movetofinished timed out)
		
	end
end


--Refer to Settings.COMPARISON_CHECKS
-- This function is fired every Run call (after path generation is a success)
local function comparePosition(self)
	
	-- if the current waypoint is the last waypoint then return 
	if self._currentWaypoint == #self._waypoints then return end
	
	-- self._position._count is incremented by 1 if the agent pos is too close to its pos from the previous Run call. If it isn't too close then count is reset to 0
	self._position._count = ((self._agent.PrimaryPart.Position - self._position._last).Magnitude <= 0.07 and (self._position._count + 1)) or 0
	
	-- self._position._last set to agent pos of this Run call
	self._position._last = self._agent.PrimaryPart.Position
	
	-- if _count is GTE COMPARISON_CHECKS then the agent is stuck so it fires error event with AgentStuck
	if self._position._count >= self._settings.COMPARISON_CHECKS then
		
		-- if this setting is enabled then it jumps
		if self._settings.JUMP_WHEN_STUCK then
			setJumpState(self)
		end
		
		declareError(self, self.ErrorType.AgentStuck)
	end
end


--[[ STATIC METHODS ]]--
function Path.GetNearestCharacter(fromPosition) -- just a standard getNearestChar function
	local character, dist = nil, math.huge
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character and (player.Character.PrimaryPart.Position - fromPosition).Magnitude < dist then
			character, dist = player.Character, (player.Character.PrimaryPart.Position - fromPosition).Magnitude
		end
	end
	return character
end


--[[ CONSTRUCTOR ]]--
function Path.new(agent, agentParameters, override)
	
	if not (agent and agent:IsA("Model") and agent.PrimaryPart) then -- checking to see if agent is model and has prim part
		output(error, "Pathfinding agent must be a valid Model Instance with a set PrimaryPart.")
	end
	
	-- more stuff are added to self in other function calls
	local self = setmetatable({
		_settings = override or DEFAULT_SETTINGS; -- settings of the path are override or default
		_events = { -- creating roblox events for all path events
			Reached = Instance.new("BindableEvent");
			WaypointReached = Instance.new("BindableEvent");
			Blocked = Instance.new("BindableEvent");
			Error = Instance.new("BindableEvent");
			Stopped = Instance.new("BindableEvent");
		};
		_agent = agent; -- the agent model
		_humanoid = agent:FindFirstChildOfClass("Humanoid"); -- the agent humanoid
		_path = PathfindingService:CreatePath(agentParameters); -- path created with PFS
		_status = "Idle"; -- initial path status set to idle
		_t = 0; -- time since Run function last fired
		_position = { -- position data
			_last = Vector3.new();
			_count = 0;
		};
	}, Path) -- Path object

	--Configure settings
	-- Makes sure to add the default values to settings in case u didnt provide certain keys in 
	for setting, value in pairs(DEFAULT_SETTINGS) do
		self._settings[setting] = self._settings[setting] == nil and value or self._settings[setting]
	end

	--Path blocked connection
	-- 
	-- self._currentWaypoint is created in the first Run call
	self._path.Blocked:Connect(function(blockedWaypointIndex) -- changed ... to blockedWaypointIndex 
		
		-- I removed the if statement here because it's checking to see if the PFS path blocked event fired when the blocked waypoint is either the current waypoint or the waypoint directly ahead
		-- Which isn't good because imagine if this blocked event is fired and the currentwaypoint is several waypoints behind the blocked waypoint,
		-- it won't pass this if statement and therefore won't fire the custom blocked event
		--if (self._currentWaypoint <= blockedWaypointIndex and self._currentWaypoint + 1 >= blockedWaypointIndex) and self._humanoid then
		
			-- I removed this setJumpState because let's be real, if the path is blocked, a jump is almost never gonna solve it
			--setJumpState(self) -- make humanoid jump
			
			self._events.Blocked:Fire(self._agent, self._waypoints[blockedWaypointIndex]) -- custom Blocked event fired
		--end
	end)

	return self
end


--[[ NON-STATIC METHODS ]]--
-- Object methods
function Path:Destroy()
	
	-- destroy all events and their connections
	for _, event in ipairs(self._events) do
		event:Destroy() 
	end
	self._events = nil
	
	-- sets _visualWaypoints to nil
	-- if it doesnt use rawget() then it will fire the function set to __index which has a line of code that tries to index something in _events 
	-- but _events was already set to nil before this line of code here so it will error.
	-- honestly it would be better to just remove the visuals before setting _events to nil
	if rawget(self, "_visualWaypoints") then 
		self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints) -- returns nil 
	end
	
	-- destroys the roblox path
	self._path:Destroy()
	
	-- removes self's metatable (Path) 
	setmetatable(self, nil)
	
	-- sets all keys to nil leaving u with an empty table
	for k, _ in pairs(self) do
		self[k] = nil
	end
end



function Path:Stop()
	
	-- errors if Path has no humanoid
	if not self._humanoid then
		output(error, "Attempt to call Path:Stop() on a non-humanoid.")
		return
	end
	
	-- If path is idle then just give a warn and return
	if self._status == Path.StatusType.Idle then
		output(function(m)
			warn(debug.traceback(m))
		end, "Attempt to run Path:Stop() in idle state")
		return
	end
	
	-- disconnects the _moveConnection (movetofinished)
	disconnectMoveConnection(self)
	
	-- set status to idle, destroy visuals, fire Stopped event
	self._status = Path.StatusType.Idle
	self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
	self._events.Stopped:Fire(self._model)
end


-- This is the method that u should be calling frequently
-- It generates a path with PFS and causes the humanoid to MoveTo along the waypoints
-- It returns false if the time elapsed since last Run call isn't greater than time_variance
-- It also returns false if something went wrong with the path generation
function Path:Run(target)

	--Non-humanoid handle case
	if not target and not self._humanoid and self._target then
		moveToFinished(self, true)
		return
	end

	--Parameter check
	-- if the target argument isnt a vector3 nor basepart then error
	if not (target and (typeof(target) == "Vector3" or target:IsA("BasePart"))) then
		output(error, "Pathfinding target must be a valid Vector3 or BasePart.")
	end

	--Refer to Settings.TIME_VARIANCE
	-- checks if elapsed time since last Run call is LTE time_variance (not enough time has passed since last Run call). 
	-- If it is LTE, yield until it is GT, fire error event and return (false). Otherwise, set _t to current time
	if os.clock() - self._t <= self._settings.TIME_VARIANCE and self._humanoid then
		task.wait(os.clock() - self._t) -- why is it yielding and then returning like cmon what is the point of yielding if it's not gonna do anything after
		declareError(self, self.ErrorType.LimitReached)
		return false
	elseif self._humanoid then
		self._t = os.clock()
	end

	--Compute path with PFS
	local pathComputed, _ = pcall(function()
		self._path:ComputeAsync(self._agent.PrimaryPart.Position, (typeof(target) == "Vector3" and target) or target.Position)
	end)

	--Make sure path computation is successful
	-- if computing the path errored (pcall not successful) or PFS is incapable of making a path 
	-- or the number of waypoints in the computed path is less than 2 or the agent is a humanoid and is falling
	-- then destroy visuals, fire error event with ComputationError and return false
	if not pathComputed 
		or self._path.Status == Enum.PathStatus.NoPath
		or #self._path:GetWaypoints() < 2
		or (self._humanoid and self._humanoid:GetState() == Enum.HumanoidStateType.Freefall) then
		
		self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints) -- remove visuals
		task.wait()
		declareError(self, self.ErrorType.ComputationError) -- fire error event with ComputationError
		
		return false
	end
	
	-- after this point, all is well with the generated PFS path
	
	
	--Set status to active (if agent is a humanoid); pathfinding starts
	self._status = (self._humanoid and Path.StatusType.Active) or Path.StatusType.Idle 
	self._target = target -- target field created on first Run call

	--Set network owner to server to prevent "hops"
	pcall(function()
		self._agent.PrimaryPart:SetNetworkOwner(nil)
	end)

	--Initialize waypoints
	self._waypoints = self._path:GetWaypoints() -- _waypoint field created on first Run call
	self._currentWaypoint = 2 -- _currentWaypoint field created on first Run call and set to 2 (cuz 1 is the waypoint at the agent's position so u wanna start moving to the next waypoint)

	--Refer to Settings.COMPARISON_CHECKS
	if self._humanoid then -- if agent humanoid then do the pos comparison to determine if the agent is stuck
		comparePosition(self)
	end

	--Visualize waypoints
	-- destroy any visual waypoints and remake them
	destroyVisualWaypoints(self._visualWaypoints)
	self._visualWaypoints = (self.Visualize and createVisualWaypoints(self._waypoints)) -- _visualWaypoints field created here on first Run call (only if self.Visualize is truthy)
	-- self.Visualize is nil unless u make it in ur script

	--Create a new move connection if it doesn't exist already
	-- _moveConnection stored the MoveToFinished connection object
	-- MoveToFinished event fires if the humanoid reached its destination and gives true otherwise if it hasn't and 8 seconds pass, it gives false
	self._moveConnection = self._humanoid and (self._moveConnection or self._humanoid.MoveToFinished:Connect(function(reached) -- changed ... to reached
		moveToFinished(self, reached)
	end)) -- _moveConnection is a field created on the first Run call. It only exists for humanoid agents
	

	--Begin pathfinding
	if self._humanoid then -- if agent is humanoid then make it walk to the currentWaypoint (the next waypoint) 
		self._humanoid:MoveTo(self._waypoints[self._currentWaypoint].Position)
	elseif #self._waypoints == 2 then -- if the number of waypoints is 2 then it technically almost reached the endPoint. If there's 2 waypoints then 1 is for the agent, the other is at the target
		self._target = nil  
		self._visualWaypoints = destroyVisualWaypoints(self._visualWaypoints)
		self._events.Reached:Fire(self._agent, self._waypoints[2]) -- reached event fired
	else -- if it's non humanoid and there are more than 2 waypoints then
		self._currentWaypoint = getNonHumanoidWaypoint(self) -- gets current waypoint (it will be >= 2)
		moveToFinished(self, true)
	end
	
	return true, self._waypoints -- i added a second return which is the waypoints
end

return Path
