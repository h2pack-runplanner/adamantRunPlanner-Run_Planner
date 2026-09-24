-- Opt-in native cap probe. Run with HADES2_SCRIPTS_PATH=/path/to/Scripts
-- lua tests/probes/fangs_native.lua. It loads no proprietary source into this repo.
-- luacheck: globals CurrentRun DebugPrint ApplyEliteAttribute
package.path = "./src/?.lua;./src/?/init.lua;./tests/?.lua;./tests/?/init.lua;./?.lua;./?/init.lua;" .. package.path

local probe = require("tests.probes.generated_encounter_native")
local scriptsPath = probe.scriptsPath()
local saved = { CurrentRun = CurrentRun, DebugPrint = DebugPrint }
CurrentRun = { CurrentRoom = {} }
DebugPrint = function() end
probe.loadEliteApplicationBody(scriptsPath)

local function enemy()
    return {
        Name = "Probe", EliteAttributes = {},
        EliteAttributeData = { Fog = { MaxPerRoom = 1 } },
    }
end
local first, second = enemy(), enemy()
ApplyEliteAttribute(first, "Fog")
ApplyEliteAttribute(second, "Fog")
assert(#first.EliteAttributes == 1, "first Fog must apply")
assert(#second.EliteAttributes == 0, "native MaxPerRoom must block second Fog")
CurrentRun, DebugPrint = saved.CurrentRun, saved.DebugPrint
print("Fangs native cap probe passed")
