-- tnp_action_player_board()
--  Handles actions from a player boarding a requested tnp train.
function tnp_action_player_board(player, train)
    local config = settings.get_player_settings(player)

    if config['tnp-train-boarding-behaviour'].value == 'manual' then
        -- Force the train into manual mode, request is then fully complete.
        tnp_train_enact(train, true, nil, true, nil)
        tnp_request_cancel(player, train, nil)
    elseif config['tnp-train-boarding-behaviour'].value == 'stationselect' then
        -- Force the train into manual mode then display station select
        tnp_train_enact(train, true, nil, true, nil)
        tnp_gui_stationlist(player, train)
    end
end

-- tnp_action_player_cancel()
--   Actions a player cancelling a tnp request
function tnp_action_player_cancel(player, train)
    if not train.valid then
        -- We'd normally send a message, but because the trains invalid it'll be autogenerated from the prune task.
        tnp_request_cancel(player, train, nil)
        return
    end

    tnp_train_enact(train, true, nil, nil, false)
    tnp_request_cancel(player, train, {"tnp_train_cancelled"})
end

-- tnp_action_player_request()
--   Actions a player requesting a train
function tnp_action_player_request(player)
    local target = tnp_stop_find(player)

    if not target then
        tnp_message(tnpdefines.loglevel.core, player, {"tnp_train_notrainstop"})
        return
    end

    tnp_request_create(player, target)
end

-- tnp_action_player_request_boarded()
--   Actions a player request from onboard a train
function tnp_action_player_request_boarded(player, train, target)
    local status = tnp_state_train_get(train, 'status')
    local train_player = tnp_state_train_get(train, 'player')

    if train_player and (not train_player.valid or train_player.index ~= player.index) then
        -- Special case where the train the players on now was assigned to another player.  This player wins.
        tnp_train_enact(train, true, nil, false, nil)
        tnp_request_cancel(train_player, train, {"tnp_train_cancelled_stolen", player.name})
    elseif status and status == tnpdefines.train.status.rearrived then
        -- Another special case where the train has already been redispatched and we're waiting for the
        -- player to disembark.  We need to reset the schedule before we reassign.
        tnp_train_enact(train, true, nil, false, nil)
    end

    if target then
        tnp_request_redispatch(player, target, train)
    else
        tnp_request_assign(player, nil, train)
        tnp_action_player_board(player, train)
    end
end

-- tnp_action_player_railtool()
--   Actions an area selection
function tnp_action_player_railtool(player, entities, altmode)
    local valid_stops = {}
    local valid_rails = {}

    -- We need to know what train we're dispatching and cancel any current requests.  Do this early to ensure we cleanup
    -- any temporary stops etc.
    local train = tnp_state_player_get(player, 'train')
    if train then
        tnp_train_enact(train, true, nil, nil, nil)
        tnp_request_cancel(player, train, nil)

        -- Keep the same train providing its valid though
        if not train.valid then
            train = nil
        end
    end

    for _, ent in pairs(entities) do
        if ent.valid then
            if ent.type == "train-stop" then
                if tnp_stop_danger(ent) == false then
                    table.insert(valid_stops, ent)
                end
            elseif ent.type == "straight-rail" then
                if tnp_direction_iscardinal(ent.direction) then
                    table.insert(valid_rails, ent)
                end
            end
        end
    end

    local target = nil
    if #valid_stops > 0 then
        target = valid_stops[1]
    end

    if player.vehicle and player.vehicle.train then
        train = player.vehicle.train
    elseif not train then
        if target ~= nil then
            train = tnp_train_find(player, target)
        elseif #valid_rails > 0 then
            train = tnp_train_find(player, valid_rails[1])
        else
            train = tnp_train_find(player, nil)
        end
    end

    if not train then
        tnp_message(tnpdefines.loglevel.core, player, {"tnp_train_invalid"})
        return false
    end

    if target then
        if tnp_player_cursorstack(player) == "tnp-railtool" then
            player.clean_cursor()
        end
        player.close_map()

        -- The player is on the train, this is a redispatch.
        if player.vehicle and player.vehicle.train then
            tnp_action_player_request_boarded(player, player.vehicle.train, target)
        else
            tnp_request_dispatch(player, target, train)
        end

        if altmode then
            tnp_state_train_set(train, 'keep_position', true)
        end

        return
    end

    -- Ok, this gets messy.  We now need to test creating train stops until we can create a pair, then
    -- trigger a dispatch and rely on events from there.
    local complete = false
    if #valid_rails > 0 then
        local i = 1
        repeat
            complete = tnp_dynamicstop_create(player, valid_rails[i], train)
            i = i + 1
        until i > #valid_rails or complete
    end

    if complete then
        if tnp_player_cursorstack(player) == "tnp-railtool" then
            player.clean_cursor()
        end
        player.close_map()

        if altmode then
            tnp_state_train_set(train, 'keep_position', true)
        end
    else
        tnp_message(tnpdefines.loglevel.core, player, {"tnp_train_nolocation"})
        return
    end
