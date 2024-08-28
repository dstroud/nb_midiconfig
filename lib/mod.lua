local mod = require "core/mods"
local textentry = require "textentry"
local filepath = "/home/we/dust/data/nb_midiconfig/"
local nb_midiconfig = {}
local cc_names = {}
local m = {}
local interaction = "l1"
local selected_row_l1 = 1
local selected_row_l2 = 1
local editing_config_name
local editing_config_tab = {}

local function read_files()
    if util.file_exists(filepath) then
        local files = util.scandir(filepath)
        local confs = {}
        local names = {}
        for i = 1, #files do
            local filename = files[i]
            local type = string.sub(filename, string.len(filename) - 4)
            if type == ".conf" then
                table.insert(confs, filename)
            elseif type == ".name" then
                table.insert(names, filename)
            end
        end

        nb_midiconfig = {}
        for i = 1, #confs do
            local filename = confs[i]
            local configname = string.sub(filename, 1, string.len(filename) - 5)
            local t = {name = configname, values = tab.load(filepath .. filename)}
            nb_midiconfig[i] = t
            print("table >> read: " .. filepath .. filename)
        end

        cc_names = {defaults = tab.load("/home/we/dust/code/nb_midiconfig/lib/defaults.name")}
        for i = 1, #names do
            local filename = names[i]
            local configname = string.sub(filename, 1, string.len(filename) - 5)
            cc_names[configname] = tab.load(filepath .. filename)
            print("table >> read: " .. filepath .. filename)
        end

        for i = 1, #nb_midiconfig do -- return the new row_number in case it has changed due to filesystem sort
            if nb_midiconfig[i].name == editing_config_name then
                selected_row_l1 = i
                break
            end
        end
    end
end

local function copy_file(source, destination)
    -- Open the source file in read mode
    local src = io.open(source, "rb")
    if not src then
        return false, "Failed to open source file"
    end

    -- Open the destination file in write mode
    local dst = io.open(destination, "wb")
    if not dst then
        src:close()
        return false, "Failed to open destination file"
    end

    -- Copy the content
    local content = src:read("*all")
    dst:write(content)

    -- Close the files
    src:close()
    dst:close()

    return true
end

local function write_files()
    if util.file_exists(filepath) == false then
        util.make_dir(filepath)
    end

    for _, v in ipairs(nb_midiconfig) do
        if v.values then
            tab.save(v.values, filepath .. v.name .. ".conf")
            print("table >> write: " .. filepath .. v.name .. ".conf")
            
            if not cc_names[v.name] then -- if .name file doesn't exist, copy from lib so user can (optionally) edit
                copy_file(_path.code .. "nb_midiconfig/lib/defaults.name", filepath .. v.name .. ".name")
                print("table >> write: " .. filepath .. v.name .. ".name")
            end
        end
    end
end

local function delete_files(conf_id)
    for i = 1, #nb_midiconfig do 
        if nb_midiconfig[i].name == conf_id then
            table.remove(nb_midiconfig, i)      -- delete entry from nb_midiconfig
            break
        end
    end

    local filetype = {".conf", ".name"}
    for i = 1, 2 do
        local file = filepath .. conf_id .. filetype[i]
        if util.file_exists(file) then
            os.remove(file)                         -- delete .conf and .name files
            print("table >> delete: " .. file)
        end
    end
end

-- on/off params that aren't CC
local params_bool = {
    "always show"
}

-- required demi-params for config
local params_number = {
    {name = "port", type = {"number", 1, 16, 1}},
    {name = "channel", type = {"number", 1, 16, 1}},
    {name = "modulation cc", type = {"number", 0, 127, 1}},
    {name = "bend range", type = {"number", 1, 48, 12}},
}

-- option-style demi-params
local params_option = {
    {name = "bank select", type = {"option", "-", "msb", "lsb", "msb, lsb", "msb+lsb", "oberheim"}}, -- todo send pgm, too
    {name = "program change", type = {"option", "-", "0-99", "0-127", "1-128"}},
}

local prm = {"DELETE CONFIG"} -- numerically indexed list of demi-param names, also contains meta command(s) for L2 menu
local prm_type = {{"meta"}} -- number, option, bool corresponding to prm table
local prm_lookup = {["DELETE CONFIG"] = 1} -- look up prm name and return index in prm/prm_type

for i = 1, #params_bool do
    table.insert(prm, params_bool[i])
    table.insert(prm_type, {"bool"})
    prm_lookup[params_bool[i]] = #prm
end

for i = 1, #params_number do
    table.insert(prm, params_number[i].name)
    table.insert(prm_type, params_number[i].type)
    prm_lookup[params_number[i].name] = #prm
end

