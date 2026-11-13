-- Original procedural artwork. Geometry is inert; NanoUI owns the springs.
return function(c)
    local w, h = c.width, c.height
    local function drift(depth)
        return ui.spring { x = if c.reduced_motion then 0 else (.5-c.pointer_x)*22*depth,
            y = if c.reduced_motion then 0 else (.5-c.pointer_y)*12*depth, stiffness = 140, damping = 20 }
    end
    return ui.layer { id = "dunes", width = w, height = h, children = {
        ui.rect { id = "sky", width = w, height = h, color = if c.dark then 0x494038 else 0xf3dfc3 },
        ui.rect { id = "sun", x = w*.71, y = h*.13, width = 92, height = 92,
            radius = 46, color = if c.dark then 0xdbb476 else 0xe9ad61, opacity = .6, motion = drift(.15) },
        ui.rect { id = "far", x = w*.15, y = h*.42, width = w*1.2, height = h*1.7,
            radius = w*.47, color = if c.dark then 0x8f7055 else 0xdeb684, motion = drift(.5) },
        ui.rect { id = "middle", x = -w*.42, y = h*.56, width = w*1.3, height = h*1.6,
            radius = w*.5, color = if c.dark then 0x75503c else 0xc3926c, motion = drift(.9) },
        ui.rect { id = "near", x = w*.22, y = h*.74, width = w*1.3, height = h*1.6,
            radius = w*.45, color = if c.dark then 0x523e34 else 0xa37c66, motion = drift(1.5) },
    } }
end
