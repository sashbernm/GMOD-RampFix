--[[
	Author: Sasha
	Description: Prevents rampbugs and similar issues. Code based off GAMMACASE's css port of momentum mod's fix.
--]]

-- WARNING: THIS IS DESIGNED FOR NIFLS SK-SURF GAMEMODE, IT MAY WORK WITH OTHER GAMEMODES BUT IT IS UNTESTED!!!


--locailze many global function calls, saves A LOT of cpu cycles.
local math_ = math
local absolute = math_.abs
local clamp = math_.Clamp
local bit_ = bit
local bit_bor = bit_.bor

-- Globals defined in momentums rampfix.
-- @nifl doesnt like my naming style :(
-- but i'm just following googles style sheet!!!
local FLT_EPSILON_ = 1.192092896e-07
local MAX_CLIP_PLANES_ = 5
local BLOCKED_FLOOR_ = 1
local BLOCKED_STEP_ = 2
local LOW_SPEED_RESTORE_THRESHOLD_ = 100.0
local MAX_VELOCITY_HISTORY_TICKS_ = 10
local FALLBACK_SPEED_DROP_RATIO_ = 0.4
local FALLBACK_RAMP_NORMAL_MIN_Z_ = 0.05
local FALLBACK_RAMP_NORMAL_MAX_Z_ = 0.7
local FALLBACK_RAMP_PROBE_DOWN_DISTANCE_ = 32.0
local FALLBACK_RAMP_PROBE_FORWARD_DISTANCE_ = 16.0
local CONVAR_FLAGS_ =
    bit_bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED)

local ramp_bump_count_cvar_ = nil
local ramp_initial_retrace_length_cvar_ = nil
local noclip_workaround_cvar_ = nil
local restore_ticks_back_cvar_ = nil
if SERVER then
  ramp_bump_count_cvar_ = CreateConVar(
      "momsurffix_ramp_bumpcount",
      "8",
      CONVAR_FLAGS_,
      "Helps with fixing surf/ramp bugs",
      4,
      16)
  ramp_initial_retrace_length_cvar_ = CreateConVar(
      "momsurffix_ramp_initial_retrace_length",
      "0.2",
      CONVAR_FLAGS_,
      "Amount of units used in offset for retraces",
      0.2,
      5.0)
  noclip_workaround_cvar_ = CreateConVar(
      "momsurffix_enable_noclip_workaround",
      "1",
      CONVAR_FLAGS_,
      "Enables workaround to prevent invalid ramp traces",
      0,
      1)
  restore_ticks_back_cvar_ = CreateConVar(
      "momsurffix_restore_ticks_back",
      "2",
      CONVAR_FLAGS_,
      "How many ticks back to use for low-speed restore",
      1,
      MAX_VELOCITY_HISTORY_TICKS_)
else
  ramp_bump_count_cvar_ = GetConVar("momsurffix_ramp_bumpcount")
  ramp_initial_retrace_length_cvar_ =
      GetConVar("momsurffix_ramp_initial_retrace_length")
  noclip_workaround_cvar_ = GetConVar("momsurffix_enable_noclip_workaround")
  restore_ticks_back_cvar_ = GetConVar("momsurffix_restore_ticks_back")
end
local sv_bounce_cvar_ = GetConVar("sv_bounce")
local zero_vector_ = Vector(0, 0, 0)
local move_state_by_player_ = setmetatable({}, {__mode = "k"})
local velocity_history_by_player_ = setmetatable({}, {__mode = "k"})
local last_history_tick_by_player_ = setmetatable({}, {__mode = "k"})


-- these are meant to replace the slow, global functions that do similar things. 
-- RampFix is quite heavy on performance, so although i could localize the global functions,
-- it's better performance-wise to make my own.
local function copy_vector(vector_value)
  return Vector(vector_value.x, vector_value.y, vector_value.z)
end

local function close_enough_float(left_value, right_value, epsilon_value)
  local epsilon = epsilon_value or FLT_EPSILON_
  return absolute(left_value - right_value) <= epsilon
end

local function vectors_equal_exact(left_value, right_value)
  return left_value.x == right_value.x and left_value.y == right_value.y and
      left_value.z == right_value.z
end

local function close_enough_vector(left_value, right_value, epsilon_value)
  local epsilon = epsilon_value or FLT_EPSILON_
  return absolute(left_value.x - right_value.x) <= epsilon and
      absolute(left_value.y - right_value.y) <= epsilon and
      absolute(left_value.z - right_value.z) <= epsilon
