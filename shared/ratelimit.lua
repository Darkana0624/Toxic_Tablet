---Per-key token buckets that refill lazily on access (no timers).
---A bucket holds `perMinute` tokens and refills at perMinute/60 per second.

local ratelimit = {}
ratelimit.__index = ratelimit

---@param clock fun(): number  seconds, monotonic (os.clock / GetGameTimer()/1000)
---@return table
function ratelimit.new(clock)
    return setmetatable({ clock = clock, buckets = {} }, ratelimit)
end

---Takes one token. Returns false when the bucket is empty.
---@param key string
---@param perMinute integer
---@return boolean allowed
---@return number overflow  how many times the limit was exceeded in the current window
function ratelimit:take(key, perMinute)
    local now = self.clock()
    local bucket = self.buckets[key]

    if not bucket then
        bucket = { tokens = perMinute, stamp = now, over = 0 }
        self.buckets[key] = bucket
    else
        local refill = (now - bucket.stamp) * perMinute / 60
        if refill > 0 then
            bucket.tokens = math.min(perMinute, bucket.tokens + refill)
            bucket.stamp = now
            if bucket.tokens >= perMinute then bucket.over = 0 end
        end
    end

    if bucket.tokens >= 1 then
        bucket.tokens = bucket.tokens - 1
        return true, bucket.over
    end

    bucket.over = bucket.over + 1
    return false, bucket.over
end

---Forgets every bucket whose key starts with `prefix` (a player who left).
---@param prefix string
function ratelimit:forget(prefix)
    for key in pairs(self.buckets) do
        if key:sub(1, #prefix) == prefix then self.buckets[key] = nil end
    end
end

return ratelimit
