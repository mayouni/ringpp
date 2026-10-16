-- The string workload, for Lua 5.4 and Luau. Kernels transcribed from
-- strings.ring so all four runtimes do the same work.
--
--     lua strings.lua [reps]
--
-- Note on fairness: the inner loop uses a boolean flag where the spike's
-- bytecode jumps directly past the counter. That is one extra boolean store
-- per candidate position (~1M) against ~2M byte comparisons, and Lua has no
-- cheaper spelling without `goto`, which Luau does not accept. Stated rather
-- than hidden.
local reps = tonumber(...) or 3

local function flen(s) return #s end

local function strpass(s, n)
    local total = 0
    for _ = 1, n do total = total + flen(s) end
    return total
end

local function strfind(s, pat)
    local n, m = #s, #pat
    local count = 0
    local lim = n - m + 1
    local byte = string.byte
    for i = 1, lim do
        local hit = true
        for j = 1, m do
            if byte(s, i + j - 1) ~= byte(pat, j) then hit = false; break end
        end
        if hit then count = count + 1 end
    end
    return count
end

local big = string.rep("the quick brown fox ", 50000) -- 1,000,000 bytes
local pat = "fox"

local function bench(name, fn, expect)
    local best
    for _ = 1, reps do
        local t0 = os.clock()
        local v = fn()
        local ms = (os.clock() - t0) * 1000
        if not best or ms < best then best = ms end
        if v ~= expect then error(name .. " CHECK MISMATCH: " .. tostring(v)) end
    end
    local h = math.floor(best * 1000 + 0.5)
    print(string.format("CHECK %s %d", name, expect))
    print(string.format("TIME  %s %d.%03d", name, math.floor(h / 1000), h % 1000))
end

print("string workload")
print("==============================================")
print("")

bench("strpass", function() return strpass(big, 2000) end, 2000000000)
bench("strfind", function() return strfind(big, pat) end, 50000)

print("")
print("SUITE OK")