end

local function is_valid_plane_normal(plane_normal)
  if not isvector(plane_normal) then
    return false
  end

  return absolute(plane_normal.x) <= 1.0 and absolute(plane_normal.y) <= 1.0 and
      absolute(plane_normal.z) <= 1.0
end

local function get_surface_friction(player_value)
  if not player_value.GetInternalVariable then
    return 1.0
  end

  local success, internal_value =
      pcall(player_value.GetInternalVariable, player_value, "m_surfaceFriction")
  if not success then
    return 1.0
  end

  local numeric_value = tonumber(internal_value)
  if not numeric_value then
    return 1.0
  end

  if numeric_value < 0.0 then
    return 0.0
  end

  return numeric_value
end

local function is_ducking(player_value, move_data)
  if move_data and move_data.KeyDown then
    local success, key_down = pcall(move_data.KeyDown, move_data, IN_DUCK)
    if success and key_down then
      return true
    end
  end

  return player_value:Crouching()
end

local function get_player_hull(player_value, move_data)
  if player_value.GetHull and player_value.GetHullDuck then
    local mins_value
    local maxs_value

    if is_ducking(player_value, move_data) then
      mins_value, maxs_value = player_value:GetHullDuck()
    else
      mins_value, maxs_value = player_value:GetHull()
    end

    if isvector(mins_value) and isvector(maxs_value) then
      return mins_value, maxs_value
    end
  end

  return player_value:OBBMins(), player_value:OBBMaxs()
end

local function get_ramp_bump_count()
  if not ramp_bump_count_cvar_ then
    ramp_bump_count_cvar_ = GetConVar("momsurffix_ramp_bumpcount")
  end

  if not ramp_bump_count_cvar_ then
    return 8
  end

  return clamp(ramp_bump_count_cvar_:GetInt(), 4, 16)
end

local function get_ramp_initial_retrace_length()
  if not ramp_initial_retrace_length_cvar_ then
    ramp_initial_retrace_length_cvar_ =
        GetConVar("momsurffix_ramp_initial_retrace_length")
  end

  if not ramp_initial_retrace_length_cvar_ then
    return 0.2
  end

  return clamp(ramp_initial_retrace_length_cvar_:GetFloat(), 0.2, 5.0)
end

local function get_noclip_workaround_enabled()
  if not noclip_workaround_cvar_ then
    noclip_workaround_cvar_ =
        GetConVar("momsurffix_enable_noclip_workaround")
  end

  if not noclip_workaround_cvar_ then
    return true
  end

  return noclip_workaround_cvar_:GetBool()
end

local function get_restore_ticks_back()
  if not restore_ticks_back_cvar_ then
    restore_ticks_back_cvar_ = GetConVar("momsurffix_restore_ticks_back")
  end

  if not restore_ticks_back_cvar_ then
    return 2
  end

  return clamp(
      restore_ticks_back_cvar_:GetInt(), 1, MAX_VELOCITY_HISTORY_TICKS_)
end

local function get_sv_bounce()
  if not sv_bounce_cvar_ then
    sv_bounce_cvar_ = GetConVar("sv_bounce")
  end

  if sv_bounce_cvar_ then
    return sv_bounce_cvar_:GetFloat()
  end

  return 0.0
end

local function trace_player_bbox(player_value, start_pos, end_pos, mins_value, maxs_value)
  return util.TraceHull({
    start = start_pos,
    endpos = end_pos,
    mins = mins_value,
    maxs = maxs_value,
    mask = MASK_PLAYERSOLID,
    collisiongroup = COLLISION_GROUP_PLAYER_MOVEMENT,
    filter = player_value
  })
end

local function is_valid_movement_trace(
    player_value, trace_result, mins_value, maxs_value)
  if not trace_result then
    return false
  end

  if trace_result.AllSolid or trace_result.StartSolid then
    return false
  end

  if close_enough_float(trace_result.Fraction or 0.0, 0.0) then
    return false
  end

  local plane_normal = trace_result.HitNormal or zero_vector_
  if not is_valid_plane_normal(plane_normal) then
    return false
  end

  local end_pos = trace_result.HitPos
  if not isvector(end_pos) then
    return false
  end

  local stuck_trace =
      trace_player_bbox(player_value, end_pos, end_pos, mins_value, maxs_value)
  if stuck_trace.StartSolid or not close_enough_float(stuck_trace.Fraction, 1.0) then
    return false
  end

  return true
