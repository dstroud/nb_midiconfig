-- TODO
-- test launching nb host with no configs
-- test with disconnected MIDI port

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
            local t = {name = configname, values = tab.load(filepath .. filename)}
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
        if v.values then -- prob not needed
            tab.save(v.values, filepath .. v.name .. ".conf")
            print("table >> write: " .. filepath .. v.name .. ".conf")
        end
    end

end


-- always-on `config` demi-params 
params_number = {
    {name = "port", type = {"range", 1, 16, 1}},
    {name = "channel", type = {"range", 1, 16, 1}},
    {name = "modulation cc", type = {"range", 0, 127, 1}},
    {name = "bend range", type = {"range", 1, 48, 12}},
}

-- option-style demi-params
params_option = {
    {name = "bank", type = {"option", "-", "msb", "lsb", "msb, lsb", "msb+lsb", "oberheim"}},
    {name = "program change", type = {"option", "-", "1-128", "0-99"}},
}


-- on/off params that aren't CC
params_bool = {
    -- "param 1" -- can be used to enable custom params (need to process in add_params)
}

prm = {} -- todo local, numerically indexed list of DIY-param names
prm_type = {} -- range, bool for prm table
prm_lookup = {} -- todo local, look up prm name and return index in prm/prm_type

for i = 1, #params_number do
    prm[i] = params_number[i].name
    prm_type[i] = params_number[i].type
    prm_lookup[params_number[i].name] = i
end

for i = 1, #params_option do
    table.insert(prm, params_option[i].name)
    table.insert(prm_type, params_option[i].type)
    prm_lookup[params_option[i].name] = #prm
end

for i = 1, #params_bool do
    table.insert(prm, params_bool[i])
    table.insert(prm_type, {"bool"})
    prm_lookup[params_bool[i]] = #prm
end

for i = 0, 127 do
    table.insert(prm, "cc " .. i)
    table.insert(prm_type, {"bool"})
    prm_lookup["cc " .. i] = #prm
end


if note_players == nil then
    note_players = {}
end


