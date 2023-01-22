--[[
    One Track Per Audio OBS Studio LUA Script.

    Version: 0.0.1 beta.

    With this script you can forget about mixing different audio channels.
    Up to 6 audio sources the script will try to maintain in different tracks.

    You can find more at: https://github.com/srg91/obs-plugins.
]]--

---@diagnostic disable: lowercase-global

local S = require("obslua")
local bit = require("bit")

local SETTINGS = nil

function script_description()
    return [[
        <h2>One Track Per Audio</h2>
        <p>With this script you can forget about mixing different audio channels.</p>
        <p>Up to 6 audio sources the script will try to maintain in different tracks.</p>
        <p>More at <a href="https://github.com/srg91/obs-plugins">github.com/srg91/obs-plugins</a>.</p>
    ]]
end

local Log = {
    _level = S.LOG_INFO,
    _is_script_log_enabled = false,
}

local Script = {
    _callbacks = {},
}

local Mixer = {
    _state = nil,
    _sources = nil,
}

local Utils = {

}

---Called by the OBS Studio at application startup or reload script.
---@param settings userdata settings associated with the script.
function script_load(settings)
    SETTINGS = settings

    Log.set_level(S.obs_data_get_int(settings, "log-level"))
    Log.enable_script_log(S.obs_data_get_bool(settings, "script-log-enabled"))

    Script.initialize()
end

---Set current logging level (from S.LOG_ERROR up to S.LOG_DEBUG).
---@param level integer
Log.set_level = function(level)
    Log._level = level
end

---Also log to `Script log` in the application.
---@param enabled boolean
Log.enable_script_log = function(enabled)
    Log._is_script_log_enabled = enabled
end

---Initialize the global mixer and create all necessary handlers (create/show/hide/etc).
Script.initialize = function()
    Log.info("Start script initiliaztion.")

    Mixer.initialize()

    Script._attach_source_create_handler()
    Script._attach_handlers_to_exist_sources()

    Log.info("Finish initiliaztion.")
end

---@param message string
Log.info = function(message)
    Log.log(S.LOG_INFO, message)
end

---@param level integer
---@param message string
Log.log = function(level, message)
    if level > Log._level then return end

    local level_as_text = Log._level_to_text(level)
    message = string.format("[ %s ] %s", level_as_text, message)

    if Log._is_script_log_enabled then
        S.script_log(level, message)
    else
        message = "[ one-track-per-audio-obs-plugin ] " .. message
        S.blog(level, message)
    end
end

---@param level integer
---@return string
Log._level_to_text = function(level)
    local levels = {
        [S.LOG_ERROR] = "ERROR",
        [S.LOG_WARNING] = "WARNING",
        [S.LOG_INFO] = "INFO",
        [S.LOG_DEBUG] = "DEBUG",
    }
    return levels[level]
end

Mixer.initialize = function()
    Mixer._state = 0x00000000
    Mixer._sources = {
        active = {},
        changed_by_mixer = {},
    }
end

Script._attach_source_create_handler = function()
    Log.info("Attaching to the global `source_create` event.")

    local handler = S.obs_get_signal_handler()
    S.signal_handler_connect(handler, "source_create", Script._callbacks.source_create)
end

---@param calldata userdata
Script._callbacks.source_create = function(calldata)
    local source = S.calldata_source(calldata, "source")
    local source_name = S.obs_source_get_name(source)

    if Script._is_source_audio(source) then
        Log.infof("[ %s ] Handle `source_create`.", source_name)
        Script._attach_handlers_to_source(source)
    end
end

---@param message string
---@param ... any
Log.infof = function(message, ...)
    message = string.format(message, ...)
    Log.info(message)
end

