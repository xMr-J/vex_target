-- ============================================================================
-- VEX TARGET — server/main.lua
--
-- Server-side sanity layer for client-reported target selections.
--
-- Threat model this file exists for: vex_target's raycast, registry
-- resolution, and condition gating all run entirely on the client
-- (client/core.lua, client/raycast.lua, client/watchdog.lua). None of that
-- is a trust boundary — a modified client can call VexTarget.DispatchSelection
-- directly, or simply fire the `vex_target:server:submitSelection` net event
-- by hand, with an arbitrary netId/hitCoords/optionId/metadata combination
-- and no real shape test ever having run. This file is what stands between
-- "the client claims a selection happened" and "a downstream resource
-- actually acts on it."
--
-- This handler fires unconditionally on every selection the client makes,
-- independent of Config.CallbackBridge.Mode (client-side, and only governs
-- how the local Lua onSelect gets invoked). Anything with a real server-side
-- consequence — currency, items, world-state changes — should be driven off
-- Config.Server.ValidatedEvent here, never off the client-local onSelect
-- alone.
--
-- Downstream consumption pattern (illustrative, not part of this file):
--
--   AddEventHandler(Config.Server.ValidatedEvent, function(selection)
--       -- selection.source, selection.optionId, selection.sourceType,
--       -- selection.sourceKey, selection.netId, selection.entity,
--       -- selection.hitCoords, selection.metadata are all validated/typed
--       -- by the time this fires.
--       if selection.optionId == 'sleep' then ... end
--   end)
-- ============================================================================

local Server = Config.Server

-- selectionMemory[playerSrc] = { [selectionId] = expiresAtMs }
-- Bounds replay: the same selectionId cannot be accepted twice from the same
-- player while it's still remembered.
local selectionMemory = {}

-- lastAcceptedAt[playerSrc] = GetGameTimer() of last ACCEPTED selection.
-- Server-enforced pacing — never trust the client's own
-- Config.Behaviour.SelectionDebounceMs, that's UX only.
local lastAcceptedAt = {}

local function now()
    return GetGameTimer()
end

local function securityLog(format, ...)
    -- Rejections are a security signal, not a debug convenience — always
    -- printed regardless of Config.Debug.
    print(('[vex_target:SECURITY] %s'):format(format:format(...)))
end

local function debugLog(format, ...)
    if not Config.Debug then
        return
    end

    print(('[vex_target:server] %s'):format(format:format(...)))
end

-- ============================================================================
-- Player bookkeeping
-- ============================================================================

local function forgetPlayer(playerSrc)
    selectionMemory[playerSrc] = nil
    lastAcceptedAt[playerSrc] = nil
end

AddEventHandler('playerDropped', function()
    forgetPlayer(source)
end)

-- Periodic sweep so a long-lived server doesn't accumulate expired
-- selectionId entries for players who never disconnect cleanly.
CreateThread(function()
    while true do
        Citizen.Wait(60000)

        local currentTime = now()

        for playerSrc, ids in pairs(selectionMemory) do
            for selectionId, expiresAt in pairs(ids) do
                if currentTime >= expiresAt then
                    ids[selectionId] = nil
                end
            end

            if next(ids) == nil then
                selectionMemory[playerSrc] = nil
            end
        end
    end
end)

-- ============================================================================
-- Rejection / acceptance signalling
-- ============================================================================

local function rejectSelection(playerSrc, payload, reason)
    securityLog(
        'rejected selection from player %s (reason=%s, selectionId=%s, optionId=%s, sourceType=%s, netId=%s)',
        tostring(playerSrc),
        tostring(reason),
        tostring(payload and payload.selectionId),
        tostring(payload and payload.optionId),
        tostring(payload and payload.sourceType),
        tostring(payload and payload.netId)
    )

    -- Deliberately re-emit only scalar/identifying fields, not the raw
    -- (potentially oversized or hostile) metadata table — the rejected event
    -- is for moderation/audit hooking, not for replaying the attacker's
    -- payload verbatim.
    TriggerEvent(Server.RejectedEvent, {
        source = playerSrc,
        reason = reason,
        selectionId = payload and payload.selectionId or nil,
        optionId = payload and payload.optionId or nil,
        sourceType = payload and payload.sourceType or nil,
        netId = payload and payload.netId or nil
    })
end

-- ============================================================================
-- Field-level validation
-- ============================================================================

local function isFiniteNumber(value)
    return type(value) == 'number'
        and value == value                 -- rejects NaN
        and value ~= math.huge
        and value ~= -math.huge
end

local function normalizeHitCoords(raw)
    if raw == nil then
        return nil, true    -- absent is allowed at this layer; caller decides if required
    end

    if type(raw) ~= 'table' then
        return nil, false
    end

    if not isFiniteNumber(raw.x) or not isFiniteNumber(raw.y) or not isFiniteNumber(raw.z) then
        return nil, false
    end

    return vector3(raw.x, raw.y, raw.z), true