local function add_midiconfig_players()
    read_confs()
    for _, v in ipairs(nb_midiconfig) do
        local id = "nb_" .. v.name
        local player = {}

        function player:add_params()
                        
            -- todo not sure where to house this fn
            -- returns 7-bit LSB and MSB for a given number
            local function get_bytes(number)
                local lsb = number % 128 -- Extract the lower 7 bits
                local msb = math.floor(number / 128) -- Shift right by 7 bits
                
                return lsb, msb
            end

            params:add_group(id, v.name, 7)

            local function incr_group()
                params:lookup_param(id).n = params:lookup_param(id).n + 1
            end

            params:add_separator(id .. "_controls", "controls")



            -- helper function to configure cc with range of 0-127
            -- `name` is optional and will replace "cc 1" etc...
            -- if `after` is true, the off/"-" value will be at the end of range rather than beginning
            local function add_cc(cc, name, after)
                local param_id = id .. "_cc_" .. cc
                if params.lookup[param_id] == nil then -- check because we have overlap with bank select vs cc0/32
                    incr_group()
                    params:add_number(param_id, name or ("cc " .. cc), (after and 0 or -1), (after and 128 or 127), (after and 128 or -1),
                        function(param)
                            local val = param:get()
                            return(val == (after and 128 or -1) and "-" or val)
                        end
                    )

                    -- params:set_save(id .. "_cc_" .. cc, false)

                    params:set_action(param_id,
                        function(val)
                            if val ~= (after and 128 or -1) then
                                self.conn:cc(cc, val, self:ch())

                                if cc == 0 then
                                    print("DEBUG sending cc 0: ", val)    
                                end

                            end
                        end
                    )
                end
            end
            

            if v.values["bank"] ~= "-" then -- bank select options
                local type = v.values["bank"]

                if type == "msb" then
                    add_cc(0, "bank select")
                elseif type == "lsb" then
                    add_cc(32, "bank select")
                elseif type == "msb, lsb" then
                    add_cc(0, "bank msb")
                    add_cc(32, "bank lsb")
                elseif type == "msb+lsb" then -- used one param to set both msb and lsb
                    incr_group()
                    params:add_number(id .. "_bank_msb+lsb", "bank select", -1, 16383, -1,
                        function(param)
                            local val = param:get()
                            return(val == -1 and "-" or val)
                        end
                    )
                    params:set_action(id .. "_bank_msb+lsb",
                        function(val)
                            if val ~= -1 then
                                local msb, lsb = get_bytes(val)
                                self.conn:cc(0, msb, self:ch())
                                self.conn:cc(32, lsb, self:ch())
                            end
                        end
                    )
                elseif type == "oberheim" then -- custom handling of Oberheim's non-standard bank change for the M-1000/6
                    incr_group()
                    params:add_number(id .. "_bank_ob", "bank select", -1, 9, -1,
                        function(param)
                            local val = param:get()
                            return(val == -1 and "-" or val)
                        end
                    )
                    params:set_action(id .. "_bank_ob",
                        function(val)
                            if val ~= -1 then
                                self.conn:cc(31, 127, self:ch()) -- tells pc to operate on bank
                                self.conn:program_change(val, self:ch()) -- pc used for bank
                                self.conn:cc(31, 0, self:ch()) -- tells pc to operate as usual
                            end
                        end
                    )
                end
            end


            if v.values["program change"] ~= "-" then -- program change options
                local type = v.values["program change"]

                if type == "1-128" then -- todo need to verify that this makes sense, might need a 0-127 option?
                    incr_group()
                    params:add_number(id .. "_program_change", "program change", 0, 128, 0,
                        function(param)
                            local val = param:get()
                            return(val == 0 and "-" or val)
                        end
                    )
        
                    params:set_action(id .. "_program_change",
                        function(val)
                            if val ~= 0 then
                                self.conn:program_change(val - 1, self:ch())
                            end
                        end
                    )
                elseif type == "0-99" then
                    incr_group()
                    params:add_number(id .. "_program_change", "program change", -1, 99, -1,
                        function(param)
                            local val = param:get()
                            return(val == -1 and "-" or val)
                        end
                    )
                    params:set_action(id .. "_program_change",
                        function(val)
                            if val ~= -1 then
                                self.conn:program_change(val, self:ch())
                            end
                        end
                    )
                end
            end

            
            local cc_start = #params_number + #params_bool + 1 -- add standard CCs
            for i = cc_start, cc_start + 127 do
                if v.values[prm[i]] then
                    add_cc(i - cc_start)
                end
            end


            -- TODO "send all" to blast all CCs out. They are only set on pset load if index changes, which is not reliable if patch has changed, etc.
            -- TODO "save with PSET" toggle? Maybe not since it doesn't affect bang
            -- TODO "defaults" option to set all to default (to restore "-" without changing cc)
            
            -- `all notes off` sent to all channels of connected ports
            params:add_binary(id .. "_panic", "panic!", "trigger", 0)
            params:set_action(id .. "_panic",
                function()
                    for i, vport in ipairs(midi.vports) do
                        if vport.connected then
                            for ch = 1, 16 do
                                vport:cc(123, 1, ch)
                            end
                        end
                    end
                end
            )


        -- mandatory `config` params:
        params:add_separator(id .. "_config", "config")

        -- todo consider all notes off on prev port/ch when changing (hanging notes)
        params:add_number(id .. "_port", "port", 1, 16, v.values.port)
        params:set_action(id .. "_port",
            function(val)
                local conn = midi.connect(val)
                self.conn = conn
            end
        )

        params:add_number(id .. "_ch", "channel", 1, 16, v.values.channel)

        params:add_number(id .. "_modulation_cc", "modulation cc", 1, 127, v.values["modulation cc"] or 1) -- assignable for nb's modulate fn

        params:add_number(id .. "_bend_range", "bend range", 1, 48, v.values["bend range"] or 12)

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


-- system mod menu for managing device configs
local m = {}

local interaction = "l1"
local config_name = "" -- "replace me by pressing K3"