---Ask a source is it input source and does it have capability to work as audio.
---@param source userdata
---@return boolean
Script._is_source_audio = function(source)
    local source_type = S.obs_source_get_type(source)
    local source_cap = S.obs_source_get_output_flags(source)

    local is_input = source_type == S.OBS_SOURCE_TYPE_INPUT
    local is_audio = bit.band(source_cap, S.OBS_SOURCE_AUDIO) ~= 0

    return is_input and is_audio
end

---@param source userdata
Script._attach_handlers_to_source = function(source)
    local source_name = S.obs_source_get_name(source)
    Log.infof("[ %s ] Attach handlers to source.", source_name)

    local callbacks = {
        audio_mixers = Script._callbacks.source_audio_mixers,
        rename = Script._callbacks.source_rename,
        show = Script._callbacks.source_show,
        hide = Script._callbacks.source_hide,
        remove = Script._callbacks.source_remove,
    }

    local handler = S.obs_source_get_signal_handler(source)
    for signal, callback in pairs(callbacks) do
        S.signal_handler_connect(handler, signal, callback)
    end
end

---@param calldata userdata
Script._callbacks.source_audio_mixers = function(calldata)
    local source = S.calldata_source(calldata, "source")
    local source_name = S.obs_source_get_name(source)

    local is_visible = S.obs_source_showing(source)
    if not is_visible then
        Log.debugf("[ %s ] Receive changed, but source is not visible, ignoring.", source_name)
        return
    end

    Log.debugf("[ %s ] Handle `source_audio_mixers`.", source_name)

    if Mixer.is_a_change_made_by_user(source_name) then
        local audio_mixers = Utils.remove_leading_2(
            S.calldata_int(calldata, "mixers")
        )
        Mixer.process_a_change_made_by_user(source, audio_mixers)
    else
        Mixer.mark_a_change_done(source_name)
    end
end

---@param message string
---@param ... any
Log.debugf = function(message, ...)
    message = string.format(message, ...)
    Log.debug(message)
end

---@param message string
Log.debug = function(message)
    Log.log(S.LOG_DEBUG, message)
end

---Guess is a change was unexpected (both user and script can change tracks).
---@param source_name string
---@return boolean
Mixer.is_a_change_made_by_user = function(source_name)
    local value = Mixer._sources.changed_by_mixer[source_name] == nil
    Log.debugf("[ %s ] Is a change made by user? [ %s ]", source_name, value)
    return value
end

---If a change was done by script - we should mark we've already done our work.
---@param source_name string
Mixer.mark_a_change_done = function(source_name)
    Log.debugf("[ %s ] A change marked as done.", source_name)
    Mixer._sources.changed_by_mixer[source_name] = nil
end

---If a change was done by user we respect it and trying to guess if any other changes needed.
---@param source userdata
---@param audio_mixers integer
Mixer.process_a_change_made_by_user = function(source, audio_mixers)
    local source_name = S.obs_source_get_name(source)
    Log.infof("[ %s ] Process a change made by user.", source_name)

    local previous_audio_mixers = Utils.get_audio_mixers_from_source(source)
    if previous_audio_mixers > audio_mixers then
        Log.debugf("[ %s ] User disabled a track, do disable it in Mixer.", source_name)
        Mixer._deactivate_audio_mixers(bit.bxor(previous_audio_mixers, audio_mixers))
        return
    end

    Log.debugf("[ %s ] User enabled a track.", source_name)
    if not Utils.has_only_one_bit(audio_mixers) then
        Log.debugf("[ %s ] Disable all previous enabled tracks.", source_name)

        Mixer._deactivate_audio_mixers(previous_audio_mixers)
        audio_mixers = bit.bxor(previous_audio_mixers, audio_mixers)
    end

    if Mixer._is_state_free(audio_mixers) then
        Log.debugf("[ %s ] New track is on the right and empty place, just activate it.", source_name)
        Mixer._activate_audio_mixers(audio_mixers)
    else
        Log.debugf("[ %s ] New track is on the tacken place, trying to free this place.", source_name)

        for another_source_name, another_source in pairs(Mixer._sources.active) do
            if another_source_name ~= source_name then
                local another_audio_mixers = Utils.get_audio_mixers_from_source(another_source)
                local have_same_bits = bit.band(audio_mixers, another_audio_mixers) ~= 0
                if have_same_bits then
                    Log.debugf("[ %s ] Ask source to free the track.", another_source_name)

                    another_audio_mixers = Mixer._fit_source_to_mixer(another_source)
                    Mixer._activate_audio_mixers(another_audio_mixers)
                    break
                end
            end
        end
    end

    Log.debugf("[ %s ] Performe a change, deactivate other tracks from this source.", source_name)
    Mixer._make_a_change_parallel(source_name, audio_mixers)