end

-- tnp_action_player_train()
--   Handles actions from a player entering/exiting a train
function tnp_action_player_train(player, train)
    if player.vehicle then
        -- Player has entered a train.  First check if we're tracking the player at all.
        if tnp_state_player_query(player) then
            local player_train = tnp_state_player_get(player, 'train')

            if not player_train or not player_train.valid then
                -- The train we were tracking for this player is now invalid, cancel what we can.
                tnp_message(tnpdefines.loglevel.core, player, {"tnp_train_cancelled_invalid"})
                tnp_request_cancel(player, player_train, nil)

            elseif not tnp_state_train_query(train) then
                -- Player has boarded a train that we are not tracking for them.  For now, cancel the request.
                tnp_train_enact(player_train, true, nil, nil, nil)
                tnp_request_cancel(player, player_train, {"tnp_train_cancelled_wrongtrain"})

            elseif player_train.id ~= train.id then
                -- Player has boarded a train we are tracking, but not for them.
                tnp_train_enact(player_train, true, nil, nil, nil)
                tnp_request_cancel(player, player_train, {"tnp_train_cancelled_wrongtrain"})

            else
                -- Player has successfully boarded their tnfp train
                local status = tnp_state_train_get(train, 'status')

                -- Player has boarded the train whilst we're dispatching -- treat that as an arrival.
                if status == tnpdefines.train.status.dispatching or status == tnpdefines.train.status.dispatched then
                    tnp_action_train_arrival(player, train)
                end

                tnp_action_player_board(player, train)
            end

        elseif tnp_state_train_query(train) then
            -- We were not tracking this player -- but we are tracking the train they've entered.  For now, simply report it as stolen
            -- and cleanup.
            local train_player = tnp_state_train_get(train, 'player')
            tnp_request_cancel(train_player, train, {"tnp_train_cancelled_stolen", player.name})
            tnp_train_enact(train, true, nil, nil, nil)
        end
    elseif tnp_state_train_query(train) then
        -- Player has exited a train that we are tracking.
        local status = tnp_state_train_get(train, 'status')

        -- Attempt to close the stationlist regardless, just in case the players exited the train we sent
        tnp_gui_stationlist_close(player)

        -- It shouldn't be possible to exit a vehicle in a dispatching/dispatched status, as entering the vehicle
        -- would have triggered the boarding event, so we just need to handle arrived, redispatched or rearrived.
        if status == tnpdefines.train.status.arrived then
            tnp_train_enact(train, true, nil, nil, nil)
            tnp_request_cancel(player, train, {"tnp_train_cancelled"})
        elseif status == tnpdefines.train.status.redispatched then
            if tnp_state_train_get(train, 'keep_schedule') then
                tnp_request_cancel(player, train, {"tnp_train_complete_continue", tnp_train_destinationstring(train)})
            elseif tnp_state_train_get(train, 'keep_position') then
                -- The player requested the train waits somewhere for them in manual mode, but jumped out before
                -- we arrived.  For qol, presume the train should continue -- but notify them.
                tnp_message(tnpdefines.loglevel.detailed, player, {"tnp_train_continue", tnp_train_destinationstring(train)})
            else
                tnp_train_enact(train, true, nil, nil, nil)
                tnp_request_cancel(player, train, {"tnp_train_complete_resume"})
            end
        elseif status == tnpdefines.train.status.rearrived then
            if tnp_state_train_get(train, 'keep_schedule') then
                local station = tnp_state_train_get(train, 'station')

                local target = "?"
                if station and station.valid then
                    target = station.backer_name
                end

                tnp_message(tnpdefines.loglevel.detailed, player, {"tnp_train_complete_remain", target})
                tnp_request_cancel(player, train, nil)
            else
                tnp_message(tnpdefines.loglevel.detailed, player, {"tnp_train_complete_resume"})
                tnp_train_enact(train, true, nil, nil, nil)
            end
        end
    end
