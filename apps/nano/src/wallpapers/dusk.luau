-- Original procedural artwork: no downloaded images, shaders, or timer.
return function(c)
    local w, h = c.width, c.height
    local dx, dy = c.pointer_x - .5, c.pointer_y - .5
    local calm = c.reduced_motion
    local function drift(depth)
        return ui.spring { x = if calm then 0 else -dx * 22 * depth,
            y = if calm then 0 else -dy * 12 * depth, stiffness = 140, damping = 20 }
    end
    return ui.layer { id = "dusk", width = w, height = h, children = {
        ui.rect { id = "sky", width = w, height = h, color = if c.dark then 0x30304d else 0xd9d4ed },
        ui.rect { id = "moon", x = w*.76, y = h*.12, width = 76, height = 76,
            radius = 38, color = if c.dark then 0xe4ceb1 else 0xfff1cf, opacity = .65, motion = drift(.2) },
        ui.rect { id = "far", x = -w*.22, y = h*.43, width = w*1.1, height = h*1.4,
            radius = w*.44, color = if c.dark then 0x656088 else 0xb7afce, motion = drift(.6) },
        ui.rect { id = "middle", x = w*.43, y = h*.54, width = w, height = h*1.2,
            radius = w*.35, color = if c.dark then 0x494766 else 0x979ab7, motion = drift(1) },
        ui.rect { id = "near", x = -w*.12, y = h*.77, width = w*1.3, height = h*1.2,
            radius = w*.38, color = if c.dark then 0x353b51 else 0x818da8, motion = drift(1.5) },
    } }
end
