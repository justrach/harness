-- A stateful, native dashboard. The host chooses layout, typography and colors.
local iterations = 3
local compare = false
local target = 8

return function()
    return ui.column{
        ui.text('Design review'),
        ui.row{
            ui.stat{label='Iterations', value=tostring(iterations)},
            ui.stat{label='Target', value=tostring(target)},
        },
        ui.chart{label='Feedback resolved', values={2, 5, iterations + 4}, labels={'Mon', 'Tue', 'Wed'}},
        ui.button{label='Add iteration', onClick=function() iterations += 1 end},
        ui.toggle{label='Compare variants', value=compare, onChange=function(value) compare = value end},
        ui.slider{label='Target iterations', value=target, min=1, max=20, onChange=function(value) target = value end},
        ui.rule{},
        ui.text{text=compare and 'Comparison enabled' or 'Single variant'},
    }
end
