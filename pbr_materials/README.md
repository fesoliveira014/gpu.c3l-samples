# pbr_materials

A 7×7 grid of spheres rendered in **one instanced draw**, each picking its
material from a GPU material table by index — the material-table pattern the
root-pointer + bindless design exists for. Roughness sweeps 0.05→1.0 across
columns, metallic 0→1 up the rows.

![pbr_materials](screenshots/pbr_materials.png)

## Material table

```
instance table (SSBO)          material table (SSBO)         descriptor heap
┌──────────────────────┐      ┌───────────────────────┐     ┌──────────────┐
│ pos_scale            │      │ base_color            │     │ albedo_white │
│ material ────────────┼─────▶│ roughness, metallic   │     │ albedo_check │
└──────────────────────┘      │ albedo_tex ───────────┼────▶│      ...     │
  × 49, gl_InstanceIndex      └───────────────────────┘     └──────────────┘
                                × 49, fetched per pixel
```

- The schema declares `type MaterialIndex : uint;` — the first user semantic
  type in a sample; it flows through the generator into both the C3 twin
  (`typedef MaterialIndex = uint;`) and the GLSL include.
- `SphereInstance` and `Material` are declared in the `.abi` schema, so the
  CPU writes the tables through the generated C3 structs and the shaders read
  them through the generated GLSL structs — one layout, two languages.
- Each material carries an albedo `TextureIndex` resolved through the heap
  per pixel; every third material uses a checker to make the indirection
  visible.

## Shading

GGX-lite Cook-Torrance: GGX NDF + Schlick fresnel, with the Kelemen
`1/(4·vdh²)` visibility approximation standing in for full Smith. Two fixed
directional lights plus a split ambient — Lambertian for dielectrics, an
f0-tinted constant for metals (stand-in for the missing IBL, keeps the
metallic rows readable). Reinhard + gamma encode at the end; the swapchain
is UNORM, so the clear color is pre-encoded.

## Mesh

CPU-generated non-indexed UV sphere (32×24), two vec4s per vertex with UV
packed into the w components. UVs come from the grid indices rather than
`atan` on the position: u is monotonic (no wrap-seam smear) and pole
vertices keep their column's u (no pole smudge).

## Run

```
c3c build pbr_materials
./build/pbr_materials [--frames N] [--no-vsync] [--screenshot out.png]
```