end

---If a change was done by user we unable to change again it at once.
---Doing it with a little pause.
---@param source_name string
---@param audio_mixers integer
Mixer._make_a_change_parallel = function(source_name, audio_mixers)
    function _callback()
        Mixer._start_making_a_change(source_name)

        local source = S.obs_get_source_by_name(source_name)
        Log.debugf("[ %s ] Send signal to update source to [ 0x%02x ].", source_name, audio_mixers)
        S.obs_source_set_audio_mixers(source, audio_mixers)
        Mixer.mark_a_change_done(source_name)

        is_something_changed = Utils.get_audio_mixers_from_source(source) == audio_mixers
        S.obs_source_release(source)

        if is_something_changed then
            Log.debugf("[ %s ] Source updated, stop timer.", source_name)
            S.remove_current_callback()
        else
            Log.warningf("[ %s ] Unable to make a change, waiting.", source_name)
        end
    end

    Log.debugf("[ %s ] Start timer to 1 ms to update source to [ 0x%02x ].", source_name, audio_mixers)
    S.timer_add(_callback, 1)
    Mixer._start_making_a_change(source_name)
end

---@param source_name string
---@param audio_mixers integer
Mixer._make_a_change_synchronous = function(source_name, audio_mixers)
    Mixer._start_making_a_change(source_name)

    Log.debugf("[ %s ] Update source to [ 0x%02x ].", source_name, audio_mixers)

    local source = S.obs_get_source_by_name(source_name)
    S.obs_source_set_audio_mixers(source, audio_mixers)
    S.obs_source_release(source)
end

---Show to event `source_audio_mixers` handler script start doing some changes.
---@param source_name string
Mixer._start_making_a_change = function(source_name)
    Log.debugf("[ %s ] Start making a change.", source_name)
    Mixer._sources.changed_by_mixer[source_name] = true
end

---@param calldata userdata
Script._callbacks.source_rename = function(calldata)
    local source_name = S.calldata_string(calldata, "prev_name")
    local source_name_new = S.calldata_string(calldata, "new_name")

    Log.infof("[ %s ] Handle `source_rename` to [ %s ].", source_name, source_name_new)

    Mixer.rename_source(source_name, source_name_new)
end

---Keep inner state up to date.
---@param prev_name string
---@param new_name string
Mixer.rename_source = function(prev_name, new_name)
    if Mixer._sources.active[prev_name] ~= nil then
        Mixer._sources.active[new_name] = Mixer._sources.active[prev_name]
        Mixer._sources.active[prev_name] = nil
    end
end

---@param calldata userdata
Script._callbacks.source_show = function(calldata)
    local source = S.calldata_source(calldata, "source")
    local source_name = S.obs_source_get_name(source)
    Log.infof("[ %s ] Handle `source_show`.", source_name)

    Mixer.add_source(source)
end

---Add an source to the Mixer with all necessary calculations.
---@param source userdata
Mixer.add_source = function(source)
    if not Mixer._is_source_can_fit_without_changes(source) then
        Mixer._fit_source_to_mixer(source)
    end
    Mixer._add_source_to_repository(source)
end

