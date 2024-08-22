local mod = require "core/mods"
local textentry = require "textentry"
local filepath = "/home/we/dust/data/nb_midiconfig/"
nb_midiconfig = {} -- table containing settings         --  TODO LOCAL


local function read_confs()
    print("DEBUG read_confs called")
    if util.file_exists(filepath) then
        nb_midiconfig = {} -- wipe table

        local confs = util.scandir(filepath)

        for i = 1, #confs do
            local filename = confs[i]
            local configname = string.sub(filename, 1, string.len(filename) - 5)
            local t = {name = configname, enabled = tab.load(filepath .. filename)}
            nb_midiconfig[i] = t
            print('table >> read: ' .. filepath .. filename)
        end

    end
end

-- todo needs to delete old files, too!
local function write_confs()
    if util.file_exists(filepath) == false then
        util.make_dir(filepath)
    end

    for k, v in ipairs(nb_midiconfig) do
        if v.enabled then -- prob not needed
            tab.save(v.enabled, filepath .. v.name .. ".conf")
            print("table >> write: " .. filepath .. v.name .. ".conf")
        end
    end

end


prm = {} -- todo local, numerically indexed list of prm names
prm_lookup = {} -- todo local, look up prm name and return index
for i = 0, 127 do
    table.insert(prm, "cc " .. i)
    prm_lookup["cc " .. i] = i + 1
end


if note_players == nil then
    note_players = {}
end


local function add_midiconfig_players()
    read_confs()
    for i, v in ipairs(nb_midiconfig) do
        local id = "nb_" .. v.name
        local player = {}

        function player:add_params()

            local paramcount = 0 -- count of how many params have been enabled for this config
            for k, prm in pairs(v.enabled) do -- not sorted tho :/
                if prm then -- only create param if bool is true
                    paramcount = paramcount + 1
                end
            end
            -- print("DEBUG paramcount for " .. id .. ": " .. paramcount)

            params:add_group(id, v.name, paramcount + (paramcount > 0 and 1 or 0) + 7) -- TODO remove +2 once port/channel have been sorted

            -- active controller params:
            if paramcount > 0 then
                params:add_separator(id .. "_controls", "controls")
            end

            -- helper function to configure cc with range of 0-127
            -- `name` is optional and will replace "cc 1" etc...
            -- if `after` is true, the off/"-" value will be at the end of range rather than beginning
            local function add_cc(cc, name, after)
                params:add_number(id .. "_cc_" .. cc, name or ("cc " .. cc), (after and 0 or -1), (after and 128 or 127), (after and 128 or -1),
                    function(param)
                        local val = param:get()
                        return(val == (after and 128 or -1) and "-" or val)
                    end
                )
                params:set_action(id .. "_cc_" .. cc,
                    function(val)
                        if val ~= (after and 128 or -1) then
                            self.conn:cc(cc, val, self:ch())
                        end
                    end
                )
            end

            -- configure enabled MIDI CC params
            for i = 1, #prm do
                if v.enabled[prm[i]] then
                    add_cc(i - 1)
                end
            end


            -- keep this around as we may need to use some variant to iterate through non-cc prms
            -- for k, p in pairs(v.enabled) do -- not sorted tho :/
            --     if p then -- only create param if bool is true
            --         if string.sub(k, 1, 2) == "cc" then
            --             local cc_no = tonumber(string.sub(k, 4))
            --             add_cc(cc_no)
            --         end
            --     end
            -- end


            -- `all notes off` sent to all channels of connected ports
            params:add_binary(id .. "_panic", "panic!", "trigger", 0)
            params:set_action(id .. "_panic",
                function()
                    for i, v in ipairs(midi.vports) do
                        if v.connected then
                            for ch = 1, 16 do
                                v:cc(123, 1, ch)
                            end
                        end
                    end
                end
            )


        -- `config` params:
        params:add_separator(id .. "_config", "config")

        -- todo consider all notes off on prev port/ch when changing (hanging notes)
        params:add_number(id .. "_port", "port", 1, 16, 1)
        params:set_action(id .. "_port",
            function(val)
                local conn = midi.connect(val)
                self.conn = conn
            end
        )

        -- todo bank options, probably

        params:add_number(id .. "_ch", "channel", 1, 16, 1)

        params:add_number(id .. "_program_change", "program change", -1, 99, -1,
            function(param)
                local v = param:get()
                return(v == -1 and "-" or v)
            end
        )

        params:set_action(id .. "_program_change",
            function(val)
                if val ~= -1 then
                    self.conn:program_change(val, self:ch())
                end
            end
        )

        params:add_number(id .. "_modulation_cc", "modulation cc", 1, 127, 72) -- assignable for nb's modulate fn

        params:add_number(id .. "_bend_range", "bend range", 1, 48, 12)

        -- params:hide(id) -- TODO re-enable before deploy

        end -- of add_params


        function player:ch()
            return(params:get(id .. "_ch"))
        end

        function player:note_on(note, vel)
            self.conn:note_on(note, util.clamp(math.floor(127 * vel), 0, 127), self:ch())
        end

        function player:note_off(note)
            self.conn:note_off(note, 0, self:ch())
        end

        function player:active()
            -- params:show(id)          -- TODO re-enable before deploy
            -- _menu.rebuild_params()
        end
    
        function player:inactive()
            -- params:hide(id)            -- TODO re-enable before deploy
            -- _menu.rebuild_params()
        end
    
        function player:modulate(val)
            self.conn:cc(params:get(id .. "_modulation_cc"),
                util.clamp(math.floor(127 * val), 0, 127),
                self:ch())
        end
    
        function player:modulate_note(note, key, value)
            if key == "pressure" then
                self.conn:key_pressure(note, util.round(value * 127), 1)
            end
        end
    
        function player:pitch_bend(note, amount)
            local bend_range = params:get( id .. "bend_range")
            if amount < -bend_range then
                amount = -bend_range
            end
            if amount > bend_range then
                amount = bend_range
            end
            local normalized = amount / bend_range -- -1 to 1
            local send = util.round(((normalized + 1) / 2) * 16383)
            self.conn:pitchbend(send, self:ch())
        end
    
        function player:stop_all()
            if self and self.conn then -- won't run at init as add_params has yet to run
                self.conn:cc(123, 1, self:ch())
            end
        end
    
        function player:describe()
            local mod_d = "cc"
            if params.lookup[id .. "_modulation_cc"] ~= nil then
                mod_d = "cc " .. params:get(id .. "_modulation_cc")
            end
            return {
                name = v.name,
                supports_bend = true,
                supports_slew = false,
                note_mod_targets = { "pressure" },
                modulate_description = mod_d
            }
        end

        note_players[v.name] = player

    end
