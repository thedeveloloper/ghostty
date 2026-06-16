// Full-screen triangle, mirroring shaders/glsl/full_screen.v.glsl. A single
// oversized triangle is clipped to the viewport.
//
//   X <- vid == 0: (-1, -3)
//   |\
//   | \
//   |##\
//   |#+#\   `+` is (0, 0). `#`s are the viewport area.
//   X----X <- vid == 2: (3, 1)
//   ^ vid == 1: (-1, 1)
float4 main(uint vid : SV_VertexID) : SV_Position {
    float4 position;
    position.x = (vid == 2) ? 3.0 : -1.0;
    position.y = (vid == 0) ? -3.0 : 1.0;
    position.z = 1.0;
    position.w = 1.0;
    return position;
}