---Check the Mixer inner state and guess if we can use source tracks as is.
---@param source userdata
---@return boolean
Mixer._is_source_can_fit_without_changes = function (source)
    local source_name = S.obs_source_get_name(source)
    local audio_mixers = Utils.get_audio_mixers_from_source(source)

    Log.debugf("[ %s ] Is source [ 0x%02x ] can fit without changes?", source_name, audio_mixers)

    if audio_mixers ~= 0 then
        if not Utils.has_only_one_bit(audio_mixers) then
            Log.debugf("[ %s ] Source has more than one bit, require fit help.", source_name)
            return false
        end

        local is_state_already_set = not Mixer._is_state_free(audio_mixers)
        if is_state_already_set then
            Log.debugf("[ %s ] .", source_name)
            return false
        end
    end

    Log.debugf("[ %s ] Yes, source can fit without any change.", source_name)

    return true
end

---@param source userdata
---@return integer
Utils.get_audio_mixers_from_source = function (source)
    local value = Utils.remove_leading_2(
        S.obs_source_get_audio_mixers(source)
    )

    local source_name = S.obs_source_get_name(source)
    Log.debugf("[ %s ] Got audio tracks from source: [ 0x%02x ].", source_name, value)

    return value
end

---@param value integer
---@return integer
Utils.remove_leading_2 = function (value)
    return Utils.remove_leading(value, 2)
end

---@param value integer
---@param count integer
---@return integer
Utils.remove_leading = function (value, count)
    local leading = bit.lshift(1, 8 - count) - 1
    return bit.band(value, leading)
end

---Check if a value is a power of two.
---@param value integer
---@return boolean
Utils.has_only_one_bit = function(value)
    return value ~= 0 and (bit.band(value, value - 1) == 0)
end

---@param audio_mixers integer
---@return boolean
Mixer._is_state_free = function (audio_mixers)
    Log.debug("Is mixer state is free for next tracks?")

    local is_free = bit.bxor(Mixer._state, Mixer._state + audio_mixers) == audio_mixers

    Log.debugf("Is it free? 0x%02x ^ 0x%02x + 0x%02x => %s", Mixer._state, Mixer._state, audio_mixers, is_free)

    return is_free
end

---Trying to fit a source track state to the Mixer.
---@param source userdata
---@return integer
Mixer._fit_source_to_mixer = function (source)
    local source_name = S.obs_source_get_name(source)
    local audio_mixers = Utils.get_audio_mixers_from_source(source)

    Log.infof("[ %s ] Was asked to fit 0x%02x to internal state 0x%02x.", source_name, audio_mixers, Mixer._state)

    local fit_audio_mixer = Mixer._try_to_fit_audio_mixers_one_by_one(audio_mixers)
    if fit_audio_mixer ~= 0 then
        Log.debugf("[ %s ] Successfully fit (found empty one in corresponding position).", source_name)
    else
        Log.debugf("[ %s ] Unable to fit track in corresponding positions, try to get empty one.", source_name)

        fit_audio_mixer = Mixer._try_to_fit_with_empty_one()
        if fit_audio_mixer ~= 0 then
            Log.debugf("[ %s ] Successfully fit (took the first empty one).", source_name)
        else
            Log.warningf("[ %s ] Unable to found free track.", source_name)
        end
    end

    Log.debugf("[ %s ] Perform a change, fit source's track to mixer.", source_name)
    Mixer._make_a_change_synchronous(source_name, fit_audio_mixer)

    return fit_audio_mixer
end

