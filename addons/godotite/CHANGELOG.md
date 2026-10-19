# Changelog

Notable changes to Godotite, newest first. Versions follow [semantic versioning](https://semver.org):
before 1.0, a minor version may change the DAG format, settings or API.

## 0.9.0 (2026-10-19)

The first public release.

- **Building:** a `GodotiteBuilder` node (Regenerate) or the scene importer (Build Lod) builds any
  Mesh into a hierarchy of clusters, in C#, deterministically, on every core; meshes over 4 million
  triangles build in cells to bound memory. Materials, UVs, normals, tangents, vertex colors and
  custom channels carry over; separate pieces and non-manifold edges are handled.
- **Drawing:** a `GodotiteLOD` node draws the coarsest clusters that keep the error under a pixel
  threshold, crack-free, through RenderingServer instances, in GDScript: games need no .NET.
- **Quality:** one project-wide error threshold (Project Settings, Godotite > LOD), changeable at
  runtime with `GodotiteLOD.set_global_error_threshold()`, with per-node overrides and an optional
  draw call budget.
- **DAG files:** saved in a project DAG folder and referred to by UID, so moving files breaks
  nothing and a missing file is a warning, not a broken scene; Project > Tools > Godotite: Rebuild
  Missing DAGs and Find Unused DAGs.
- **Exporting:** DAG files exported scenes use are added and their debug data stripped.
- **Checking:** Validate DAG and Measure Error on every `GodotiteLOD`; debug materials showing
  clusters, levels and error.
- **Demo:** `addons/godotite/demo/godotite_demo.tscn`, a generated terrain with a fly camera and an
  overlay of what is drawn.
- Requires Godot 4.5 or later; building needs the .NET version of Godot.
