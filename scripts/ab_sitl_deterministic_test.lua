-- Deterministic SITL test script for comparing controller behaviour between firmware versions.
-- Arms in QLOITER, climbs to 10m via RC throttle override, applies force/torque disturbances,
-- then disarms. Stays in VTOL the entire time (no FW transition).
--
-- Usage:
--   ./build/sitl/bin/arduplane --model quadplane-copter_tailsitter \
--       --defaults Tools/autotest/default_params/quadplane.parm,\
--       Tools/autotest/default_params/quadplane-copter_tailsitter.parm,\
--       scripts/ab_sitl_test.parm \
--       --speedup 10 --serial0 udpclient:127.0.0.1:14550
--
--   Place this script in the scripts/ directory so it auto-loads.

local LOOP_INTERVAL_MS = 500
local GCS_INFO = 6

-- Plane mode numbers
local MODE_MANUAL  = 0
local MODE_QLOITER = 19
local MODE_QLAND   = 20

-- State machine
local STATE_WAIT_INIT     = 0
local STATE_SET_PARAMS    = 1
local STATE_WAIT_EKF      = 2
local STATE_SET_QLOITER   = 3
local STATE_ARM           = 4
local STATE_CLIMB         = 5
local STATE_STABILIZE     = 6
local STATE_APPLY_SHOVE   = 7
local STATE_WAIT_SHOVE    = 8
local STATE_APPLY_TWIST   = 9
local STATE_WAIT_TWIST    = 10
local STATE_LAND          = 11
local STATE_DONE          = 12

local state = STATE_WAIT_INIT
local ekf_wait_start = 0
local arm_attempts = 0
local state_timer = 0

-- Target altitude and RC throttle values
local TARGET_ALT = 10.0   -- meters AGL
local RC3_CLIMB = 1650    -- above mid-stick = climb
local RC3_HOLD  = 1500    -- mid-stick = hold altitude
local RC3_IDLE  = 1000    -- minimum throttle (idle)

-- Disturbance parameters
local SHOVE_ACCEL_X = 20.0    -- m/s/s body-frame lateral push in the X axis
local SHOVE_ACCEL_Y = 20.0    -- m/s/s body-frame lateral push in the Y axis
local SHOVE_ACCEL_Z = 2.0    -- m/s/s body-frame lateral push in the Z axis
local SHOVE_DURATION = 1000  -- ms
local TWIST_ACCEL_X = 5.0    -- rad/s/s yaw torque about the X axis
local TWIST_ACCEL_Y = 1.0    -- rad/s/s yaw torque about the Y axis
local TWIST_ACCEL_Z = 1.0    -- rad/s/s yaw torque about the Z axis
local TWIST_DURATION = 1000  -- ms
local STABILIZE_TIME = 10000 -- ms to let QLOITER settle at altitude
local RECOVERY_TIME = 10000 -- ms to observe recovery after disturbance

local function set_test_params()
    -- Disable arming checks for automated SITL testing
    param:set_and_save("ARMING_CHECK", 0)

    -- Disable radio failsafe (no RC input in headless SITL)
    param:set_and_save("FS_SHORT_ACTN", 0)
    param:set_and_save("FS_LONG_ACTN", 0)
    param:set_and_save("THR_FAILSAFE", 0)

    -- Do not log while disarmed
    param:set_and_save("LOG_DISARMED", 0)

    -- Disable all sensor noise sources for determinism
    param:set_and_save("SIM_GYR1_RND", 0)
    param:set_and_save("SIM_GYR2_RND", 0)
    param:set_and_save("SIM_ACC1_RND", 0)
    param:set_and_save("SIM_ACC2_RND", 0)
    param:set_and_save("SIM_GPS_NOISE", 0)
    param:set_and_save("SIM_GPS2_NOISE", 0)
    param:set_and_save("SIM_VIB_FREQ_X", 0)
    param:set_and_save("SIM_VIB_FREQ_Y", 0)
    param:set_and_save("SIM_VIB_FREQ_Z", 0)
    param:set_and_save("SIM_VIB_MOT_MAX", 0)
    param:set_and_save("SIM_WIND_SPD", 0)
    param:set_and_save("SIM_WIND_TURB", 0)

    -- Clear any previous shove/twist
    param:set_and_save("SIM_SHOVE_TIME", 0)
    param:set_and_save("SIM_TWIST_TIME", 0)

    gcs:send_text(GCS_INFO, "AB_TEST: params set")