---Trying to fit in a light way.
---Just check if source has more then one track and maybe we can use other one?
---@param audio_mixers integer
---@return integer
Mixer._try_to_fit_audio_mixers_one_by_one = function (audio_mixers)
    Log.debugf("[ Mixer.fit_one_by_one ] Start.")
    repeat
        Log.debugf("[ Mixer.fit_one_by_one ] Audio mixers at the loop start: [ 0x%02x ].", audio_mixers)

        local least_significat_bit = Utils.least_significat_bit(audio_mixers)
        Log.debugf("[ Mixer.fit_one_by_one ] Got least_significat_bit: [ 0x%02x ].", least_significat_bit)

        audio_mixers = audio_mixers - least_significat_bit
        if Mixer._is_state_free(least_significat_bit) then
            Log.debug("[ Mixer.fit_one_by_one ] Least significant bit is free, take it.")
            return least_significat_bit
        end
    until audio_mixers <= 0

    return audio_mixers
end

---@param value integer
---@return integer
Utils.least_significat_bit = function(value)
    local value = Utils.remove_leading_2(value)
    return value - bit.band(value, value - 1)
end

---Just take any free track from the Mixer.
---@return integer
Mixer._try_to_fit_with_empty_one = function ()
    local inverted = Utils.remove_leading_2(bit.bnot(Mixer._state))
    return Utils.least_significat_bit(inverted)
end

---@param message string
---@param ... any
Log.warningf = function(message, ...)
    message = string.format(message, ...)
    Log.warning(message)
end

---@param message string
Log.warning = function(message)
    Log.log(S.LOG_WARNING, message)
end

---Add the source to internal state.
---@param source userdata
Mixer._add_source_to_repository = function (source)
    source = S.obs_source_get_ref(source)

    local audio_mixers = Utils.get_audio_mixers_from_source(source)
    Mixer._activate_audio_mixers(audio_mixers)

    local source_name = S.obs_source_get_name(source)
    Mixer._sources.active[source_name] = source
end

---@param audio_mixers integer
Mixer._activate_audio_mixers = function (audio_mixers)
    local value = bit.bor(Mixer._state, audio_mixers)
    Log.debugf("[ Mixer ] Activating audio mixers: [ 0x%02x ^ 0x%02x => 0x%02x ]", Mixer._state, audio_mixers, value)
    Mixer._state = value
end

---@param calldata userdata
Script._callbacks.source_hide = function(calldata)
    local source = S.calldata_source(calldata, "source")
    local source_name = S.obs_source_get_name(source)
    Log.infof("[ %s ] Handle `source_hide`.", source_name)

    Mixer.remove_source(source)
end

---@param calldata userdata
Script._callbacks.source_remove = function(calldata)
    local source = S.calldata_source(calldata, "source")
    local source_name = S.obs_source_get_name(source)
    Log.infof("[ %s ] Handle `source_remove`.", source_name)

    Mixer.remove_source(source)
end

---Remove the source from the internal state.
---We don't detach a event handlers, because OBS Studio wiil do it by itself.
---@param source userdata
Mixer.remove_source = function (source)
    local audio_mixers = Utils.get_audio_mixers_from_source(source)
    Mixer._deactivate_audio_mixers(audio_mixers)

    local source_name = S.obs_source_get_name(source)
    S.obs_source_release(Mixer._sources.active[source_name])
    Mixer._sources.active[source_name] = nil
end

---@param audio_mixers integer
Mixer._deactivate_audio_mixers = function (audio_mixers)
    local value = bit.bxor(Mixer._state, audio_mixers)
    Log.debugf("[ Mixer ] Deactivating audio mixers: [0x%02x ^ 0x%02x => 0x%02x]", Mixer._state, audio_mixers, value)
    Mixer._state = value
end

---Called when the script is being unloaded.
function script_unload()
    -- We can't use script log while shutdown process.
    Log.enable_script_log(false)

    Script.destruct()
end

---Look through already exists source and attach to them.
Script._attach_handlers_to_exist_sources = function()
    Log.info("Attach handlers to exist sources.")

    local source_list = S.obs_enum_sources()
    for _, source in ipairs(source_list) do
        local is_audio = Script._is_source_audio(source)
        local is_visible = S.obs_source_showing(source)

        if is_audio then
            Script._attach_handlers_to_source(source)

            if is_visible then
                Mixer.add_source(source)
            end
        end
    end
    S.source_list_release(source_list)
