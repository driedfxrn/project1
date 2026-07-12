-- Packets.lua
-- ByteNet packet definitions for the Laser Ray weapon.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ByteNet = require(ReplicatedStorage.Packages.bytenet)

return ByteNet.defineNamespace("LaserRay", function()
	return {
		FireLaser = ByteNet.definePacket({
			value = ByteNet.struct({
				Origin = ByteNet.vec3,
				Target = ByteNet.vec3,
				PreviousTarget = ByteNet.vec3,
			}),
			reliabilityType = "unreliable",
		}),
	}
end)