end

local function get_alt()
    local pos = ahrs:get_relative_position_NED_home()
    if pos then
        return -pos:z()
    end
    return -1
end

function update()
    if state == STATE_WAIT_INIT then
        if ahrs:initialised() and ahrs:home_is_set() then
            gcs:send_text(GCS_INFO, "AB_TEST: AHRS init, home set")
            state = STATE_SET_PARAMS
        end

    elseif state == STATE_SET_PARAMS then
        set_test_params()
        ekf_wait_start = millis()
        state = STATE_WAIT_EKF

    elseif state == STATE_WAIT_EKF then
        local elapsed = millis() - ekf_wait_start
        if elapsed > 10000 then
            if ahrs:healthy() and gps:status(0) >= 3 then
                gcs:send_text(GCS_INFO, "AB_TEST: EKF converged, ready")
                state = STATE_SET_QLOITER
            else
                gcs:send_text(GCS_INFO, "AB_TEST: waiting for EKF/GPS...")
                ekf_wait_start = millis()
            end
        end

    elseif state == STATE_SET_QLOITER then
        -- Set RC3 to idle first so throttle_wait works correctly on mode entry
        local ch3 = rc:get_channel(3)
        ch3:set_override(RC3_IDLE)
        if vehicle:set_mode(MODE_QLOITER) then
            gcs:send_text(GCS_INFO, "AB_TEST: QLOITER mode set")
            state = STATE_ARM
        end

    elseif state == STATE_ARM then
        arm_attempts = arm_attempts + 1
        if arming:arm() then
            if arming:is_armed() then
                gcs:send_text(GCS_INFO, "AB_TEST: armed in QLOITER")
                -- Now raise throttle to climb
                local ch3 = rc:get_channel(3)
                ch3:set_override(RC3_CLIMB)
                state = STATE_CLIMB
            else
                gcs:send_text(GCS_INFO, "AB_TEST: arm() returned true but not armed")
            end
        else
            gcs:send_text(GCS_INFO, string.format("AB_TEST: arm failed (attempt %d)", arm_attempts))
            if arm_attempts > 20 then
                gcs:send_text(GCS_INFO, "AB_TEST: giving up on arming")
                state = STATE_DONE
            end
        end

    elseif state == STATE_CLIMB then
        -- Keep RC3 at climb value and wait for target altitude
        local ch3 = rc:get_channel(3)
        ch3:set_override(RC3_CLIMB)
        local alt = get_alt()
        gcs:send_text(GCS_INFO, string.format("AB_TEST: climbing alt=%.1fm", alt))
        if alt >= TARGET_ALT then
            -- Switch to hold altitude
            ch3:set_override(RC3_HOLD)
            gcs:send_text(GCS_INFO, string.format("AB_TEST: reached %.1fm, holding", alt))
            state_timer = millis()
            state = STATE_STABILIZE
        end

    elseif state == STATE_STABILIZE then
        -- Keep RC3 at hold and wait for altitude to settle
        local ch3 = rc:get_channel(3)
        ch3:set_override(RC3_HOLD)
        local elapsed = millis() - state_timer
        if elapsed > STABILIZE_TIME then
            local alt = get_alt()
            gcs:send_text(GCS_INFO, string.format("AB_TEST: stable at alt=%.1fm, applying shove", alt))
            state = STATE_APPLY_SHOVE
        end

    elseif state == STATE_APPLY_SHOVE then
        -- Keep RC3 override active
        local ch3 = rc:get_channel(3)
        ch3:set_override(RC3_HOLD)
        -- Apply a lateral body-frame push (Y axis = sideways in copter frame)
        param:set_and_save("SIM_SHOVE_X", SHOVE_ACCEL_X)
        param:set_and_save("SIM_SHOVE_Y", SHOVE_ACCEL_Y)
        param:set_and_save("SIM_SHOVE_Z", SHOVE_ACCEL_Z)
        param:set_and_save("SIM_SHOVE_TIME", SHOVE_DURATION)
        gcs:send_text(GCS_INFO, string.format("AB_TEST: SHOVE; [%.1f %.1f %.1f] m/s/s; %d ms",
                                              SHOVE_ACCEL_X, SHOVE_ACCEL_Y, SHOVE_ACCEL_Z, SHOVE_DURATION))
        state_timer = millis()
        state = STATE_WAIT_SHOVE

    elseif state == STATE_WAIT_SHOVE then
        local ch3 = rc:get_channel(3)
        ch3:set_override(RC3_HOLD)
        local elapsed = millis() - state_timer
        if elapsed > SHOVE_DURATION + 3000 then
            local alt = get_alt()
            gcs:send_text(GCS_INFO, string.format("AB_TEST: post-shove alt=%.1fm, applying twist", alt))
            state = STATE_APPLY_TWIST
        end

    elseif state == STATE_APPLY_TWIST then
        local ch3 = rc:get_channel(3)
        ch3:set_override(RC3_HOLD)
        -- Apply a yaw torque (Z axis rotation in copter frame)
        param:set_and_save("SIM_TWIST_X", TWIST_ACCEL_X)
        param:set_and_save("SIM_TWIST_Y", TWIST_ACCEL_Y)
        param:set_and_save("SIM_TWIST_Z", TWIST_ACCEL_Z)
        param:set_and_save("SIM_TWIST_TIME", TWIST_DURATION)
        gcs:send_text(GCS_INFO, string.format("AB_TEST: TWIST; [%.1f %.1f %.1f] rad/s/s; %d ms",
                                              TWIST_ACCEL_X, TWIST_ACCEL_Y, TWIST_ACCEL_Z, TWIST_DURATION))
        state_timer = millis()
        state = STATE_WAIT_TWIST

    elseif state == STATE_WAIT_TWIST then
        local ch3 = rc:get_channel(3)
        ch3:set_override(RC3_HOLD)
        local elapsed = millis() - state_timer
        if elapsed > TWIST_DURATION + RECOVERY_TIME then
            local alt = get_alt()
            gcs:send_text(GCS_INFO, string.format("AB_TEST: recovery complete, alt=%.1fm", alt))
            state = STATE_LAND
        end

    elseif state == STATE_LAND then
        -- Switch to QLAND for autonomous controlled descent and auto-disarm on touchdown.
        -- Don't refresh RC3 override here; it will expire after RC_OVERRIDE_TIME (3s)
        -- and QLAND ignores pilot throttle anyway.
        if vehicle:set_mode(MODE_QLAND) then
            gcs:send_text(GCS_INFO, "AB_TEST: QLAND mode set, descending")
            state_timer = millis()
            state = STATE_DONE
        end

    elseif state == STATE_DONE then
        -- Wait for QLAND to auto-disarm on touchdown, then stop the script.
        if not arming:is_armed() then
            gcs:send_text(GCS_INFO, "AB_TEST: landed and disarmed, test complete")
            return -- stop scheduling
        end
        local elapsed = millis() - state_timer
        if elapsed > 60000 then
            gcs:send_text(GCS_INFO, "AB_TEST: QLAND timeout, stopping")
            return -- stop scheduling
        end
    end

    return update, LOOP_INTERVAL_MS
end

gcs:send_text(GCS_INFO, "AB_TEST: script loaded")
return update, 3000 -- 3s initial delay for boot