end

local function clip_velocity(in_velocity, normal_value, overbounce_value)
  local blocked = 0
  local angle = normal_value.z

  if angle > 0.0 then
    blocked = bit_bor(blocked, BLOCKED_FLOOR_)
  end
  if close_enough_float(angle, 0.0) then
    blocked = bit_bor(blocked, BLOCKED_STEP_)
  end

  local backoff = in_velocity:Dot(normal_value) * overbounce_value
  local out_velocity = in_velocity - normal_value * backoff
  local adjust = out_velocity:Dot(normal_value)
  if adjust < 0.0 then
    out_velocity = out_velocity - normal_value * adjust
  end

  return out_velocity, blocked
end

local function should_process_player(player_value)
  if not IsValid(player_value) or not player_value:Alive() then
    return false
  end

  if CLIENT and player_value ~= LocalPlayer() then
    return false
  end

  if player_value:InVehicle() then
    return false
  end

  if player_value:GetMoveType() ~= MOVETYPE_WALK then
    return false
  end

  if player_value:WaterLevel() >= 2 then
    return false
  end

  return true
end

local function resolve_start_velocity(move_data, fallback_velocity)
  local result_velocity = copy_vector(fallback_velocity)
  if not move_data.GetFinalIdealVelocity then
    return result_velocity
  end

  local success, final_ideal_velocity =
      pcall(move_data.GetFinalIdealVelocity, move_data)
  if not success or not isvector(final_ideal_velocity) then
    return result_velocity
  end

  if final_ideal_velocity:LengthSqr() <= 0.0 then
    return result_velocity
  end

  return copy_vector(final_ideal_velocity)
end

local function push_velocity_history(player_value, velocity_value)
  local history = velocity_history_by_player_[player_value]
  if not history then
    history = {}
    velocity_history_by_player_[player_value] = history
  end

  table.insert(history, 1, copy_vector(velocity_value))
  while #history > MAX_VELOCITY_HISTORY_TICKS_ do
    table.remove(history)
  end
end