local selected_row_l1 = 1
local selected_row_l2 = 1
local editing_config_name

editing_config_tab = {} -- TODO LOCAL
    
local function init_editing_config_tab() -- init working table with all current prms
    -- print("DEBUG init_editing_config_tab called")
    editing_config_tab = {}
    for i = 1, #prm_type do
        if prm_type[i][1] == "bool" then
            editing_config_tab[i] = false
        elseif prm_type[i][1] == "option" then
            editing_config_tab[i] = "-"
        else
            editing_config_tab[i] = prm_type[i][4] -- default value for ranged demi-param
        end
    end
end


-- loads saved demi-params from the id-indexed nb_midiconfig/.confs to the row-indexed editing_config_tab for screen display/editing
local function load_editing_config_tab()
    init_editing_config_tab() -- init first in case there are new prms (default to false)
    for _, c in pairs(nb_midiconfig) do
        if c.name == editing_config_name then
            if c.values then
                for k, v in pairs(c.values) do
                    if v then -- technically not needed since we can re-set `false` states
                        editing_config_tab[prm_lookup[k]] = v
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
        elseif interaction == "l2" then -- back out from editing config and save values to nb_midiconfig
        
            nb_midiconfig[selected_row_l1].values = {}

            for i = 1, #prm do
                nb_midiconfig[selected_row_l1].values[prm[i]] = editing_config_tab[i] -- indexed by prm name/id
            end

            print("DEBUG write_confs called when backing out of l2") -- todo check if write happens when leaving menu with E1
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
                            selected_row_l2 = 1
                            interaction = "l2"
                            editing_config_name = txt
                            init_editing_config_tab()
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
                selected_row_l2 = 1
                interaction = "l2"
                load_editing_config_tab()
                mod.menu.redraw()
                print("DEBUG editing config: ", nb_midiconfig[selected_row_l1].name)
            end

        elseif interaction == "l2" then
            if prm_type[selected_row_l2][1] == "bool" then
                editing_config_tab[selected_row_l2] =  not editing_config_tab[selected_row_l2] -- flip enabled state
                mod.menu.redraw()
            end
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
        -- todo use to enable/disable bools, too
        if interaction == "l2" then
            if prm_type[selected_row_l2][1] == "bool" then
                if d > 0 then
                    editing_config_tab[selected_row_l2] = true
                else
                    editing_config_tab[selected_row_l2] = false
                end
            elseif prm_type[selected_row_l2][1] == "option" then
                local val = editing_config_tab[selected_row_l2]
                local max = #prm_type[selected_row_l2]
                local idx = tab.key(prm_type[selected_row_l2], val) -- get index from string

                editing_config_tab[selected_row_l2] = prm_type[selected_row_l2][util.clamp(idx + d, 2, max)] -- get new string from delta'd index
            else -- range
                local min = prm_type[selected_row_l2][2]
                local max = prm_type[selected_row_l2][3]
                editing_config_tab[selected_row_l2] = util.clamp(editing_config_tab[selected_row_l2] + d, min, max)
            end
            mod.menu.redraw()
        end
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

        for i = 1, 6 do -- draw up to 6 rows for prm (demi-params) table
            if (i > 3 - selected_row_l2) and (i < (#prm) - selected_row_l2 + 4) then
                local idx = i + selected_row_l2 - 3
                screen.level( i == 3 and 15 or 4)
                screen.move(0, 10 * i)
                screen.text(prm[idx]) --string

                if prm_type[idx][1] == "bool" then
                    if editing_config_tab[idx] then
                        screen.rect(124, 10 * i - 4, 3, 3)
                        screen.fill()
                    end
                else -- `number` and `option` demi-param
                    screen.move(127, 10 * i)
                    screen.text_right(editing_config_tab[idx])
                end
            end

        end
    end


    screen.update()
end

function m.init()
    init_editing_config_tab()
    interaction = "l1"
    read_confs()
end -- on menu entry

function m.deinit()
    -- might reset row, etc??
end -- on menu exit

mod.menu.register(mod.this_name, m)