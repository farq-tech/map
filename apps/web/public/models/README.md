Your car on the Sary map is a real 3D model drawn by Mapbox (`model` layer):
`src/lib/sary/suvModel.ts` builds a low-poly 4×4 as a glTF binary in the browser,
in the body colour chosen in the profile, and `src/lib/sary/vehicleLayer.ts` puts
it on the map — no background, lit by the map, on the terrain.

The earlier Prado PNG poses carried their own square of sand and were retired.
A licensed `.glb` can replace the generated one by pointing `addModel` at it.
