--!strict
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UPDATE_TICK = 8 -- Server heartbeat frequency for zone checks.
local ZONE_TAG = "Zone"
local ZONE_ID_ATTRIBUTE = "ZoneId" -- String Attribute on each tagged BasePart

export type ZoneId = string

export type Zone = {
	Id: ZoneId,
	Parts: { BasePart },
	Tags: { string },
}

export type ZoneEventCallback = (player: Player, zoneId: ZoneId) -> ()

-- Internal representation of a cached part bound.
export type ZonePartBounds = {
	Part: BasePart,
	HalfSize: Vector3,
}

-- Per-player zone membership.
export type PlayerZoneState = {
	[ZoneId]: boolean,
}

--[[
    ZoneService
    @author DistractedGames
    @version 0.2.0

    This module provides deterministic enter/exit detection for gameplay-relevant
    spatial zones using oriented bounding box (OBB) math against tagged or explicitly
    registered BaseParts. All zone evaluation is performed on the server, ensuring
    security, consistency, and exploit resistance.

    This service is intended for zones that affect gameplay state, such as:
    - Safe zones / PvP restrictions
    - Combat arenas
    - Quest regions
    - Environmental rule changes
]]
local ZoneService = {}
ZoneService.__index = ZoneService

local zones: { [ZoneId]: Zone } = {}
local zoneBounds: { [ZoneId]: { ZonePartBounds } } = {}
local playerStates: { [Player]: PlayerZoneState } = {}

local enterCallbacks: { [ZoneId]: { ZoneEventCallback } } = {}
local exitCallbacks: { [ZoneId]: { ZoneEventCallback } } = {}

-- Tracks parts discovered via CollectionService before full registration.
local pendingPartsByZone: { [ZoneId]: { BasePart } } = {}

--[[
    Utility function for point-in-oriented-bounding-box test.
]]
local function pointInPart(part: BasePart, halfSize: Vector3, point: Vector3): boolean
	local localPoint = part.CFrame:PointToObjectSpace(point)

	return math.abs(localPoint.X) <= halfSize.X
		and math.abs(localPoint.Y) <= halfSize.Y
		and math.abs(localPoint.Z) <= halfSize.Z
end

local function ensurePlayerState(player: Player): PlayerZoneState
	local state = playerStates[player]
	if state == nil then
		state = {}
		playerStates[player] = state
	end
	return state
end

--[[
    Helper function to register a new zone or expand a registered zone's bounds
    with the given part when CollectionService picks it up.
]]
function ZoneService._onZonePartAdded(part: BasePart)
	local zoneId = part:GetAttribute(ZONE_ID_ATTRIBUTE)
	if typeof(zoneId) ~= "string" then
		return
	end

	pendingPartsByZone[zoneId] = pendingPartsByZone[zoneId] or {}
	table.insert(pendingPartsByZone[zoneId], part)

	if zones[zoneId] == nil then
		ZoneService.RegisterZone(zoneId, pendingPartsByZone[zoneId])
	else
		-- Extend existing zone.
		local boundsList = zoneBounds[zoneId]
		if boundsList then
			table.insert(boundsList, {
				Part = part,
				HalfSize = part.Size * 0.5,
			})
		end
	end
end

--[[
    Helper function to remove a given part from a zone's bounds when removed.
]]
function ZoneService._onZonePartremoved(part: BasePart)
	local zoneId = part:GetAttribute(ZONE_ID_ATTRIBUTE)
	if typeof(zoneId) ~= "string" then
		return
	end

	local boundsList = zoneBounds[zoneId]
	if boundsList == nil then
		return
	end

	-- Using last in, first out check.
	for i = #boundsList, 1, -1 do
		if boundsList[i].Part == part then
			table.remove(boundsList, i)
			break
		end
	end
end