end

-- tnp_action_railtool()
--   Provides the given player with a railtool item
function tnp_action_railtool(player, item)
    local cursoritem = tnp_player_cursorstack(player)

    if cursoritem then
        if cursoritem == item then
            -- Player already has this railtool in hand.
            return
        elseif item == "tnp-railtool" then
            -- Player is swapping from a supply railtool to normal railtool
            tnp_supplytrain_clear(player)
        end
    end

    if not player.clean_cursor() then
        tpn_message_flytext(player, player.position, {"tnp_railtool_error_clear"})
        return
    end

    -- If the player has a railtool in their inventory, throw that one away
    local inventory = player.get_main_inventory()
    if inventory then
        inventory.remove({name = "tnp-railtool", count = 999})
        inventory.remove({name = "tnp-railtool-supply", count = 999})
    end

    local result = player.cursor_stack.set_stack({
        name = item,
        count = 1
    })
    if not result then
        tnp_message_flytext(player, player.position, {"tnp_railtool_error_provide"})
    end

    tnp_state_player_set(player, 'railtool', item)
    devent_enable("player_cursor_stack_changed")
end

-- tnp_action_stationselect_cancel()
--   Actions the stationselect dialog being cancelled
function tnp_action_stationselect_cancel(player)
    local train = tnp_state_player_get(player, 'train')

    tnp_gui_stationlist_close(player)

    -- We're still tracking a request at this point we need to cancel, though theres no
    -- schedule to amend.
    tnp_request_cancel(player, train, nil)
end

-- tnp_action_stationselect_pin()
--   Actions pinning a station in the stationselect list
function tnp_action_stationselect_pin(player, gui)
    local station = tnp_state_gui_get(gui, player, 'pinstation')

    if tnp_state_stationpins_check(player, station) then
        tnp_state_stationpins_delete(player, station)
    else
        tnp_state_stationpins_set(player, station)
    end

    if player.vehicle and player.vehicle.valid and player.vehicle.train then
        tnp_gui_stationlist_build(player, player.vehicle.train)
        tnp_gui_stationlist_search(player)
    end
end

function tnp_action_stationselect_railtoolmap(player)
    tnp_gui_stationlist_close(player)
    player.open_map(player.position)
    tnp_action_railtool(player, "tnp-railtool")
end

-- tnp_action_stationselect_redispatch()
--   Actions a stationselect request to redispatch
function tnp_action_stationselect_redispatch(player, gui)
    local station = tnp_state_gui_get(gui, player, 'station')
    local train = tnp_state_player_get(player, 'train')

    tnp_gui_stationlist_close(player)

    if not station or not station.valid then
        tnp_request_cancel(player, train, {"tnp_train_cancelled_invalidstation"})
        return
    end

    if not train or not train.valid then
        tnp_request_cancel(player, train, {"tnp_train_cancelled_invalid"})
    end

    -- Lets just revalidate the player is on a valid train
    if not player.vehicle or not player.vehicle.train or not player.vehicle.train.valid then
        tnp_request_cancel(player, train, {"tnp_train_cancelled_invalidstate"})
    end

    tnp_request_redispatch(player, station, player.vehicle.train)
