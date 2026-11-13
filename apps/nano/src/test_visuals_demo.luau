local capacity = 60
local efficient = true
local saved = 0
return function()
    local rate = if efficient then 0.72 else 1
    local cost = math.floor(capacity * 24 * rate)
    return ui.column {
        ui.text("Synthetic estimates · explore a local capacity plan."),
        ui.row {
            ui.stat { label = "Monthly estimate", value = "$" .. cost },
            ui.stat { label = "Capacity", value = capacity .. " units" },
        },
        ui.chart {
            label = "Projected monthly cost · USD",
            values = { math.floor(cost * 0.66), math.floor(cost * 0.82), cost, math.floor(cost * 1.15) },
            labels = { "Current", "Week 1", "Week 2", "Week 3" },
        },
        ui.slider { label = "Capacity", value = capacity, min = 10, max = 100,
            onChange = function(n) capacity = math.floor(n + 0.5) end },
        ui.row {
            ui.toggle { label = "Efficiency mode", value = efficient,
                onChange = function(b) efficient = b end },
            ui.button { label = "Save scenario", onClick = function() saved += 1 end },
            ui.button { label = "Reset", onClick = function() capacity = 60 efficient = true saved = 0 end },
        },
        ui.text("Saved scenarios: " .. saved),
    }
end