end


function pre_init()
    add_midiconfig_players()
end

mod.hook.register("script_pre_init", "midiconfig pre init", pre_init)


-- system mod menu for creating configuration
local m = {}

local interaction = "l1"
local config_name = "" -- "replace me by pressing K3"

local selected_row_l1 = 1
local selected_row_l2 = 1
local editing_config_name
editing_config_bools = {} -- TODO LOCAL-- use when editing prms as this is always up-to-date, unlike nb_midiconfig from .confs

local function init_editing_config_bools() -- init working table with all current prms
    editing_config_bools = {}
    for i = 1, #prm do
        editing_config_bools[i] = false -- prm[i] -- prm[i] will populate the prm id/name
    end
end
    

-- loads saved prms from nb_midiconfig to editing_config_bools for display and enable/disable
local function load_editing_config_bools() -- load the saved prms
    init_editing_config_bools() -- init first in case there are new prms (default to false)

    for _, c in pairs(nb_midiconfig) do
        if c.name == editing_config_name then
            if c.enabled then
                for k, v in pairs(c.enabled) do
                    if v then -- technically not needed since we can re-set `false` states
                        editing_config_bools[prm_lookup[k]] = v
                    end
                end
            end
            break
        end
    end
end


function m.key(n, z)
    if n == 2 and z == 1 then
        if interaction == "l1" then
            mod.menu.exit()
        elseif interaction == "l2" then -- back out from editing config and save enabled states to nb_midiconfig
        
            nb_midiconfig[selected_row_l1].enabled = {}

            for i = 1, #prm do
                nb_midiconfig[selected_row_l1].enabled[prm[i]] = editing_config_bools[i] -- indexed by prm name/id
            end


            print("DEBUG write_confs called when backing out of l2")
            write_confs()

            interaction = "l1"
            -- print("DEBUG backing out from L2 to L1")

            mod.menu.redraw()
        end
    elseif n == 3 and z == 1 then
        -- print("key 3 pressed")
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

                local function textentry_callback(txt)
                    if (txt or "") ~= "" and check(txt) ~= "too long" then

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
                            interaction = "l2"
                            editing_config_name = txt
                            mod.menu.redraw()
                        else
                            print("DEBUG duplicate textentry = " .. config_name)
                            interaction = "l1"
                            mod.menu.redraw()
                        end

                    else
                        print("DEBUG exited textentry without saving config_name")
                        interaction = "l1"
                        mod.menu.redraw()
                    end
                end

                local default_text = "" -- config_name ~= "" and config_name or ""
                textentry.enter(textentry_callback, default_text, "ENTER CONFIG/DEVICE NAME", check) -- todo adjust limit for DS

            else -- editing an existing config
                editing_config_name = nb_midiconfig[selected_row_l1].name
                interaction = "l2"
                load_editing_config_bools()
                mod.menu.redraw()
                print("DEBUG editing config: ", nb_midiconfig[selected_row_l1].name)
            end

        elseif interaction == "l2" then
            editing_config_bools[selected_row_l2] =  not editing_config_bools[selected_row_l2] -- flip enabled state
            mod.menu.redraw()
        elseif interaction == "textentry" then
            print("RETURNING to menu with config_name text: ", config_name)
        end
    end
end

function m.enc(n, d)
    if n == 2 then
        if interaction == "l1" then
            selected_row_l1 = util.clamp(selected_row_l1 + d, 1, #nb_midiconfig + 1)
        elseif interaction == "l2" then
            selected_row_l2 = util.clamp(selected_row_l2 + d, 1, #prm + 0) -- change 0 to append options
        end
    elseif n == 3 then
        -- todo use to enable/disable, etc...
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
            screen.text(editing_config_name)
        end

        for i = 1, 6 do -- draw up to 6 rows for prm (faux params) table
            -- local string

            if (i > 3 - selected_row_l2) and (i < (#prm + 0) - selected_row_l2 + 4) then -- change 0 to append options
                local idx = i + selected_row_l2 - 3
                screen.level( i == 3 and 15 or 4)
                screen.move(0, 10 * i)
                screen.text(prm[idx]) --string

                if editing_config_bools[idx] then
                    screen.rect(124, 10 * i - 4, 3, 3)
                    screen.fill()
                end
            end

        end
    end


    screen.update()
end

function m.init()
    init_editing_config_bools()
    interaction = "l1"
    read_confs()
end -- on menu entry

function m.deinit()
    -- might reset row, etc??
end -- on menu exit

mod.menu.register(mod.this_name, m)