end

local function sanitizeMetadata(value, depth)
    local limits = Server.Metadata

    if value == nil then
        return nil
    end

    depth = depth or 0

    if depth > limits.MaxDepth then
        return nil
    end

    local valueType = type(value)

    if valueType == 'string' then
        if #value > limits.MaxStringLength then
            return value:sub(1, limits.MaxStringLength)
        end

        return value
    end

    if valueType == 'number' then
        if not isFiniteNumber(value) then
            return 0
        end

        return value
    end

    if valueType == 'boolean' then
        return value
    end

    if valueType == 'vector2' or valueType == 'vector3' or valueType == 'vector4' then
        return value
    end

    if valueType == 'table' then
        local result = {}
        local keyCount = 0

        for key, nested in pairs(value) do
            keyCount = keyCount + 1

            if keyCount > limits.MaxKeys then
                break
            end

            local keyType = type(key)

            if keyType == 'string' or keyType == 'number' then
                result[key] = sanitizeMetadata(nested, depth + 1)
            end
            -- non string/number keys silently dropped rather than rejecting
            -- the whole payload — metadata is caller convenience data, not
            -- a security-relevant field in its own right.
        end

        return result
    end

    -- functions, userdata, threads: unsupported/dangerous, stripped entirely.
    return nil
end

-- ============================================================================
-- Player position resolution
-- ============================================================================
--
-- vex_core's real export name/signature is unconfirmed (same open item every
-- other vex_ blueprint in this project flags for vex_core/vex_callback).
-- Resolved defensively: try the configured export, fall back to the native
-- replicated ped position if it's missing/errors. This never "fails open" —
-- if neither source produces a position, the caller treats position as
-- unresolved and rejects the selection rather than skipping the distance
-- check.
-- ============================================================================

local function resolvePlayerPosition(playerSrc)
    local core = Server.Core

    local success, result = pcall(function()
        return exports[core.Resource][core.PositionExport](playerSrc)
    end)

    if success and result then
        if type(result) == 'vector3' then
            return result
        end

        if type(result) == 'table'
            and isFiniteNumber(result.x)
            and isFiniteNumber(result.y)
            and isFiniteNumber(result.z)
        then
            return vector3(result.x, result.y, result.z)
        end
    end

    debugLog(
        'vex_core position export unavailable/invalid for player %s (%s), falling back to native ped coords',
        tostring(playerSrc),
        tostring(result)
    )

    local ped = GetPlayerPed(playerSrc)

    if not ped or ped == 0 or not DoesEntityExist(ped) then
        return nil
    end

    local okCoords, coords = pcall(GetEntityCoords, ped)

    if not okCoords or type(coords) ~= 'vector3' then
        return nil
    end

    return coords
end

local function distanceBetween(a, b)
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = a.z - b.z

    return math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
end

-- ============================================================================
-- Entity resolution (networked sourceTypes only)
-- ============================================================================
--
-- For Peds/Vehicles resolved by net ID client-side, the server independently
-- re-derives the entity from the network ID and confirms it actually exists
-- and is of the claimed entity type. This is strictly stronger than trusting
-- the client's hitCoords: DoesEntityExist/GetEntityType/GetEntityCoords here
-- are the server's own replicated truth, not client-reported values.
--
-- Global static Models (and vehicle_class catch-alls without a concrete
-- netId) have no server-side entity to resolve at all — a "campfire" model
-- exists at dozens of world positions, so the only available check for that
-- branch is the distance cross-verification against the claimed hitCoords.
-- ============================================================================

local EXPECTED_ENTITY_TYPE = {
    ped_netid = 1,
    vehicle_netid = 2
}

local function resolveNetworkedEntity(sourceType, netId)
    if type(netId) ~= 'number' or netId <= 0 then
        return nil, 'invalid_netid'
    end

    local entity = NetworkGetEntityFromNetworkId(netId)

    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil, 'entity_not_found'
    end

    local expectedType = EXPECTED_ENTITY_TYPE[sourceType]

    if expectedType and GetEntityType(entity) ~= expectedType then
        return nil, 'entity_type_mismatch'
    end

    return entity
end

-- ============================================================================
-- Main handler
-- ============================================================================