end

-- tnp_action_train_arrival()
--   Partially fulfils a tnp request, marking a train as successfully arrived.
function tnp_action_train_arrival(player, train)
    local dynamicstop = tnp_state_player_get(player, 'dynamicstop')
    if dynamicstop then
        tnp_dynamicstop_destroy(player, dynamicstop)
    end

    tnp_state_train_delete(train, 'timeout_arrival')
    tnp_state_train_set(train, 'status', tnpdefines.train.status.arrived)
end

-- tnp_action_train_rearrival()
--   Partially fulfils a tnp request, marking a train as successfully arrived after redispatch.
function tnp_action_train_rearrival(player, train)
    local keep_position = tnp_state_train_get(train, 'keep_position')

    -- If we're holding position, we can fully complete the request now as we'll be resetting the
    -- schedule and switching to manual mode.  Otherwise, we keep the train active so we can
    -- restore the schedule if the player disembarks.
    if keep_position then
        tnp_train_enact(train, true, nil, true, nil)
        tnp_request_cancel(player, train, {"tnp_train_arrived_manual", tnp_train_destinationstring(train)})
    else
        tnp_request_cancel(player, nil, {"tnp_train_arrived", tnp_train_destinationstring(train)})
        tnp_state_train_set(train, 'status', tnpdefines.train.status.rearrived)
    end
end

-- tnp_action_train_schedulechange()
--   Performs any checks and actions required when a trains schedule is changed.
function tnp_action_train_schedulechange(train, event_player)
    if event_player then
        -- The schedule was changed by a player, on a train we're dispatching.  We need to cancel this request
        local player = tnp_state_train_get(train, 'player')
        local status = tnp_state_train_get(train, 'status')

        if status ~= tnpdefines.train.status.rearrived then
            tnp_request_cancel(player, train, {"tnp_train_cancelled_schedulechange", event_player.name})
        end
    else
        -- This is likely a schedule change we've made.  Check if we're expecting one.
        local expect = tnp_state_train_get(train, 'expect_schedulechange')
        if expect then
            tnp_state_train_set(train, 'expect_schedulechange', false)
            return
        end

        -- This is either another mod changing schedules of a train we're using, or our tracking is off.
        -- For now, do nothing -- though we should be able to verify its still going where we expect it to.
        -- !!!: TODO
    end
end

-- tnp_action_train_statechange()
--   Wrapper function to handle a train changing driving state
function tnp_action_train_statechange(train)
    local player = tnp_state_train_get(train, 'player')

    if not player or not player.valid then
        tnp_request_cancel(player, train, nil)
        return
    end

    tnp_action_trainstate(player, train)
end

-- tnp_action_timeout()
--   Loops through trains and applies any timeout actions for dispatched trains.
function tnp_action_timeout()
    local trains = tnp_state_train_timeout()

    if not trains or (#trains.arrival == 0 and #trains.railtooltest == 0) then
        return
    end

    for _, train in pairs(trains.arrival) do
        local player = tnp_state_train_get(train, 'player')
        local status = tnp_state_train_get(train, 'status')

        if status == tnpdefines.train.status.dispatching or status == tnpdefines.train.status.dispatched or status == tnpdefines.train.status.railtooltest then
            tnp_train_enact(train, true, nil, nil, false)
            tnp_request_cancel(player, train, {"tnp_train_cancelled_timeout_arrival"})
        end
    end

    for _, train in pairs(trains.railtooltest) do
        tnp_state_train_delete(train, 'timeout_railtooltest')
        tnp_action_train_statechange(train)
    end
end
