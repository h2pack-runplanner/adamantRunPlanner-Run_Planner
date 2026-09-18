-- Manual only: lua tests/probes/test_boss_customization_native.lua /path/to/Scripts
-- Reads local game source without copying it into the module. It attests the
-- declared Chronos/Typhon pools and the exact native stage-transition order.
-- luacheck: globals TestBossCustomizationNative
local lu = require("luaunit")
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tests/?/init.lua;" .. package.path

local TestBossCustomizationNative = {}
_G.TestBossCustomizationNative = TestBossCustomizationNative

local function read(path)
    local file = assert(io.open(path, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end

local function scriptsPath()
    local value = arg[1] or os.getenv("HADES2_SCRIPTS_PATH")
    assert(type(value) == "string" and value ~= "", "supply HADES2_SCRIPTS_PATH or a Scripts directory")
    return value:gsub("/$", "")
end

local nativeScriptsPath = scriptsPath()
if arg[1] then table.remove(arg, 1) end -- The source directory is not a LuaUnit test selector.

local function position(source, text)
    return assert(source:find(text, 1, true), "native source is missing " .. text)
end

function TestBossCustomizationNative.testChronosActiveLateSummonSelectorsAndRivalSpawnerPool()
    local path = nativeScriptsPath
    local enemy = read(path .. "/EnemyData_Chronos.lua")
    local weapons = read(path .. "/WeaponData_Chronos.lua")
    position(enemy, 'FireWeapon = "ChronosDefense3"')
    position(enemy, 'FireWeapon = "ChronosDefense3_SuperElite"')
    position(weapons, 'PreAttackRandomDumbFireWeapon = { "ChronosEliteSpawn1", "ChronosEliteSpawn2", "ChronosEliteSpawn3" }')
    position(weapons, 'PreAttackRandomDumbFireWeapon = { "ChronosSuperEliteSpawn1", }')
    for _, nativeId in ipairs({
        "Screamer2_SuperElite", "Treant2_SuperElite", "Octofish_SuperElite", "Vampire_SuperElite",
        "Lamia_SuperElite", "ClockworkHeavyMelee_SuperElite", "SatyrRatCatcher_SuperElite",
    }) do position(weapons, '"' .. nativeId .. '"') end
end

function TestBossCustomizationNative.testTyphonEggPoolsAndRivalOverridePrecedeBossTransition()
    local path = nativeScriptsPath
    local typhon = read(path .. "/EnemyData_TyphonHead.lua")
    local ai = read(path .. "/EnemyAILogic.lua")
    local transition = read(path .. "/EncounterLogic.lua")
    position(typhon, 'FireRandomWeapon = { "TyphonHeadCastSummon01", "TyphonHeadCastSummon03", }')
    position(typhon, 'FireRandomWeapon = { "TyphonHeadCastSummonCaptain", }')
    position(typhon, 'FireRandomWeapon = { "TyphonHeadCastSummon02", "TyphonHeadCastSummon05", }')
    position(typhon, 'FireRandomWeapon = { "TyphonHeadCastSummonBoar", "TyphonHeadCastSummonDragon" }')
    local override = position(ai, "OverwriteTableKeys(aiStage, aiStage.EMStageDataOverrides)")
    local call = position(ai, "CallFunctionName( aiStage.TransitionFunction, enemy, CurrentRun, aiStage )")
    lu.assertTrue(override < call, "Rival stage overrides must reach BossStageTransition first")
    position(transition, "aiStage.FireWeapon = aiStage.FireWeapon or GetRandomValue(aiStage.FireRandomWeapon)")
end

os.exit(lu.LuaUnit.run())
