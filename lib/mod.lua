local mod = require "core/mods"
local textentry = require "textentry" --require('textentry')
local filepath = "/home/we/dust/data/nb_midiconfig/"
nb_midiconfig = {} -- table containing settings         --  TODO LOCAL


local function read_confs()
    print("DEBUG read_confs called")
    -- local confs = {}
    if util.file_exists(filepath) then
        nb_midiconfig = {} -- wipe table

        local confs = util.scandir(filepath)

        -- for k, v in ipairs(confs) do
        for i = 1, #confs do
            local t = tab.load(filepath .. confs[i])
            table.insert(nb_midiconfig, t)
            print('table >> read: ' .. filepath .. confs[i])
        end

    end
end

-- todo needs to delete old files, too!
local function write_confs()
    local confs = {}

    if util.file_exists(filepath) == false then
        util.make_dir(filepath)
    end

    for k, v in ipairs(nb_midiconfig) do
        tab.save(v, filepath .. v.name .. ".conf")
        print("table >> write: " .. filepath .. v.name .. ".conf")
    end

end

if note_players == nil then
    note_players = {}
end


local function add_player()

end

-- add_player()

function pre_init()
    add_player()
end

mod.hook.register("script_pre_init", "midiconfig pre init", pre_init)


-- system mod menu for creating configuration
local m = {}

local interaction = "l1"
local config_name = "" -- "replace me by pressing K3"

local selected_row_l1 = 1
local selected_row_l2 = 1
local editing_config

function m.key(n, z)
    if n == 2 and z == 1 then
        if interaction == "l1" then
            mod.menu.exit()
        elseif interaction == "l2" then
            interaction = "l1"
            -- print("DEBUG backing out from L2 to L1")
            mod.menu.redraw()
        end
    elseif n == 3 and z == 1 then
        print("key 3 pressed")
        if interaction == "l1" then
            if selected_row_l1 == #nb_midiconfig + 1 then
                -- print("DEBUG k3 pressed to enter menu create new config")

                interaction = "textentry"

                local function check(txt)
                    if string.len(txt) > 10 then
                        return "too long"
                    else
                        return ("remaining: "..10 - string.len(txt))
                    end
                end

                local function callback_1(txt)
                    if txt or "" ~= "" and check(txt) ~= "too long" then

                        local available = true

                        for k, v in ipairs(nb_midiconfig) do
                            if v.name == txt then
                                available = false
                            break
                            end
                        end

                        if available then
                            table.insert(nb_midiconfig, {name = txt})

                            config_name = txt
                            print("DEBUG textentry entered config_name = " .. config_name)

                            write_confs()
                        else
                            print("DEBUG duplicate textentry = " .. config_name)
                        end

                    else
                        print("DEBUG exited textentry without saving config_name")
                    end

                    interaction = "l1"
                    mod.menu.redraw()
                end


                -- local default_text = config_name ~= "replace me by pressing K3" and config_name or ""
                local default_text = config_name ~= "" and config_name or ""

                textentry.enter(callback_1, default_text, "enter 10 chars or less", check)

            else
                editing_config = nb_midiconfig[selected_row_l1].name
                interaction = "l2"
                mod.menu.redraw()
                print("DEBUG editing config: ", nb_midiconfig[selected_row_l1].name)

            end

        elseif interaction == "textentry" then
            print("RETURNING to menu with config_name text: ", config_name)
        end
    end
end

function m.enc(n, d)
    if n == 2 then
        selected_row_l1 = util.clamp(selected_row_l1 + d, 1, #nb_midiconfig + 1)
    -- elseif n == 3 then
    end
    mod.menu.redraw()
end

function m.redraw()
    screen.clear()

    if interaction == "l1" then
    
        if selected_row_l1 == 1 then -- header
            screen.level(4)
            screen.move(0, 10)
            screen.text("MODS / NB_MIDICONFIG")
        end

        for i = 1, 6 do -- draw up to 6 rows for configs (including NEW CONFIG)
            local string

            if (i > 3 - selected_row_l1) and (i < (#nb_midiconfig + 1) - selected_row_l1 + 4) then
                screen.level( i == 3 and 15 or 4)

                if nb_midiconfig[i + selected_row_l1 - 3] then
                    string = nb_midiconfig[i + selected_row_l1 - 3].name .. " >"
                else
                    string = "NEW CONFIG"
                end

                screen.move(0 , 10 * i)
                screen.text(string)
                screen.move(127, 10 * i)
            end

        end
    
    else --if interaction == "L2" then
        if selected_row_l2 == 1 then -- header
            screen.level(4)
            screen.move(0, 10)
            screen.text(editing_config)
        end
    end


    screen.update()
end

function m.init()
    interaction = "l1"
    read_confs()
end -- on menu entry

function m.deinit()
    -- write_confs()
    -- might reset row, etc??
end -- on menu exit

mod.menu.register(mod.this_name, m)