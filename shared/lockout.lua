---Passcode lockout policy (pure). Attempts are stored on the device row.
---
---failed_attempts counts consecutive failures. The first `maxAttempts`
---failures are free; failure maxAttempts + k locks the device for steps[k]
---seconds (the last step repeats).

local lockout = {}

---@param failedAttempts integer   consecutive failures so far (after this one)
---@param maxAttempts integer
---@param steps integer[]
---@return integer seconds  0 = not locked
function lockout.seconds(failedAttempts, maxAttempts, steps)
    if failedAttempts < maxAttempts then return 0 end
    local index = failedAttempts - maxAttempts + 1
    return steps[math.min(index, #steps)] or 0
end

---@param lockedUntil integer?  unix seconds
---@param now integer           unix seconds
---@return integer remaining    seconds left, 0 when unlocked
function lockout.remaining(lockedUntil, now)
    if not lockedUntil or lockedUntil <= now then return 0 end
    return lockedUntil - now
end

return lockout
