# nb_midiconfig
Mod to configure Nota Bene voices for individual MIDI devices

This mod runs alongside the regular NB MIDI players and allows you to create configurations for MIDI devices (synths, DAW plugins, MIDI-controllable effects, etc...). These configs contain some basic information about your device: what port and channel is the device on, how does it handle bank/program changes, what CC values does it respond to.

To use a config, select its name from your script's selector just like you would for an engine-based NB voice. It will automatically fetch the latest port, channel, etc... from the config.

Norns can now control your device through the system parameters menu or via scripts that support manipulating NB params (e.g. Dreamsequence with its automation "events").

Parameters are also saved along with your script presets, so the next time you open a preset, it can automatically send the right bank/program/CC values for that song.


### Installation
Install via maiden: `;install https://github.com/dstroud/nb_midiconfig`

Enable the mod via SYSTEM>>MODS>>NB_MIDICONF>>E3 and restart


### Editing configs

Create or edit configs via SYSTEM>>MODS>>NB_MIDICONF>>K3>>NEW CONFIG.

Some options, like port, channel, modulation cc, and bend range, are required. If you have a change to your setup at a later date, just edit the config here and the changes will be applied retroactively to script presets using this config.

Other options like Bank Select, Program Change, and CC values, are optional. Use E3/K3 to configure.

  > **_TIP:_** Enable the `always show` option if you want this config's params to always appear when an NB script is running, even if it's not selected as a player/voice. This is useful for effects or synths that you might not be sending *notes* to from NB, but might still want to control via params.

To save your config, exit using K2. Re-launch your script if a config has been edited while the script was running.
 
  > **_TIP:_** After a config has been saved, you may want to change the default descriptions of the CC numbers to better describe your device's capabilities. This can be done via Maiden>>(files icon)>>data>>nb_midiconfig and editing the values in the *your_config*.name file (be sure to save and re-launch your script).


### Using configs
Select your config name from your NB-capable script's player/voice param and you will see the config's name in the system parameters menu.

The parameters are broken out into two groups:

#### Controls 
Bank Select, Program Change, and CC values. Note that the values default to a state of "-" which means no value will be sent or saved with your script presets. Changing the param will send the corresponding MIDI message. Several options are available:
- `send all` sends all of the control values at once- useful if a receiving device was not turned on in time or a patch was changed and you want to reset it.
- `reset all` defaults all of the controls to the "-" state, but will not send any MIDI to the device. This can be useful if you want to keep the device's sound as-is but don't want to save the settings with your script preset.
- `panic!` sends CC 123 (all notes off) to all channels of all ports.

#### Config overrides
Optional parameters that override whatever was set at the config level and can be saved with script presets. They do not change the config, so are mostly useful for one-off scenarios.
- `port` any system MIDI ports, including disconnected ones
- `channel` port channels 1-16
- `modulation cc` CC to use for NB's modulate CC function, if supported by a script
- `bend range` pitch bend range, if supported by a script


### Addendum, contributing
For script authors: this mod surfaces all configured param ids using the `params` table in the NB player object's describe() function.

I'm not personally motivated to accomodate every weird implentation of MIDI that has shown up over the last 40+ years, but if there is something that a bunch of folks would benefit from, let me know. Otherwise, PRs are certainly welcome.