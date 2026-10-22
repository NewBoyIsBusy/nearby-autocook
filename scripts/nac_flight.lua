-- Match CookDiary's native complexprojectile flight tuning.
-- Its 1.1 launch-speed multiplier and DST's default high arc mean that 6.5
-- is a tuning parameter, not the final apex above the launch position.
local M = {
    HEIGHT = 6.5,
    GRAVITY = 25,
    SPEED_MULTIPLIER = 1.1,
    OFFSET_Y = 3.2,
}

function M.Speed(horizontal_distance_squared)
    return math.sqrt(M.GRAVITY * (horizontal_distance_squared + 16 * M.HEIGHT * M.HEIGHT)
        / (8 * M.HEIGHT)) * M.SPEED_MULTIPLIER
end

-- Ideal metadata/timeout only. Actual motion uses the engine's Physics and
-- complexprojectile so its native gravity and fixed-step integration also match.
function M.Calculate(horizontal_distance_squared, height_difference)
    local g = M.GRAVITY
    local dy = height_difference or 0
    local speed = M.Speed(horizontal_distance_squared)
    local speed_squared = speed * speed
    -- A distant elevated modded container may need more speed than the normal
    -- equal-height recipe. Keep that visual reachable instead of producing NaN.
    local minimum_speed_squared = g * (dy + math.sqrt(horizontal_distance_squared + dy * dy))
    speed_squared = math.max(speed_squared, minimum_speed_squared)
    local discriminant = math.max(0,
        speed_squared * speed_squared - 2 * g * dy * speed_squared
        - g * g * horizontal_distance_squared)
    -- Solve the larger flight-time root (DST complexprojectile's high arc).
    -- This form also works for a perfectly vertical flight without division by 0.
    local duration = math.sqrt(2 * (speed_squared - g * dy + math.sqrt(discriminant))) / g
    return duration, g * duration * duration / 8
end

return M