local function get_restore_velocity_from_history(player_value, fallback_velocity)
  local history = velocity_history_by_player_[player_value]
  if not history then
    return copy_vector(fallback_velocity)
  end
  local ticks_back = get_restore_ticks_back()
  local history_index = ticks_back + 1
  local history_velocity = history[history_index]
  if not history_velocity then
    history_velocity = history[#history]
  end

  if not history_velocity then
    return copy_vector(fallback_velocity)
  end

  return copy_vector(history_velocity)
end

local function is_ramp_transition_context(
    player_value, origin_value, mins_value, maxs_value, reference_velocity)
  local down_offset = Vector(0, 0, -FALLBACK_RAMP_PROBE_DOWN_DISTANCE_)
  local down_trace = trace_player_bbox(
      player_value, origin_value, origin_value + down_offset, mins_value, maxs_value)
  local down_normal = down_trace.HitNormal or zero_vector_
  if is_valid_plane_normal(down_normal) and
      down_normal.z > FALLBACK_RAMP_NORMAL_MIN_Z_ and
      down_normal.z < FALLBACK_RAMP_NORMAL_MAX_Z_ then
    return true
  end

  if reference_velocity:LengthSqr() <= 0.0 then
    return false
  end

  local direction = reference_velocity:GetNormalized()
  local probe_start =
      origin_value + direction * FALLBACK_RAMP_PROBE_FORWARD_DISTANCE_
  local forward_trace = trace_player_bbox(
      player_value, probe_start, probe_start + down_offset, mins_value, maxs_value)
  local forward_normal = forward_trace.HitNormal or zero_vector_
  if not is_valid_plane_normal(forward_normal) then
    return false
  end

  return forward_normal.z > FALLBACK_RAMP_NORMAL_MIN_Z_ and
      forward_normal.z < FALLBACK_RAMP_NORMAL_MAX_Z_
end

--[[
This function is a lot bigger than i wish it were, try_player_move contains MOST of the logic of rampfix.
I'd prefer to have broken it up into smaller functions, but i won't bother at the moment.
The main issue i've had is the fact that CGameMovement::TryPlayerMove isn't exposed to the lua interface.
Thankfully, after a lot of research, i figured out while we cannot hook into TryPlayerMove 
(which would fix rampbugs without requiring prediction for ping)
I can have a very similar affect by combining FinishMove, Move, AND SetupMove and adding prediction in between all of them. 
]]--

local function try_player_move(player_value, move_state, start_velocity)
  local original_velocity = copy_vector(start_velocity)
  local primal_velocity = copy_vector(start_velocity)
  local fixed_origin = copy_vector(move_state.origin)
  local abs_origin = copy_vector(move_state.origin)
  local valid_plane = Vector(0, 0, 0)
  local velocity = copy_vector(start_velocity)
  local end_pos = copy_vector(move_state.origin)
  local all_fraction = 0.0
  local time_left = move_state.frame_time
  local planes = {}
  local num_planes = 0
  local blocked = 0
  local num_bumps = get_ramp_bump_count()
  local stuck_on_ramp = false
  local has_valid_plane = false
  local trace_result = nil
  local fix_detected = false
  local should_break = false

  local bounce = get_sv_bounce()
  local retrace_length = get_ramp_initial_retrace_length()
  local surface_friction = move_state.surface_friction
  local is_on_ground = move_state.on_ground
  local move_type = move_state.move_type
  local mins_value = move_state.mins
  local maxs_value = move_state.maxs

  for bump_count = 0, num_bumps - 1 do
    if velocity:LengthSqr() == 0.0 then
      break
    end

    repeat
      if stuck_on_ramp then
        if not has_valid_plane then
          local plane_normal = zero_vector_
          if trace_result and isvector(trace_result.HitNormal) then
            plane_normal = trace_result.HitNormal
          end

          if not close_enough_vector(plane_normal, zero_vector_) and
              not vectors_equal_exact(valid_plane, plane_normal) then
            valid_plane = copy_vector(plane_normal)
            has_valid_plane = true
          else
            for plane_index = num_planes, 1, -1 do
              local candidate_plane = planes[plane_index]
              if candidate_plane and
                  not close_enough_vector(candidate_plane, zero_vector_) and
                  is_valid_plane_normal(candidate_plane) and
                  not vectors_equal_exact(valid_plane, candidate_plane) then
                valid_plane = copy_vector(candidate_plane)
                has_valid_plane = true
                break
              end
            end
          end
        end

        if has_valid_plane then
          local overbounce = 1.0
          if valid_plane.z < 0.7 or valid_plane.z > 1.0 then
            overbounce = 1.0 + bounce * (1.0 - surface_friction)
          end

          velocity = select(1, clip_velocity(velocity, valid_plane, overbounce))
          original_velocity = copy_vector(velocity)
        elseif not get_noclip_workaround_enabled() or velocity.z < -6.25 or
            velocity.z > 0.0 then
          local offset_scale = (bump_count * 2.0) * retrace_length
          local offsets = {-offset_scale, 0.0, offset_scale}
          local valid_planes = 0
          valid_plane = Vector(0, 0, 0)

          for i = 1, 3 do
            for j = 1, 3 do
              for h = 1, 3 do
                local offset = Vector(offsets[i], offsets[j], offsets[h])
                local offset_mins = offset * 0.5
                local offset_maxs = offset * 0.5

                if offset.x > 0.0 then
                  offset_mins.x = offset_mins.x / 2.0
                end
                if offset.y > 0.0 then
                  offset_mins.y = offset_mins.y / 2.0
                end
                if offset.z > 0.0 then
                  offset_mins.z = offset_mins.z / 2.0
                end

                if offset.x < 0.0 then
                  offset_maxs.x = offset_maxs.x / 2.0
                end
                if offset.y < 0.0 then
                  offset_maxs.y = offset_maxs.y / 2.0
                end
                if offset.z < 0.0 then
                  offset_maxs.z = offset_maxs.z / 2.0
                end

                local trace_start = fixed_origin + offset
                local trace_end = end_pos - offset
                local trace_mins = mins_value - offset_mins
                local trace_maxs = maxs_value + offset_maxs
                local retrace = trace_player_bbox(
                    player_value, trace_start, trace_end, trace_mins, trace_maxs)
                local plane_normal = retrace.HitNormal or zero_vector_

                if is_valid_plane_normal(plane_normal) and retrace.Fraction > 0.0 and
                    retrace.Fraction < 1.0 and not retrace.StartSolid then
                  valid_planes = valid_planes + 1
                  valid_plane = valid_plane + plane_normal
                end
              end
            end
          end

          if valid_planes ~= 0 and not close_enough_vector(valid_plane, zero_vector_) then
            has_valid_plane = true
            valid_plane:Normalize()
            fix_detected = true
            break
          end
        end

        if has_valid_plane then
          fixed_origin = fixed_origin + valid_plane * retrace_length
        else
          stuck_on_ramp = false
          break
        end
      end

      end_pos = fixed_origin + velocity * time_left
      if stuck_on_ramp and has_valid_plane then
        trace_result = trace_player_bbox(
            player_value, fixed_origin, end_pos, mins_value, maxs_value)
        trace_result.HitNormal = valid_plane
      else
        trace_result = trace_player_bbox(
            player_value, abs_origin, end_pos, mins_value, maxs_value)
      end

      if bump_count > 0 and
          not is_valid_movement_trace(
              player_value, trace_result, mins_value, maxs_value) then
        has_valid_plane = false
        stuck_on_ramp = true
        fix_detected = true
        break
      end

      if trace_result.Fraction > 0.0 then
        if (bump_count == 0 or is_on_ground) and num_bumps > 0 and
            trace_result.Fraction == 1.0 then
          local stuck_trace = trace_player_bbox(
              player_value, trace_result.HitPos, trace_result.HitPos, mins_value,
              maxs_value)
          local trace_is_stuck =
              stuck_trace.StartSolid or not close_enough_float(stuck_trace.Fraction, 1.0)

          if trace_is_stuck and bump_count == 0 then
            has_valid_plane = false
            stuck_on_ramp = true
            fix_detected = true
            break
          end

          if trace_is_stuck then
            velocity = Vector(0, 0, 0)
            should_break = true
            break
          end
        end

        has_valid_plane = false
        stuck_on_ramp = false
        original_velocity = copy_vector(velocity)
        abs_origin = copy_vector(trace_result.HitPos)
        fixed_origin = copy_vector(abs_origin)
        all_fraction = all_fraction + trace_result.Fraction
        num_planes = 0
        planes = {}
      end

      if close_enough_float(trace_result.Fraction, 1.0) then
        should_break = true
        break
      end

      local plane_normal = trace_result.HitNormal or zero_vector_
      if stuck_on_ramp and has_valid_plane then
        plane_normal = valid_plane
      end
      is_on_ground = plane_normal.z >= 0.7

      if plane_normal.z >= 0.7 then
        blocked = bit_bor(blocked, BLOCKED_FLOOR_)
      end
      if close_enough_float(plane_normal.z, 0.0) then
        blocked = bit_bor(blocked, BLOCKED_STEP_)
      end

      time_left = time_left - time_left * trace_result.Fraction
      if num_planes >= MAX_CLIP_PLANES_ then
        velocity = Vector(0, 0, 0)
        should_break = true
        break
      end

      num_planes = num_planes + 1
      planes[num_planes] = copy_vector(plane_normal)

      if num_planes == 1 and move_type == MOVETYPE_WALK and is_on_ground then
        local overbounce = 1.0
        if planes[1].z < 0.7 then
          overbounce = 1.0 + bounce * (1.0 - surface_friction)
        end

        local new_velocity = select(
            1, clip_velocity(original_velocity, planes[1], overbounce))
        velocity = copy_vector(new_velocity)
        original_velocity = copy_vector(new_velocity)
      else
        local found_velocity = false

        for plane_index = 1, num_planes do
          local clipped_velocity = select(
              1, clip_velocity(original_velocity, planes[plane_index], 1.0))
          local intersects_all_planes = true

          for inner_plane_index = 1, num_planes do
            if inner_plane_index ~= plane_index and
                clipped_velocity:Dot(planes[inner_plane_index]) < 0.0 then
              intersects_all_planes = false
              break
            end
          end

          if intersects_all_planes then
            velocity = clipped_velocity
            found_velocity = true
            break
          end
        end

        if not found_velocity then
          if num_planes ~= 2 then
            velocity = Vector(0, 0, 0)
            should_break = true
            break
          end

          if close_enough_vector(planes[1], planes[2]) then
            local boosted_velocity = original_velocity + planes[1] * 20.0
            velocity = Vector(boosted_velocity.x, boosted_velocity.y, velocity.z)
            should_break = true
            break
          end

          local direction = planes[1]:Cross(planes[2])
          if direction:LengthSqr() == 0.0 then
            velocity = Vector(0, 0, 0)
            should_break = true
            break
          end

          direction:Normalize()
          local projected_speed = velocity:Dot(direction)
          velocity = direction * projected_speed
        end

        if velocity:Dot(primal_velocity) <= 0.0 then
          velocity = Vector(0, 0, 0)
          should_break = true
          break
        end
      end
    until true

    if should_break then
      break
    end
  end

  if close_enough_float(all_fraction, 0.0) then
    velocity = Vector(0, 0, 0)
  end

  return abs_origin, velocity, blocked, fix_detected
end

hook.Add("Move", "momsurffix_capture_move_state", function(player_value, move_data)
  if not should_process_player(player_value) then
    move_state_by_player_[player_value] = nil
    velocity_history_by_player_[player_value] = nil
    last_history_tick_by_player_[player_value] = nil
    return
  end

  local mins_value, maxs_value = get_player_hull(player_value, move_data)
  move_state_by_player_[player_value] = {
    origin = copy_vector(move_data:GetOrigin()),
    velocity = copy_vector(move_data:GetVelocity()),
    on_ground = IsValid(player_value:GetGroundEntity()),
    move_type = player_value:GetMoveType(),
    surface_friction = get_surface_friction(player_value),
    mins = copy_vector(mins_value),
    maxs = copy_vector(maxs_value),
    frame_time = FrameTime()
  }
end)

hook.Add(
    "SetupMove",
    "momsurffix_capture_velocity_history",
    function(player_value, move_data, command_data)
      if not should_process_player(player_value) then
        move_state_by_player_[player_value] = nil
        velocity_history_by_player_[player_value] = nil
        last_history_tick_by_player_[player_value] = nil
        return
      end

      local history_tick = engine.TickCount()
      if command_data and command_data.CommandNumber then
        local command_number = command_data:CommandNumber()
        if command_number > 0 then
          history_tick = command_number
        end
      end

      if last_history_tick_by_player_[player_value] == history_tick then
        return
      end

      push_velocity_history(player_value, move_data:GetVelocity())
      last_history_tick_by_player_[player_value] = history_tick
    end)

hook.Add("FinishMove", "momsurffix_apply_move_fix", function(player_value, move_data)
  local move_state = move_state_by_player_[player_value]
  move_state_by_player_[player_value] = nil

  if not move_state then
    return
  end

  if not should_process_player(player_value) then
    return
  end

  local start_velocity = resolve_start_velocity(move_data, move_state.velocity)
  local fixed_origin, fixed_velocity, _, fix_detected =
      try_player_move(player_value, move_state, start_velocity)
  local current_origin = move_data:GetOrigin()
  local current_velocity = move_data:GetVelocity()

  if not fix_detected then
    local restore_velocity =
        get_restore_velocity_from_history(player_value, start_velocity)
    local current_speed = current_velocity:Length()
    local restore_speed = restore_velocity:Length()
    local speed_drop_ratio = 1.0
    if restore_speed > 0.0 then
      speed_drop_ratio = current_speed / restore_speed
    end

    if current_speed <= LOW_SPEED_RESTORE_THRESHOLD_ and
        restore_speed > LOW_SPEED_RESTORE_THRESHOLD_ and
        speed_drop_ratio <= FALLBACK_SPEED_DROP_RATIO_ and
        is_ramp_transition_context(
            player_value, current_origin, move_state.mins, move_state.maxs,
            restore_velocity) then
      fixed_origin = copy_vector(current_origin)
      fixed_velocity = restore_velocity
      fix_detected = true
    end
  end

  if not fix_detected then
    return
  end

  local fixed_speed = fixed_velocity:Length()

  local restore_velocity =
  get_restore_velocity_from_history(player_value, start_velocity)

  
  local restore_speed = restore_velocity:Length()

  print(fixed_speed)

  if fixed_speed < restore_speed then
    if restore_speed > LOW_SPEED_RESTORE_THRESHOLD_ then
      fixed_velocity = restore_velocity
    end
  end

  if current_origin:DistToSqr(fixed_origin) <= FLT_EPSILON_ and
      current_velocity:DistToSqr(fixed_velocity) <= FLT_EPSILON_ then
    return
  end

  move_data:SetOrigin(fixed_origin)
  move_data:SetVelocity(fixed_velocity)
  if move_data.SetFinalIdealVelocity then
    move_data:SetFinalIdealVelocity(fixed_velocity)
  end
end)

hook.Add("PlayerDisconnected", "momsurffix_clear_state", function(player_value)
  move_state_by_player_[player_value] = nil
  velocity_history_by_player_[player_value] = nil
  last_history_tick_by_player_[player_value] = nil
end)