end

Script.destruct = function()
    Log.info("Start script deactivation.")

    Mixer.destruct()

    Log.info("Finish deactivation.")
end

Mixer.destruct = function()
    Log.debug("Start mixer deactivation.")

    for source_name, source in pairs(Mixer._sources.active) do
        S.obs_source_release(source)
        Mixer._sources.active[source_name] = nil
    end

    Log.debug("Finish mixer deactivation.")
end

---@param settings userdata
function script_update(settings)
    SETTINGS = settings

    Log.set_level(S.obs_data_get_int(settings, "log-level"))
    Log.enable_script_log(S.obs_data_get_bool(settings, "script-log-enabled"))
end

---@param settings userdata
function script_defaults(settings)
    -- Log only necessary information as default.
    S.obs_data_set_default_int(settings, "log-level", S.LOG_INFO)
    -- Do not duplicate message to the "Script log".
    S.obs_data_set_default_bool(settings, "script-log-enabled", false)
end

---Configure UI.
---@return userdata
function script_properties()
    local properties = S.obs_properties_create()

    -- Tips and tricks: https://obsproject.com/forum/threads/tips-and-tricks-for-lua-scripts.132256/
    local logging_level_prop = S.obs_properties_add_list(properties, "log-level", "Logging level", S.OBS_COMBO_TYPE_LIST, S.OBS_COMBO_FORMAT_INT)

    -- Logging
    S.obs_property_list_add_int(logging_level_prop, "ERROR", S.LOG_ERROR)
    S.obs_property_list_add_int(logging_level_prop, "WARNING", S.LOG_WARNING)
    S.obs_property_list_add_int(logging_level_prop, "INFO", S.LOG_INFO)
    S.obs_property_list_add_int(logging_level_prop, "DEBUG", S.LOG_DEBUG)

    S.obs_properties_add_bool(properties, "script-log-enabled", "Also log to the script log")

    -- Debugging
    local debug_button = S.obs_properties_add_button(properties, "debug-mixer-state", "Print internal state", Script._callbacks.debug_mixer_state)
    S.obs_property_button_set_type(debug_button, S.OBS_BUTTON_DEFAULT)
    S.obs_property_set_visible(debug_button, false)

    S.obs_property_set_modified_callback(logging_level_prop, Script._callbacks.logging_level_changed)

    -- Run callbacks on settings.
    S.obs_properties_apply_settings(properties, SETTINGS)

    return properties
end

Script._callbacks.debug_mixer_state = function()
    Mixer._log_internal_state()
end

Mixer._log_internal_state = function()
    Log.error("[ DEBUG INFO ] +++++++++++++++++++++++++++++++++++++")

    Log.errorf("[ DEBUG INFO ] Mixer state: 0x%02x", Mixer._state)

    local source_names = {}
    local should_log_sources = false
    for source_name in pairs(Mixer._sources.active) do
        table.insert(source_names, source_name)
        should_log_sources = true
    end

    if should_log_sources then
        Log.error("[ DEBUG INFO ] Registered sources:")
        for _, source_name in pairs(source_names) do
            Log.errorf("[ DEBUG INFO ] - %s", source_name)
        end
    end

    Log.error("[ DEBUG INFO ] =====================================")
end

Log.errorf = function(message, ...)
    message = string.format(message, ...)
    Log.error(message)
end

Log.error = function(message)
    Log.log(S.LOG_ERROR, message)
end

Script._callbacks.logging_level_changed = function(properties, property, settings)
    local logging_level = S.obs_data_get_int(settings, "log-level")
    local debug_button = S.obs_properties_get(properties, "debug-mixer-state")
    S.obs_property_set_visible(debug_button, logging_level == S.LOG_DEBUG)
    return true
end