for i = 1, #params_option do
    table.insert(prm, params_option[i].name)
    table.insert(prm_type, params_option[i].type)
    prm_lookup[params_option[i].name] = #prm
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
    read_files()
    for _, v in ipairs(nb_midiconfig) do
        local id = "nb_" .. v.name
        local player = {}
        local paramlist = {}

        -- these variables default to using the .conf settings (so changes to configuration are retroactively applied)
        -- however, they can be overridden by using the corresponding params in edit>>parameters
        local ch
        local modulation_cc
        local bend_range

        function player:add_params()
            local names = cc_names[v.name] or cc_names["defaults"] or {}

            -------------------------------------------------------------------------
            -- helper functions
            -------------------------------------------------------------------------
            local function get_bytes(number) -- returns 7-bit LSB and MSB for a given number
                local lsb = number % 128 -- extract the lower 7 bits
                local msb = math.floor(number / 128) -- shift right by 7 bits
                return lsb, msb
            end

            local function incr_group() -- increments group as params are added
                params:lookup_param(id).n = params:lookup_param(id).n + 1
            end

            local function reg_param(param_id) -- inserts params into player:describe().params for scripts and `send/reset all`
                table.insert(paramlist, param_id)
            end

            -- configure cc with range of 0-127
            -- `name` is optional and will replace "cc 1" etc...
            -- if `after` is true, the off/"-" value will be at the end of range rather than beginning
            local function add_cc(cc, name, after)
                local param_id = id .. "_cc_" .. cc
                if params.lookup[param_id] == nil then -- check because we have overlap with bank select vs cc0/32
                    incr_group()
                    reg_param(param_id)

                    params:add_number(param_id, name or ("cc " .. cc), (after and 0 or -1), (after and 128 or 127), (after and 128 or -1),
                        function(param)
                            local val = param:get()
                            return(val == (after and 128 or -1) and "-" or val)
                        end
                    )
                    params:set_action(param_id,
                        function(val)
                            if val ~= (after and 128 or -1) then
                                self.conn:cc(cc, val, ch)
                            end
                        end
                    )
                end
            end


            -------------------------------------------------------------------------
            -- performance/preset-specific stuff like CC, bank select, program change
            -------------------------------------------------------------------------
            params:add_group(id, v.name, 9)
            
            params:add_separator(id .. "_controls", "controls")

            if v.values["bank select"] ~= "-" then -- bank select options
                local type = v.values["bank select"]

                if type == "msb" then
                    add_cc(0, "bank select")
                elseif type == "lsb" then
                    add_cc(32, "bank select")
                elseif type == "msb, lsb" then
                    add_cc(0, "bank msb")
                    add_cc(32, "bank lsb")
                elseif type == "msb+lsb" then -- used one param to set both msb and lsb
                    local param_id = id .. "_bank_msb+lsb"
                    incr_group()
                    reg_param(param_id)
                    params:add_number(param_id, "bank select", 0, 16384, 0,
                        function(param)
                            local val = param:get()
                            return(val == 0 and "-" or val)
                        end
                    )
                    params:set_action(param_id,
                        function(val)
                            if val ~= 0 then
                                local lsb, msb = get_bytes(val - 1)
                                self.conn:cc(0, msb, ch)
                                self.conn:cc(32, lsb, ch)
                            end
                        end
                    )
                elseif type == "oberheim" then -- custom handling of Oberheim's non-standard bank change for the M-1000/6
                local param_id = id .. "_bank_ob"
                    incr_group()
                    reg_param(param_id)
                    params:add_number(id .. "_bank_ob", "bank select", -1, 9, -1,
                        function(param)
                            local val = param:get()
                            return(val == -1 and "-" or val)
                        end
                    )
                    params:set_action(id .. "_bank_ob",
                        function(val)
                            if val ~= -1 then
                                self.conn:cc(31, 127, ch) -- tells pc to operate on bank
                                self.conn:program_change(val, ch) -- pc used for bank
                                self.conn:cc(31, 0, ch) -- tells pc to operate as usual
                            end
                        end
                    )
                end
            end

            if v.values["program change"] ~= "-" then -- program change options
                local type = v.values["program change"]

                if type == "0-127" then
                    local param_id = id .. "_program_change_0_127"

                    incr_group()
                    reg_param(param_id)
                    params:add_number(param_id, "program change", -1, 127, -1,
                        function(param)
                            local val = param:get()
                            return(val == -1 and "-" or val)
                        end
                    )
                    params:set_action(param_id,
                        function(val)
                            if val ~= -1 then
                                self.conn:program_change(val, ch)
                            end
                        end
                    )

                elseif type == "1-128" then
                    local param_id = id .. "_program_change_1_128"

                    incr_group()
                    reg_param(param_id)
                    params:add_number(param_id, "program change", 0, 128, 0,
                        function(param)
                            local val = param:get()
                            return(val == 0 and "-" or val)
                        end
                    )
                    params:set_action(param_id,
                        function(val)
                            if val ~= 0 then
                                self.conn:program_change(val - 1, ch)
                            end
                        end
                    )

                elseif type == "0-99" then
                    local param_id = id .. "_program_change_0_99"

                    incr_group()
                    reg_param(param_id)
                    params:add_number(param_id, "program change", -1, 99, -1,
                        function(param)
                            local val = param:get()
                            return(val == -1 and "-" or val)
                        end
                    )
                    params:set_action(param_id,
                        function(val)
                            if val ~= -1 then
                                self.conn:program_change(val, ch)
                            end
                        end
                    )
                end
            end
            
            local cc_start = #prm - 128 + 1 -- add standard CCs
            for i = cc_start, cc_start + 127 do
                local cc_no = prm[i]
                if v.values[cc_no] then
                    add_cc(i - cc_start, cc_no .. " " .. names[prm[i]])
                end
            end
            
            -- resets all "controls" to defaults (handy if you don't want to save state with .pset)
            params:add_binary(id .. "_send_all", "send all", "trigger", 0)
            params:set_action(id .. "_send_all",
                function()
                    for _, p in pairs(player:describe().params) do
                        params:lookup_param(p):bang()
                    end
                end
            )
            
            -- resets all "controls" to defaults (handy if you don't want to save state with .pset)
            params:add_binary(id .. "_reset", "reset all", "trigger", 0)
            params:set_action(id .. "_reset",
                function()
                    for _, p in pairs(player:describe().params) do
                        params:set(p, params:lookup_param(p).default)
                    end
                end
            )

            -- `all notes off` sent to *all* channels of *all* connected ports
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

            -- optional params for ad-hoc overriding of config defaults
            -- saved with .pset so this can be used to lock in values even if config changes
            params:add_separator(id .. "_config_overrides", "config overrides")

            params:add_number(id .. "_port", "port", 0, 16, 0,
                function(param)
                    local val = param:get()
                    return(val == 0 and "-" or val)
                end
            )
            params:set_action(id .. "_port",
                function(val)
                    local conn = midi.connect((val == 0) and v.values["port"] or val)
                    self.conn = conn
                end
            )

            params:add_number(id .. "_ch", "channel", 0, 16, 0,
                function(param)
                    local val = param:get()
                    return(val == 0 and "-" or val)
                end
            )
            params:set_action(id .. "_ch",
                function (val)
                    ch = (val == 0) and v.values["channel"] or val
                end
            )

            params:add_number(id .. "_modulation_cc", "modulation cc", 0, 127, 0,
                function(param)
                    local val = param:get()
                    return(val == 0 and "-" or val)
                end
            )
            params:set_action(id .. "_modulation_cc",
                function (val)
                    modulation_cc = (val == 0) and v.values["modulation cc"] or val
                end
            )

            params:add_number(id .. "_bend_range", "bend range", 0, 48, 0,
                function(param)
                    local val = param:get()
                    return(val == 0 and "-" or val)
                end
            )
            params:set_action(id .. "_bend_range",
                function (val)
                    bend_range = (val == 0) and v.values["bend range"] or val
                end
            )

            if not v.values["always show"] then
                params:hide(id)
            end
        end

        function player:note_on(note, vel)
            self.conn:note_on(note, util.clamp(math.floor(127 * vel), 0, 127), ch)
        end

        function player:note_off(note)
            self.conn:note_off(note, 0, ch)
        end

        function player:active()
            if not v.values["always show"] then
                params:show(id)
                _menu.rebuild_params()
            end
        end
    
        function player:inactive()
            if not v.values["always show"] then
                params:hide(id)
                _menu.rebuild_params()
            end
        end
    
        function player:modulate(val)
            self.conn:cc(params:get(id .. "_modulation_cc"), util.clamp(math.floor(127 * val), 0, 127), ch)
        end
    
        function player:modulate_note(note, key, value)
            if key == "pressure" then
                self.conn:key_pressure(note, util.round(value * 127), 1)
            end
        end
    
        function player:pitch_bend(note, amount)
            if amount < -bend_range then
                amount = -bend_range
            end
            if amount > bend_range then
                amount = bend_range
            end
            local normalized = amount / bend_range -- -1 to 1
            local send = util.round(((normalized + 1) / 2) * 16383)
            self.conn:pitchbend(send, ch)
        end
    
        function player:stop_all()
            if self and self.conn then -- block running at init as add_params has yet to run so there is no conn
                self.conn:cc(123, 1, ch)
            end
        end
    
        function player:describe()
            return {
                name = v.name,
                supports_bend = true,
                supports_slew = false,
                note_mod_targets = { "pressure" },
                modulate_description = "cc " .. modulation_cc,
                params = paramlist or {},
            }
        end

        note_players[v.name] = player

    end
end

function pre_init()
    add_midiconfig_players()
end

mod.hook.register("script_pre_init", "midiconfig pre init", pre_init)

local function init_editing_config_tab() -- init working table with all current prms
    editing_config_tab = {}
    for i = 1, #prm_type do
        if prm_type[i][1] == "bool" then
            editing_config_tab[i] = false
        elseif prm_type[i][1] == "option" then
            editing_config_tab[i] = "-"
        elseif prm_type[i][1] == "number" then
            editing_config_tab[i] = prm_type[i][4] -- default value for number demi-param
        elseif prm_type[i][1] == "meta" then
            editing_config_tab[i] = false
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
                    if v then
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
            write_files()
            read_files() -- bit of a hack to sort configs
            interaction = "l1"
            mod.menu.redraw()
        end
    elseif n == 3 and z == 1 then
        if interaction == "l1" then
            if selected_row_l1 == #nb_midiconfig + 1 then
                interaction = "textentry"

                local function check(txt)
                    if screen.text_extents(txt) > 59 then -- *my* mod, *my* rules LOL
                        return "too long!"
                    else
                        return ""
                    end
                end

                local function textentry_callback(txt)
                    if (txt or "") ~= "" and check(txt) ~= "too long!" then

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
                            write_files()
                            selected_row_l2 = 1
                            interaction = "l2"
                            editing_config_name = txt
                            init_editing_config_tab()
                            mod.menu.redraw()
                        else -- duplicate name is ignored
                            interaction = "l1"
                            mod.menu.redraw()
                        end

                    else -- exited textentry without saving
                        interaction = "l1"
                        mod.menu.redraw()
                    end
                end

                local default_text = ""
                textentry.enter(textentry_callback, default_text, "ENTER CONFIG NAME", check)

            else -- editing an existing config
                editing_config_name = nb_midiconfig[selected_row_l1].name
                read_files()
                selected_row_l2 = 1
                interaction = "l2"
                load_editing_config_tab()
                mod.menu.redraw()
            end

        elseif interaction == "l2" then
            if prm_type[selected_row_l2][1] == "bool" then
                editing_config_tab[selected_row_l2] =  not editing_config_tab[selected_row_l2] -- flip enabled state
                mod.menu.redraw()
            elseif prm_type[selected_row_l2][1] == "meta" then -- currently just `DELETE CONFIG`
                delete_files(editing_config_name)
                selected_row_l1 = 1
                interaction = "l1"
                mod.menu.redraw()
            end
        end
    end
end

function m.enc(n, d)
    -- n == 1 isn't detectable here as it's used to nav between system menus. Handle with m.deinit() instead.
    if n == 2 then
        if interaction == "l1" then
            selected_row_l1 = util.clamp(selected_row_l1 + d, 1, #nb_midiconfig + 1)
        elseif interaction == "l2" then
            selected_row_l2 = util.clamp(selected_row_l2 + d, 1, #prm)
        end
    elseif n == 3 then
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
            elseif prm_type[selected_row_l2][1] == "number" then
                local min = prm_type[selected_row_l2][2]
                local max = prm_type[selected_row_l2][3]
                editing_config_tab[selected_row_l2] = util.clamp(editing_config_tab[selected_row_l2] + d, min, max)
            -- (E3 won't delete config... seems too easy to do accidentally)
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
                
                if prm_type[idx][1] == "bool" then
                    if cc_names[editing_config_name] then
                        screen.text(prm[idx] .. " " .. (cc_names[editing_config_name][prm[idx]] or ""))
                    else
                        screen.text(prm[idx] .. " " .. (cc_names["defaults"][prm[idx]] or ""))
                    end

                    if editing_config_tab[idx] then
                        screen.rect(124, 10 * i - 4, 3, 3)
                        screen.fill()
                    end
                elseif prm_type[idx][1] ~= "meta" then -- `number` and `option` demi-param
                    screen.text(prm[idx])
                    screen.move(127, 10 * i)
                    screen.text_right(editing_config_tab[idx])
                else -- meta
                    screen.text(prm[idx])
                end

            end
        end
    end
    screen.update()
end

function m.init()
    if util.file_exists(filepath) == false then
        util.make_dir(filepath)
    end
    init_editing_config_tab()
    interaction = "l1"
    selected_row_l1 = 1
    selected_row_l2 = 1
    read_files()
end -- on menu entry

function m.deinit()
    if interaction == "l2" then -- if user navigates out of l2 menu using E1 (undetectable by m.enc), save editing config
        nb_midiconfig[selected_row_l1].values = {}
        for i = 1, #prm do
            nb_midiconfig[selected_row_l1].values[prm[i]] = editing_config_tab[i] -- indexed by prm name/id
        end
        write_files()
    end
end -- on menu exit

mod.menu.register(mod.this_name, m)