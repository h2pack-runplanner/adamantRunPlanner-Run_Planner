-- Pure checkpoint proof over the planner-published conformance facts. Native
-- observation is injected so this module owns comparison without owning hooks.
local proof = {}

local function equal(left, right)
    if type(left) ~= type(right) then return false end
    -- Native operand transforms such as (1 + bonus) - 1 introduce roundoff.
    -- Compare values without rounding either ledger; NaN/infinity fail here too.
    if type(left) == "number" then return math.abs(left - right) <= 1e-9 end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
    for key in pairs(right) do if left[key] == nil then return false end end
    return true
end

function proof.compare(checkpoint, expected, observed)
    if expected == nil or observed == nil or not equal(expected, observed) then
        return nil, {
            checkpoint = checkpoint,
            expected = expected,
            observed = observed,
        }
    end
    return true
end

local function keepsakeCheckpoint(value, requireActivation, expected)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = entry end
    -- Athena acquisition is proved by trait inventory, not keepsake-use bookkeeping.
    result.gorgon = nil
    result.figLeaf = nil
    if requireActivation then
        result.figLeaf = {
            activatedThisBiome = expected or
                (type(value.figLeaf) == "table" and value.figLeaf.activatedThisBiome == true),
        }
    end
    return result
end

function proof.compareKeepsakes(checkpoint, expected, observed, requireActivation)
    return proof.compare(checkpoint,
        keepsakeCheckpoint(expected, requireActivation, true),
        keepsakeCheckpoint(observed, requireActivation, false))
end

function proof.prove(occurrence, read)
    for _, fact in ipairs((occurrence.roomExitConformance or {}).facts or {}) do
        local expected = occurrence.conformanceExpected and occurrence.conformanceExpected[fact.kind]
        local observed = type(read) == "function" and read(fact.kind, expected) or nil
        local compare = proof.compare
        local requireActivation = false
        if fact.kind == "keepsakeEffects" then
            compare = proof.compareKeepsakes
            for _, phase in ipairs((occurrence.overview or {}).encounterPhases or {}) do
                requireActivation = requireActivation or phase.figLeafSkip == true
            end
        end
        local ok, mismatch = compare(
            "room-exit-conformance:" .. fact.kind,
            expected,
            observed,
            requireActivation
        )
        if not ok then return nil, mismatch end
    end
    return true
end

return proof
