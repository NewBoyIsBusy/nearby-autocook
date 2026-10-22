-- Optional native-engine measurement. This temporary carrot is reference test
-- instrumentation only; the shipped transfer FX never creates an inventory item.
return function()
    local flight = require("nac_flight")
    local fx_api = require("nac_fx")
    local item = SpawnPrefab("carrot")
    -- The headless smoke world has no player to keep this distant entity awake.
    -- Keep native inventory Physics and complexprojectile integration unchanged;
    -- only disable entity sleeping so every simulation update is measured.
    item.entity:SetCanSleep(false)
    item.persists = false
    item.Transform:SetPosition(1000, 0, 1000)
    item:AddComponent("complexprojectile")
    local p = item.components.complexprojectile
    local distance, gravity, height = 8, 25, 6.5
    local speed = math.sqrt((gravity * distance * distance + 16 * gravity * height * height) / (8 * height)) * 1.1
    p:SetHorizontalSpeed(speed)
    p:SetLaunchOffset({x=0,y=3.2,z=0})
    p:SetTargetOffset({y=3.2})
    p:SetGravity(-gravity)
    local duration, arc = flight.Calculate(distance * distance, 0)
    -- Run the production network FX two units beside the real ingredient. Both
    -- use native Physics in the same simulation frames, with no nearby obstacles.
    local fx = assert(fx_api.Play(item, Vector3(1000,0,1002), Vector3(1008,0,1002)))
    local peak, fxpeak, maxdeviation, frames, compared = 0, 0, 0, 0, 0
    p:SetOnUpdate(function()
        local x,y = item.Transform:GetWorldPosition()
        local t = (x-1000) / distance
        local ideal = 3.2 + 4*t*(1-t)*arc
        peak=math.max(peak,y)
        frames=frames+1
        local fxy=-1
        if fx:IsValid() then
            local _, actual_y=fx.Transform:GetWorldPosition()
            fxy=actual_y
            fxpeak=math.max(fxpeak,fxy)
            maxdeviation=math.max(maxdeviation,math.abs(y-fxy))
            compared=compared+1
        end
        if frames <= 3 or frames % 8 == 0 then
            print(string.format("AUTOCOOK_REFERENCE_FLIGHT_SAMPLE frame=%d x=%.6f reference_y=%.6f fx_y=%.6f ideal_y=%.6f vy=%.6f",
                frames,x-1000,y,fxy,ideal,p.velocity.y))
        end
        if p.velocity.y < 0 and y <= 3.2 then p:Hit(); return true end
        return false
    end)
    p:SetOnHit(function()
        local x,y=item.Transform:GetWorldPosition()
        local passed=compared >= 20 and maxdeviation <= .02 and math.abs(peak-fxpeak) <= .02
        print(string.format("AUTOCOOK_REFERENCE_FLIGHT_RESULT passed=%s reference_peak=%.6f fx_peak=%.6f ideal_peak=%.6f maxdeviation=%.6f duration=%.6f frames=%d compared=%d endx=%.6f endy=%.6f",
            tostring(passed),peak,fxpeak,3.2+arc,maxdeviation,duration,frames,compared,x-1000,y))
        if not passed then print("AUTOCOOK_REFERENCE_FLIGHT_FAILURE native FX did not match the reference ingredient") end
        item:Remove()
    end)
    p:Launch(Vector3(1008,0,1000),item,item)
    item:DoTaskInTime(4,function()
        if item:IsValid() then
            local x,y=item.Transform:GetWorldPosition()
            print(string.format("AUTOCOOK_REFERENCE_FLIGHT_FAILURE timed out frames=%d endx=%.6f endy=%.6f",
                frames,x-1000,y))
            item:Remove()
            if fx:IsValid() then fx:Remove() end
        end
    end)
end