RegisterNetEvent('vex_target:server:submitSelection')
AddEventHandler('vex_target:server:submitSelection', function(rawPayload)
    -- Capture immediately: `source` is only valid synchronously at the top
    -- of the handler, before any yield (pcall to an external export below
    -- does not reassign it, but capturing up front removes any doubt).
    local playerSrc = source

    if type(rawPayload) ~= 'table' then
        rejectSelection(playerSrc, nil, 'malformed_payload')
        return
    end

    -- Player must still be a real, currently-connected session.
    if GetPlayerName(playerSrc) == nil then
        return
    end

    -- ---- Server-enforced pacing (cheap check first, before any heavier work)
    local currentTime = now()
    local lastAccepted = lastAcceptedAt[playerSrc]

    if lastAccepted and (currentTime - lastAccepted) < Server.MinIntervalMs then
        rejectSelection(playerSrc, rawPayload, 'rate_limited')
        return
    end

    -- ---- Envelope type/shape validation
    local selectionId = rawPayload.selectionId
    local sourceType = rawPayload.sourceType
    local optionId = rawPayload.optionId
    local netId = rawPayload.netId

    if type(selectionId) ~= 'string' or selectionId == '' or #selectionId > 128 then
        rejectSelection(playerSrc, rawPayload, 'invalid_selection_id')
        return
    end

    if type(optionId) ~= 'string' or optionId == '' or #optionId > 128 then
        rejectSelection(playerSrc, rawPayload, 'invalid_option_id')
        return
    end

    if type(sourceType) ~= 'string' or not Server.ValidSourceTypes[sourceType] then
        rejectSelection(playerSrc, rawPayload, 'invalid_source_type')
        return
    end

    if netId ~= nil and (type(netId) ~= 'number' or netId < 0) then
        rejectSelection(playerSrc, rawPayload, 'invalid_netid')
        return
    end

    local hitCoords, hitCoordsShapeOk = normalizeHitCoords(rawPayload.hitCoords)

    if not hitCoordsShapeOk then
        rejectSelection(playerSrc, rawPayload, 'malformed_hit_coords')
        return
    end

    -- ---- Replay protection
    local playerSelections = selectionMemory[playerSrc]

    if playerSelections and playerSelections[selectionId] then
        rejectSelection(playerSrc, rawPayload, 'replayed_selection_id')
        return
    end

    -- ---- Entity / network verification
    local isNetworked = Server.NetworkedSourceTypes[sourceType] == true
    local resolvedEntity = 0

    if isNetworked then
        local entity, entityError = resolveNetworkedEntity(sourceType, netId)

        if not entity then
            rejectSelection(playerSrc, rawPayload, entityError)
            return
        end

        resolvedEntity = entity
    elseif hitCoords == nil then
        -- Global static Models/vehicle-class matches have no entity to
        -- resolve — hitCoords is the ONLY thing the distance check below can
        -- run against, so it is mandatory for this branch.
        rejectSelection(playerSrc, rawPayload, 'missing_hit_coords_for_static_target')
        return
    end

    -- ---- Distance / teleport-click verification
    local playerPosition = resolvePlayerPosition(playerSrc)

    if not playerPosition then
        -- Fail closed: no authoritative position means the check cannot run,
        -- and an unverifiable selection is not an accepted one.
        rejectSelection(playerSrc, rawPayload, 'position_unresolvable')
        return
    end

    local allowedDistance = math.min(
        Config.MaxTargetDistance + Server.DistancePadding,
        Server.MaxAllowedDistance
    )

    local referencePoint

    if isNetworked then
        -- Prefer the server's own replicated entity position over the
        -- client-reported hitCoords — this is the stronger of the two
        -- available checks for a concrete, resolvable entity.
        local okCoords, entityCoords = pcall(GetEntityCoords, resolvedEntity)

        if not okCoords or type(entityCoords) ~= 'vector3' then
            rejectSelection(playerSrc, rawPayload, 'entity_position_unresolvable')
            return
        end

        referencePoint = entityCoords
    else
        referencePoint = hitCoords
    end

    local distance = distanceBetween(playerPosition, referencePoint)

    if distance > allowedDistance then
        rejectSelection(playerSrc, rawPayload, 'out_of_range')
        return
    end

    -- ---- Metadata sanitisation
    if rawPayload.metadata ~= nil and type(rawPayload.metadata) ~= 'table' then
        rejectSelection(playerSrc, rawPayload, 'invalid_metadata_type')
        return
    end

    local sanitizedMetadata = sanitizeMetadata(rawPayload.metadata)

    -- ---- sourceKey: pass through only as a plain scalar
    local sourceKey = rawPayload.sourceKey

    if sourceKey ~= nil and type(sourceKey) ~= 'number' and type(sourceKey) ~= 'string' then
        sourceKey = nil
    end

    -- ---- Accept
    selectionMemory[playerSrc] = selectionMemory[playerSrc] or {}
    selectionMemory[playerSrc][selectionId] = currentTime + Server.SelectionIdMemoryMs
    lastAcceptedAt[playerSrc] = currentTime

    local validated = {
        source = playerSrc,
        selectionId = selectionId,
        optionId = optionId,
        sourceType = sourceType,
        sourceKey = sourceKey,
        netId = netId or 0,
        entity = resolvedEntity,
        hitCoords = hitCoords,
        distance = distance,
        metadata = sanitizedMetadata,
        validatedAt = currentTime
    }

    debugLog(
        'validated selection %s from player %s (option=%s, sourceType=%s, distance=%.2f)',
        selectionId,
        tostring(playerSrc),
        optionId,
        sourceType,
        distance
    )

    TriggerEvent(Server.ValidatedEvent, validated)
end)
