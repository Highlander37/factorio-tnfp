-- tnp_handle_request()
--   Handles a request for a TNfP Train via input
function tnp_handle_request(event)
    local player = game.players[event.player_index]
    
    if not player.surface then
        tnp_message(ptndefines.loglevel.core, player, {"tnp_error_location_surface", player.name})
        return
    end
    
    if not player.position then
        tnp_message(ptndefines.loglevel.core, player, {"tnp_error_location_position", player.name})
        return
    end
    
    tnp_action_request_create(player)
end

-- tnp_handle_shortcut()
--   Handles a shortcut being pressed
function tnp_handle_shortcut(event)
    if event.prototype_name == "tnp-handle-request" then
        tnp_handle_request(event)
    end
end

-- tnp_handle_player_vehicle()
--   Handles a player entering a vehicle
function tnp_handle_player_vehicle(event)
    local player = game.players[event.player_index]
    
    -- Dont track entering non-train vehicles
    if not event.entity.train then
        return
    end
    
    -- This player doesnt have a request outstanding
    if not tnp_state_player_query(player) then
        return
    end
    
    local train = tnp_state_player_get(player, 'train')
    -- Player has successfully boarded their tnp train
    if train.id == event.entity.train.id then
        tnp_action_request_complete(player, train)
    end
end


-- tnp_handle_train_schedulechange()
--   Handles a trains schedule being changed
function tnp_handle_train_schedulechange(event)
    -- A train we're not tracking
    if not tnp_state_train_query(event.train) then
        return
    end

    local player = nil
    if event.player_index and game.players[event.player_index] then
        player = game.players[event.player_index]
    end
    
    tnp_action_train_schedulechange(event.train, player)
end

-- tnp_handle_train_statechange()
--   Handles a trains state being changed
function tnp_handle_train_statechange(event)
    -- A train we're not tracking
    if not tnp_state_train_query(event.train) then
        return
    end    

    tnp_action_train_statechange(event.train)
end