--[[
    Automatically discovers and registers zones using CollectionService.

    Any BasePart tagged with ZONE_TAG and carrying a string Attribute named
    ZONE_ID_ATTRIBUTE will be grouped into a zone with that ID.

    This enables zero manual wiring: creators define zones entirely in Studio
    using tags and attributes, and the service handles registration, updates,
    and cleanup automatically.
]]
function ZoneService.EnableCollectionService()
	-- Initial Scan
	for _, instance in CollectionService:GetTagged(ZONE_TAG) do
		local part = instance
		if not (part and part:IsA("BasePart")) then
			continue
		end
		ZoneService._onZonePartAdded(part)
	end

	-- Dynamic Updates
	CollectionService:GetInstanceAddedSignal(ZONE_TAG):Connect(function(instance)
		local part = instance
		if not (part and part:IsA("BasePart")) then
			return
		end
		ZoneService._onZonePartAdded(part)
	end)

	CollectionService:GetInstanceRemovedSignal(ZONE_TAG):Connect(function(instance)
		local part = instance
		if not (part and part:IsA("BasePart")) then
			return
		end
		ZoneService._onZonePartremoved(part)
	end)
end

--[[
    Registeres a new zone with the service.

    Once registered, the zone will be evaluated automatically during the service's
    update loop, and enter/exit callbacks may be attached.

    Zones may be registered manually or automatically via CollectionService.

    @param zoneId A unique identifier for the zone.
    @param parts An array of BaseParts that define the zone's volume.
    @param tags Optional metadata tags associated with the zone.

    @error Throws if a zone with the same ID has already been registered.
]]
function ZoneService.RegisterZone(zoneId: ZoneId, parts: { BasePart }, tags: { string }?)
	assert(zones[zoneId] == nil, `Zone '{zoneId}' is already registered`)

	zones[zoneId] = {
		Id = zoneId,
		Parts = parts,
		Tags = tags or {},
	}

	local boundsList: { ZonePartBounds } = {}
	for _, part in parts do
		table.insert(boundsList, {
			Part = part,
			HalfSize = part.Size * 0.5,
		})
	end

	zoneBounds[zoneId] = boundsList
	enterCallbacks[zoneId] = {}
	exitCallbacks[zoneId] = {}
end

--[[
    Registers a callback to be invoked when a player enters the specified zone.

    @param zoneId The ID of a previously registered zone.
    @param callback A function invoked with (player, zoneId) on entry.
    
    @error Throws if the zone has not been registered.
]]
function ZoneService.OnZoneEntered(zoneId: ZoneId, callback: ZoneEventCallback)
	assert(enterCallbacks[zoneId] ~= nil, `Zone '{zoneId}' is not registered`)
	table.insert(enterCallbacks[zoneId], callback)
end

--[[
    Registers a callback to be invoked when a player exits the specified zone.

    @param zoneId The ID of a previously registered zone.
    @param callback A function invoked with (player, zoneId) on exit.
    
    @error Throws if the zone has not been registered.
]]
function ZoneService.OnZoneExited(zoneId: ZoneId, callback: ZoneEventCallback)
	assert(exitCallbacks[zoneId] ~= nil, `Zone '{zoneId}' is not registered`)
	table.insert(exitCallbacks[zoneId], callback)
end

--[[
    Checks whether a player is currently considered inside a given zone.

    This reflects the server's authoritative zone state and does not perform
    a real-time spatial query.

    @param player The Player to query.
    @param zoneId The ID of the zone to check.

    @return True if the player is currently inside the zone; false otherwise.
]]
function ZoneService.IsPlayerInZone(player: Player, zoneId: ZoneId): boolean
	local state = playerStates[player]
	if state == nil then
		return false
	end
	return state[zoneId] == true
end

-- Core update loop:
local accumulated = -(1 / UPDATE_TICK)

local function updateZones(deltaTime: number)
	accumulated += deltaTime
	if accumulated < (1 / UPDATE_TICK) then
		return
	end
	accumulated = 0

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") :: BasePart else nil
		if not root then
			continue
		end

		local position = root.Position
		local state = ensurePlayerState(player)

		for zoneId, boundsList in zoneBounds do
			local inside = false

			for _, bound in boundsList do
				if pointInPart(bound.Part, bound.HalfSize, position) then
					inside = true
					break
				end
			end

			local wasInside = state[zoneId] == true

			if inside and not wasInside then
				state[zoneId] = true
				for _, callback in enterCallbacks[zoneId] do
					callback(player, zoneId)
				end
			elseif not inside and wasInside then
				state[zoneId] = false
				for _, callback in exitCallbacks[zoneId] do
					callback(player, zoneId)
				end
			end
		end
	end
end

-- Cleanup
Players.PlayerRemoving:Connect(function(player: Player)
	playerStates[player] = nil
end)

RunService.Heartbeat:Connect(updateZones)

return ZoneService
