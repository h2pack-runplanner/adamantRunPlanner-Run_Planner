-- luacheck: globals TestHostBootstrap
local lu = require("luaunit")

TestHostBootstrap = {}

function TestHostBootstrap.testInspectorAttachesStandaloneGuiBeforeActivation()
    local registered = {}
    local bridge = { renderWindow = function() end, addMenuBar = function() end }
    local module = {
        data = { define = function() end },
        status = { define = function() end },
        ui = { tab = function() end, quickContent = function() end },
        fallbackUi = { attachGuiOnce = function(register) register(bridge) end },
        activate = function()
            lu.assertEquals(registered.window, bridge.renderWindow)
            lu.assertEquals(registered.menu, bridge.addMenuBar)
            registered.activated = true
        end,
    }
    local runtime = { attach = function(target) lu.assertIs(target, module) end }
    local imports = {
        ["mods/host/data.lua"] = { buildStorage = function() return {} end, buildStatus = function() return {} end },
        ["mods/runtime/composition.lua"] = { bind = function() return runtime end },
        ["mods/host/status_ui.lua"] = { bind = function() return { drawTab = function() end, drawQuickContent = function() end } end },
    }
    local environment = setmetatable({
        _PLUGIN = { guid = "adamantRunPlanner-Run_Planner", config_mod_folder_path = "unused" },
        import_as_fallback = function() end,
        import = function(path) return assert(imports[path], path) end,
        rom = {
            game = {},
            gui = {
                add_imgui = function(callback) registered.window = callback end,
                add_to_menu_bar = function(callback) registered.menu = callback end,
            },
            mods = {
                ["SGG_Modding-ENVY"] = { auto = function() end },
                ["SGG_Modding-ModUtil"] = { once_loaded = { game = function(callback) callback() end } },
                ["SGG_Modding-ReLoad"] = { auto_single = function()
                    return { load = function(_, initialize) initialize() end }
                end },
                ["adamant-ModpackLib"] = { createModule = function() return module end },
            },
        },
    }, { __index = _G })
    assert(loadfile("src/main.lua", "t", environment))()
    lu.assertTrue(registered.activated)
end
