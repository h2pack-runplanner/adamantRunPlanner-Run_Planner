-- Closed-shape primitives shared by the v10 fact-family decoders.
local json = type(import) == "function" and import("mods/protocol/json.lua") or require("mods.protocol.json")

local primitives = { MAX_ITEMS = 256, MAX_STRING = 512, MAX_OWNER_STRING = 2048, json = json }

function primitives.fail(message) return nil, message end
function primitives.obj(value, label)
    if not json.isObject(value) then return primitives.fail(label .. " must be an object") end
    return value
end
function primitives.arr(value, label, max)
    if not json.isArray(value) or #value > (max or primitives.MAX_ITEMS) then
        return primitives.fail(label .. " must be a bounded array")
    end
    return value
end
function primitives.str(value, label, max)
    if type(value) ~= "string" or value == "" or #value > (max or primitives.MAX_STRING) then
        return primitives.fail(label .. " must be a bounded non-empty string")
    end
    return value
end
function primitives.num(value, label, min)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge
        or (min and value < min) then return primitives.fail(label .. " must be finite") end
    return value
end
function primitives.int(value, label, min)
    if not primitives.num(value, label, min) or value ~= math.floor(value) then
        return primitives.fail(label .. " must be an integer")
    end
    return value
end
function primitives.bool(value, label)
    if type(value) ~= "boolean" then return primitives.fail(label .. " must be a boolean") end
    return true
end
function primitives.exact(value, required, optional, label)
    local record, errorMessage = primitives.obj(value, label)
    if not record then return nil, errorMessage end
    local allowed = {}
    for _, key in ipairs(required) do
        allowed[key] = true
        if value[key] == nil then return primitives.fail(label .. " is missing " .. key) end
    end
    for _, key in ipairs(optional or {}) do allowed[key] = true end
    for key in pairs(value) do
        if not allowed[key] then return primitives.fail(label .. " has unknown field " .. tostring(key)) end
    end
    return value
end
function primitives.one(value, allowed, label)
    if not allowed[value] then return primitives.fail(label .. " is unsupported") end
    return value
end
function primitives.strings(value, label, max)
    local items, errorMessage = primitives.arr(value, label, max)
    if not items then return nil, errorMessage end
    for index, item in ipairs(items) do
        if not primitives.str(item, label .. "[" .. index .. "]") then return nil, "invalid string" end
    end
    return items
end
function primitives.recordNumbers(value, label)
    local record, errorMessage = primitives.obj(value, label)
    if not record then return nil, errorMessage end
    for key, item in pairs(record) do
        if not primitives.str(key, label .. " key") or not primitives.num(item, label .. "." .. key) then
            return nil, label .. " has invalid number"
        end
    end
    return record
end
function primitives.roomRef(value, label)
    local record = primitives.exact(value, { "id", "biomeKey", "gameName" }, {}, label)
    if not record
        or not primitives.str(record.id, label, 256)
        or not primitives.str(record.biomeKey, label)
        or not primitives.str(record.gameName, label) then
        return primitives.fail(label .. " malformed room reference")
    end
    return record
end
local function utf8Hex(value)
    local bytes = {}
    local index = 1
    while index <= #value do
        local first = value:byte(index)
        local length, code, minimum
        if first < 128 then length, code, minimum = 1, first, 0
        elseif first >= 194 and first <= 223 then length, code, minimum = 2, first - 192, 128
        elseif first >= 224 and first <= 239 then length, code, minimum = 3, first - 224, 2048
        elseif first >= 240 and first <= 244 then length, code, minimum = 4, first - 240, 65536
        else error("fingerprint strings must contain Unicode scalar values") end
        for offset = 1, length - 1 do
            local byte = value:byte(index + offset)
            assert(byte and byte >= 128 and byte <= 191,
                "fingerprint strings must contain Unicode scalar values")
            code = code * 64 + byte - 128
        end
        assert(code >= minimum and code <= 1114111 and (code < 55296 or code > 57343),
            "fingerprint strings must contain Unicode scalar values")
        for offset = 0, length - 1 do
            bytes[#bytes + 1] = string.format("%02x", value:byte(index + offset))
        end
        index = index + length
    end
    return table.concat(bytes)
end
local function numberHex(value)
    assert(primitives.num(value, "fingerprint number"))
    if value == 0 then return "0000000000000000" end
    local sign = value < 0 and 2147483648 or 0
    local magnitude = math.abs(value)
    local mantissa, exponent
    if magnitude < 2 ^ -1022 then
        exponent, mantissa = 0, magnitude / (2 ^ -1074)
    else
        local fraction, power = math.frexp(magnitude)
        exponent, mantissa = power + 1022, (fraction * 2 - 1) * (2 ^ 52)
    end
    local high = sign + exponent * 1048576 + math.floor(mantissa / 4294967296)
    return string.format("%08x%08x", high, mantissa % 4294967296)
end
local function byteLess(left, right)
    for index = 1, math.min(#left, #right) do
        if left:byte(index) ~= right:byte(index) then return left:byte(index) < right:byte(index) end
    end
    return #left < #right
end
local function canonical(value)
    if json.isNull(value) then return "z" end
    if type(value) == "string" then return "s" .. utf8Hex(value) .. ";" end
    if type(value) == "number" then return "n" .. numberHex(value) .. ";" end
    if type(value) == "boolean" then return value and "t" or "f" end
    if json.isArray(value) then
        local parts = {}; for index, item in ipairs(value) do parts[index] = canonical(item) end
        return "[" .. table.concat(parts) .. "]"
    end
    assert(type(value) == "table", "unsupported fingerprint value")
    local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end; table.sort(keys, byteLess)
    for index, key in ipairs(keys) do keys[index] = canonical(key) .. canonical(value[key]) end
    return "{" .. table.concat(keys) .. "}"
end
primitives.canonicalFingerprintInput = canonical
function primitives.fingerprint(value)
    local text, hash = canonical(value), 2166136261
    for index = 1, #text do
        hash = bit32.bxor(hash, text:byte(index))
        local low, high = hash % 65536, math.floor(hash / 65536)
        hash = (low * 403 + ((low * 256 + high * 403) % 65536) * 65536) % 4294967296
    end
    return string.format("%08x", hash)
end
return primitives
