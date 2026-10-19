# How Godotite works

A high-level account of the algorithms, for reading before the code. The code comments carry the
detail and the history of why each rule exists; this document carries the shape. Terms in **bold**
on first use are defined in the [glossary](#glossary), and the [code map](#code-map) says where
each piece lives.

---

## The idea in one paragraph

A large mesh is cut into small patches called **clusters**. Clusters are merged a few at a time and
simplified to half their triangle count, repeatedly, until one coarse cluster covers the whole
mesh. The result is not a tree but a **DAG** of clusters at every level of detail. At runtime, each
cluster knows how wrong it is — its **error**, as a distance in model space — and how wrong its
coarser replacement is. Projecting those errors onto the screen, Godotite draws, anywhere on the
mesh, the coarsest clusters whose error is under a pixel threshold. That set is the **cut**. Near
the camera it comes from fine levels, far away from coarse ones, and it is always watertight,
because of how the clusters were built. This is the core of Unreal's Nanite, minus its GPU-driven
rasterizer and streaming.

---

## The pipeline

```
 BUILD (once, at import or Regenerate)                          RUNTIME (every frame)

 source mesh                                                    camera
    │                                                              │
    ▼                                                              ▼
 1 parse & weld ──► 2 error metrics ──► 3 leaf clustering      select a cut
                     (quadrics)             │                      │  (incremental, usually free)
                                            ▼                      ▼
                             4 DAG level loop, repeated:        show / hide one
                               group → merge → lock →           RenderingServer instance
                               simplify → error → split         per cluster
                                            │
                                            ▼
                             5 pack into a GodotiteDAG resource ────────►  loaded by GodotiteLOD
```

The build runs in C# (`native/`), because it is where all the time goes. Runtime selection runs in
GDScript (`godotite_lod.gd`), because it is cheap and has to work without a .NET build. The packed
`GodotiteDAG` resource is the only thing that passes from one to the other.

---

## Build

### 1. Parse and weld

The source `ArrayMesh` is read into flat arrays (`GodotiteMesh.Parse`). Two ideas carry through
everything after it.

**Positions and corners are separate.** Vertices at the same place are **welded** into one
**position**, within `WeldTolerance`, so the mesh becomes one connected surface. What a vertex
carries besides position — normal, tangent, UV, custom channels, material — stays on a **corner**, one per triangle
vertex. Tangents come from the source, or are generated from UVs and normals over the full-detail
mesh at parse time, so every cluster sharing a corner agrees on it and normal maps show no seams at
cluster borders. A
position where corners disagree, such as a UV island edge or a hard normal crease, is a **seam**.
Simplification works on positions, so the topology is correct, and later puts the right corner back
on each triangle (`PickCorner`), so attributes survive.

**The mesh boundary.** An edge used by only one triangle in the whole mesh is a
**mesh boundary edge**: the open outline of the surface, with nothing on the other side. This is
different from a **cluster interface**, where two clusters meet. Most of the rules for keeping the
mesh watertight depend on telling those two apart. The set is not built at parse time: it is
computed at the start of each DAG level, from that level's geometry (see below).

### 2. Error metrics: quadrics

Simplification removes one edge at a time, cheapest first, and the cost of removing an edge is
"how far does the surface move?" Quadrics answer that cheaply.

**The plane quadric.** For a plane with unit normal `n` and offset `d`, the squared distance from a
point `p` is `(n·p + d)²`. Written with `p` as a homogeneous 4-vector `(x, y, z, 1)`, that is
`pᵀ Q p`, where `Q = qqᵀ` and `q = (nx, ny, nz, d)`. `Q` is a symmetric 4×4 matrix, so it has only
**10 distinct coefficients**. That is where the 10 comes from (`BuildBaseQuadrics`).

**Summing is the trick.** Each position is given the sum of the quadrics of every triangle
touching it. The sum of plane quadrics measures the sum of squared distances to all of those planes
at once, still in 10 numbers. So each position stores a summary of "the surface around me" that
can be evaluated anywhere in constant time.

**Evaluating a collapse.** Collapsing edge `(a, b)` so that both ends move to point `v` costs
`vᵀ (Q_a + Q_b) v` (`QuadricErrorAt`): the squared distance from `v` to every plane either end used
to sit on. Godotite only ever moves one endpoint onto the other — a **half-edge collapse** — so `v`
is always `a` or `b`, and the cheaper of the two is used (`CollapseCost`). Never inventing new
positions keeps every vertex of the result a vertex of the source, which is what later makes cluster
boundaries line up exactly.

**The attribute quadric.** Position error alone would let a collapse keep the shape but smear the
texture. Over one triangle, a UV coordinate `s` is a linear function of position: `s = g·p + c`,
with the gradient `g` lying in the triangle's plane. So "how badly does point `p` with coordinate
`s` fit this triangle's mapping" is again the square of a linear expression, this time in four
variables, `(x, y, z, s)`. That is the plane quadric lifted into 4D: a symmetric 5×5 matrix (the
fifth row for the constant), **15 coefficients per UV channel, 30 for U and V together**
(`BuildUvQuadrics`). `UvErrorAt` evaluates it the same way and scales it into distance units, so it
adds to the position cost. `uv_distortion_weight` sets how much it counts.

**Stored as floats, in local frames.** Each position's quadrics are expressed relative to that
position, and the UV quadric also relative to its representative corner's UV. In world coordinates
they would need doubles: evaluating one cancels terms of order R², and on a large world R is
hundreds of meters, with UVs in meters too. Locally every term is on the scale of the neighboring
triangles, so float is enough. Since `vᵀ (Q_a + Q_b) v` is `vᵀ Q_a v + vᵀ Q_b v`, each endpoint's
quadric is evaluated in its own frame and the results added; nothing is ever translated.

**Costs added on top of the quadrics.** None of these is a quadric; each covers something quadrics
cannot see.

- **Seam error** (`ComputeSeamError`, `LostSeamError`) — the cost of erasing a seam, which grows with
  how different its corners are. Charged only for what a collapse actually erases: each of the
  removed position's corners becomes its nearest match of its own material at the kept position,
  and the seam is lost only where two of them become one, or one has no match. Collapsing *along* a
  seam erases nothing; collapsing across to an unrelated seam or onto plain surface erases it.
  Without it, UV island edges would collapse as freely as smooth surface; charged for every collapse
  touching a seam, as it once was, seam curves never coarsened while anything else could.
- **Outline and seam-curve deviation** (`BoundaryDeviationSquared`, `SeamCurves`) — a quadric
  measures distance to planes, so sliding a vertex along its own plane costs nothing. On a mesh
  boundary that silently pulls the outline inward; along a seam it moves the seam's curve across the
  surface (a shoreline sliding over flat water). Collapsing along an outline or a seam curve is
  instead charged by how far the line actually moves. Each direction of an edge is priced whole,
  collapse and deviation together, and the edge is collapsed in the direction it was priced at:
  removing the vertex in a straight run moves the line by nothing, removing the corner at its end
  can delete half a floor.
- **Texel density limit** (`IsCollapseValid`, `uv_density_limit`) — a collapse can keep every UV
  value and still stretch the texture, because it changes a triangle's size in world space and UV
  space by different amounts. A collapse that changes any touched triangle's UV area per world area
  by more than 4× is refused outright.

Costs are squared distances. The **error** a group ends up with is the square root of the most
expensive collapse it accepted: a distance, in model units.

### 3. Leaf clustering

The source triangles are divided into **leaf clusters** of about `min_cluster_triangles` each
(default 4096) by **region growing** (`GodotiteClustering.CreateLeafGroups`). Starting from a seed
triangle, the next triangle taken is always the neighbor that grows the cluster's bounding box
least. Two penalties are added, both scaled to the cluster's current size: one for adding
**boundary edges** (which keeps clusters compact), and one for pulling in a new **material** (which
keeps material borders on cluster borders where it can).

Two special cases:

- **Bridging.** If a cluster runs out of connected neighbors before it is full, it can jump to the
  nearest unassigned triangle within reach. A model made of many small disconnected pieces would
  otherwise produce thousands of tiny clusters.
- **Orphan folding** (`MergeOrphanGroups`). Small leftover groups are folded into a neighbor.

### 4. The DAG level loop

This is the heart of the build (`GodotiteDag.BuildClusterDag`). Each pass takes every cluster at one
level and produces the next, coarser level:

1. **Reclassify the mesh boundary** against the current geometry (`RecomputeMeshBoundaryEdges`).
   Coarsening can create new outline edges, and they have to be recognized as outline, not
   interface.
2. **Group** clusters in fours (`GroupClusters`). Each group grows from a seed
   by adding the neighbor that shares the most edges with it; a neighbor that brings a new
   material is scored down.
3. For each group (`BuildGroup`):
   1. **Merge** its clusters' triangles into one patch.
   2. **Lock** the patch's outer boundary — every edge it shares with a cluster outside the group —
      so the simplifier cannot move it. Open mesh boundary edges are the exception: nothing is on
      the other side, so they may be simplified, at the outline-deviation cost above.
   3. **Drop small components** (`DropSmall`). Disconnected specks too small to matter at this level
      are removed outright, and their size is added to the error.
   4. **Simplify** to half the triangle count (`GodotiteSimplifier.Simplify`): half-edge collapses,
      cheapest first. A candidate is refused if it would move a locked edge, erase a seam onto
      a position without one, flip a face, create a needle, stretch texel density, or join two
      surfaces that only touch at a point (the **link condition**).
   5. **Record error and bounds** — see the next section.
   6. **Re-split** into new clusters (`SplitTriangles`), about `min_cluster_triangles` each, so
      cluster size stays roughly constant from level to level.
4. The new clusters become the next level. The loop ends when one cluster is left: the **root**.

Groups within a level are independent, so step 3 runs in parallel across groups. Anything that
depends on order — baking cluster meshes, numbering, linking parents — happens afterwards on the main
thread, walking the results in group order, so a parallel build is bit-identical to a serial one.

**Why group and re-split, rather than simplify each cluster alone?** A cluster simplified alone has
to keep its whole border locked, or it would pull away from its neighbor. Those borders would then
never simplify, at any level, and would pile up as a mesh of dense seams. Merging a group frees the
borders *inside* the group. Re-splitting then draws new borders in different places, so at the next
level they are group-internal and get simplified in turn. Every edge is interior to some group at
some level, so every edge eventually coarsens.

This is also why larger clusters simplify better: a smaller share of their edges is locked border.

### 5. Error and bounds — what makes the cut well-defined

Each group writes the same three things onto every cluster it produced, and the same **parent**
values onto every cluster that went into it:

- **One error** for the whole group: the larger of its simplification error and its children's
  errors, so error never decreases going up the DAG (it is **monotonic**). It is capped at the
  group's diameter, since a cluster cannot be wronger than its own size.
- **One bounding sphere**, enclosing the group's children as well as its result (`MergeSpheres`),
  so a parent's bounds always contain its children's.
- **An inner radius** (`MeasureShell`), the distance from the sphere's center to the nearest
  geometry. Together with the outer radius it describes a **shell**. This matters for hollow
  geometry — a camera inside a sphere world is inside every cluster's bounding sphere, but still at
  a real distance from each cluster's surface.

The packed resource keeps a copy of the parent's error and bounds on every child, so runtime
selection can make a decision for any cluster without reaching any other.

### 6. Packing: the GodotiteDAG resource

`GodotiteNative.PackDag` flattens the clusters into a `GodotiteDAG` resource (`godotite_dag.gd`),
which is everything a `GodotiteLOD` needs to draw: no build data survives into it. It is a normal
Godot resource, saved by Godot's own resource format, so this describes what it holds, not its
bytes.

**Where it lives.** A builder saves it as a `.res` file of its own, which its `GodotiteLOD` refers
to by UID (`dag_file`); an import keeps it inside the imported scene. Either way a scene stays small:
the geometry is in the DAG.

**Version.** `format_version` is the format the DAG was built in. A build writes the current
`FORMAT_VERSION`; a `GodotiteLOD` draws a DAG from `OLDEST_FORMAT_VERSION` up to it, and refuses
others with a message (`format_problem()`). The current version rises with any change to what the
DAG stores or means, the oldest only when an older DAG can no longer be drawn correctly.

**Per cluster**, in arrays indexed by cluster:

| array | holds |
|---|---|
| `meshes` | the cluster's baked `ArrayMesh` |
| `levels` | 0 for a leaf, counting up to the root |
| `triangle_counts` | its triangles |
| `errors`, `lod_centers`, `lod_radii`, `lod_inner_radii` | its group's error, and the shell bounding it (step 5) |
| `parent_errors`, `parent_centers`, `parent_radii`, `parent_inner_radii` | the same for the group it went into |
| `child_offsets`, `child_counts` into `child_indices` | its children |
| `surface_material_offsets`, `surface_material_counts` into `surface_materials` | the source material of each of its mesh's surfaces |

Two of the lists are stored compactly (CSR): a cluster's children are `child_counts[i]` entries of
`child_indices` from `child_offsets[i]`, and its surfaces' materials likewise.

**For the whole DAG:** `cluster_count`, `root_index`, and `debug_channel` (below).

**What always holds** in a valid DAG, and what the validator checks:

- Clusters are ordered leaves first, by ascending level, so a parent's index is always above its
  children's; the root is the single cluster at the top level.
- The clusters a group produced share one error and one shell; the clusters it consumed carry that
  same error and shell as their parent values. This is what makes a group switch as one.
- Error never decreases from a cluster to its parent (leaves have 0), and a parent's shell contains
  its children's.
- The root has no parent: its parent error is infinite, so it is drawn whenever nothing finer is.
- The leaves together are the source mesh, each triangle in exactly one leaf.

**The cluster meshes.** Each is indexed, with one surface per source material it holds, and carries
the source's normals, UVs, vertex colors and custom channels (CUSTOM0 to 3), and tangents unless
the builder's Include Tangents is off. By default (Compress Vertices) they use Godot's vertex
compression, about 29 bytes per source triangle against 46, in boxes aligned so that a vertex
shared by two clusters decodes alike in both, which is what keeps compression from opening cracks;
each compressed surface has two unused vertices at its box's corners for that. The few coarsest and
the smallest clusters stay uncompressed (`GodotiteCompress.cs` explains why).

**Debug data.** Each cluster mesh also carries, in the highest custom channel the source leaves
free (`debug_channel`, RGBA8), what the debug views show: its source material, a hue for the
cluster, its level, and its error against its size. Exporting a game strips it
(`godotite_export.gd`), 4 bytes per vertex; `debug_channel` is -1 when there is none.

---

## Runtime

### The cut rule

Every frame, a cluster is drawn exactly when

```
projected(own error)  ≤  threshold   <   projected(parent error)
```

— it is detailed enough, and the next level up is not. For a cluster with error `e`, bounded by a
shell of outer radius `R` and inner radius `r`, seen from distance `D` to its center:

```
shell distance    d = max(D − R,  r − D,  small minimum)
projected error     = e / d · scale            scale = viewport height / (2 · tan(fov / 2))
```

`scale` turns a model-space error into pixels (`screen_error_scale`), so `error_threshold` means
pixels on the actual screen, whatever the resolution and field of view — the same threshold draws
finer detail at 4K than at 1080p, because the pixels are smaller. `d` is a lower bound on the distance
to any point of the cluster, so the projected error is never an underestimate.

### Why the cut is always watertight

Take one group at level L, with the set of clusters it consumed (its **children**) and the set it
produced (its **parts**). Every child has the group's error and bounds as its *parent* values, and
every part has them as its *own* values. At the group's boundary the cut rule asks the same
question of both sets — is the group's projected error under the threshold? The children are drawn
when the answer is no, the parts when it is yes. So exactly one of the two sets is drawn: never
both (which would overlap), never neither (which would leave a hole). And the locked boundary means
the parts' outer edge is the children's outer edge, vertex for vertex. So neighbors at different
levels always meet exactly, however the cut mixes levels.

Monotonic error guarantees that every path from the root down to a leaf crosses the threshold
exactly once, so the rule picks exactly one cluster on each path.

### Three ways to select the same cut

All three must produce identical results, and the validator checks that they do.

- **`select_cut`** — walks down from the root, stopping at the first cluster that fits. It is the
  reference.
- **`select_cut_flat`** — tests every cluster against the rule independently. Slow, and a second
  opinion on the descent.
- **`select_cut_incremental`** — updates last frame's cut instead of rebuilding it: a drawn cluster
  that has become too coarse is **refined** into its children, and a whole group whose coarser form
  now fits is **merged** back up. This is what runs every frame.

The incremental selector is nearly free most of the time because of **slack**
(`_decision_slack`): how far the camera can move before a given cluster's decision could possibly
change. Shell distance can change at most as fast as the camera moves, so slack is a hard bound. The
smallest slack in the cut, the **slack floor**, is spent down as the camera moves. Until it runs
out, provably nothing can change, and selection returns immediately. A still camera costs nothing.

### Rendering

Each cluster is one `RenderingServer` instance, created once and shown or hidden as the cut changes
(`_adopt_rendering_server`). There is no scene node per cluster — those are an opt-in debug mode
(`create_debug_nodes`), because thousands of nodes make the editor crawl. Each drawn cluster is a
draw call per material it contains, which is why cluster count, not triangle count, is what limits
runtime cost: larger clusters, fewer draw calls.

In the editor the cut follows the viewport camera (`editor_preview`) at up to 15 updates a second.

---

## Integration

- **Import** — `import_plugin.gd` offers the builder's settings as import options (read from the
  builder by `GodotiteConverter.build_options`) and hands off to `GodotiteConverter.build_lods`,
  which replaces each large-enough `MeshInstance3D` with a `GodotiteLOD`. Meshes under
  `MIN_SOURCE_TRIANGLES` are left alone. The DAG lives in the imported scene, in Godot's import
  cache.
- **In-scene builder** — a `GodotiteBuilder` node with a Regenerate button (`build_dag`). It saves the
  DAG to the project's DAG folder (a project setting), choosing the file once, and hides its source,
  which then holds only its mesh's path until it is shown again.
- **Build orchestration** — `GodotiteBuilder.build_from_mesh` resolves settings, starts the native
  build on a worker thread through `GodotiteNative.StartBuild`, reports its progress and bakes
  finished cluster meshes while polling (`BakeReady`), then bakes the rest and packs the result
  on the main thread. Regenerate uses `build_from_mesh_async`, the same build awaiting frames
  instead of sleeping, so the editor stays responsive. `assemble_lod_node` turns it into a ready
  `GodotiteLOD`.
- **Project tools** — `plugin.gd` registers the importer, the export plugin, the error threshold and
  DAG folder project settings, and Project › Tools › Godotite: Rebuild Missing DAGs and Find Unused
  DAGs, which read the saved scenes through `godotite_project.gd`.
- **Export** — `godotite_export.gd` adds the DAG files exported scenes refer to, strips the debug
  channel, and leaves the demo out.
- **Logging** — `godotite_log.gd` timestamps build progress to the microsecond. An import blocks the
  editor, so its progress can only be followed live on stdout, by launching the editor from a
  terminal.

---

## Glossary

**Attribute quadric** — a quadric in `(x, y, z, s)` measuring how far a point's UV coordinate
strays from the surrounding triangles' texture mapping. 15 coefficients per channel.

**Bridging** — letting a leaf cluster jump to a nearby triangle it isn't connected to, so meshes
made of many small pieces don't fragment into tiny clusters.

**Children** — the clusters a group consumed. All of a group's children switch together at runtime.

**Cluster** — a patch of triangles that is drawn or hidden as a unit. One `RenderingServer`
instance, one baked mesh, and one draw call per material it contains.

**Cluster interface** — an edge where two clusters meet. Must never move, or the clusters would
pull apart. Compare *mesh boundary*.

**Collapse / half-edge collapse** — removing an edge by moving one endpoint onto the other. The
simplifier's only operation.

**Corner** — one vertex of one triangle, carrying normal, UV and material. Several corners can share
one *position*.

**Cut** — the set of clusters drawn this frame. Exactly one cluster on every root-to-leaf path.

**DAG** — directed acyclic graph. Like a tree, except a cluster can have several parents: every
part a group produced counts as a parent of every cluster the group consumed. Here: every cluster
at every level, each linked to the clusters it replaced.

**Error** — how far a cluster's surface can be from the source surface, in model units. Shared by
every cluster a group produced, and never smaller than any of its children's.

**Error threshold** — the largest error, in screen pixels, a drawn cluster may show. Lower means
more detail and more clusters drawn.

**Group** — about four adjacent clusters merged, simplified together and re-split. The unit that
makes the cut consistent.

**Leaf** — a cluster at level 0, made directly from source triangles, with zero error.

**Level** — how many rounds of simplification a cluster has been through. Leaves are 0.

**Link condition** — a check that a collapse won't join two parts of the surface that only touch at
a point, which would create a non-manifold edge.

**Locked edge** — an edge the simplifier may not move: a group's outer boundary, apart from open
mesh boundary edges.

**Mesh boundary** — an edge used by only one triangle in the whole mesh: the open outline, with
nothing beyond it. May be coarsened, at a cost. Compare *cluster interface*.

**Monotonic error** — error never decreases from a cluster to its parent. Guarantees the cut rule
selects exactly one cluster per path.

**Parent error / parent bounds** — the error and bounds of the group a cluster was merged into.
Stored on the cluster itself so selection never has to look anything up.

**Parts** — the clusters a group produced by re-splitting. All of a group's parts switch together.

**Position** — a welded vertex location, shared by every corner there.

**Projected error** — error divided by shell distance, times the screen scale: error in pixels.

**Quadric** — a symmetric matrix summarizing the squared distance to a set of planes. 10
coefficients for position, and evaluating it at any point is constant time.

**Region growing** — building a leaf cluster by repeatedly taking the neighboring triangle that
grows it least.

**Root** — the single coarsest cluster, covering the whole mesh.

**Seam** — a position whose corners disagree (a UV island edge, a hard crease, a material border).
Costs extra to erase; collapsing along one is priced by how far its curve moves.

**Shell / inner radius** — a cluster's bounds as the region between an outer and an inner sphere.
Distance to the shell, not the center, is what error is divided by, so hollow worlds work.

**Slack / slack floor** — how far the camera can move before a cluster's cut decision could change;
the floor is the smallest slack in the cut. While the floor is unspent, selection does nothing.

**Texel density** — UV area per unit of world area: how much texture a triangle carries. The
simplifier refuses collapses that change it more than 4×.

**Weld** — merging vertices within `WeldTolerance` of each other into one position.

---

## Code map

Build (C#, `addons/godotite/native/`):

| File | Responsibility | Start with |
|---|---|---|
| `GodotiteNative.cs` | The only class GDScript can see; runs the stages in order on a worker thread and reports progress. | `StartBuild`, `FinishBuild`, `PackDag`, `BuildProgress` |
| `GodotiteMesh.cs` | Parsed mesh: welding, corners, seams, quadrics, triangle adjacency, collapse costs. | `Parse`, `BuildBaseQuadrics`, `BuildUvQuadrics`, `CollapseCost` |
| `GodotiteClustering.cs` | Leaf clustering: region growing, bridging, orphan folding. | `CreateLeafGroups` |
| `GodotiteDag.cs` | The level loop: grouping, merging, dropping, error and bounds, re-splitting, mesh baking. | `BuildClusterDag`, `BuildGroup` |
| `GodotiteSimplifier.cs` | Half-edge collapse with locked edges and rejection rules. | `Simplify`, `IsCollapseValid` |

Runtime and integration (GDScript, `addons/godotite/`):

| File | Responsibility | Start with |
|---|---|---|
| `godotite_lod.gd` | `GodotiteLOD` node: cut selection, rendering, editor preview, debug views. | `select_cut_incremental`, `projected_error`, `_adopt_rendering_server` |
| `godotite_dag.gd` | `GodotiteDAG` resource: the packed hierarchy. | the exported arrays |
| `godotite_builder.gd` | `GodotiteBuilder` node: settings, Regenerate, build orchestration. | `build_from_mesh`, `assemble_lod_node` |
| `godotite_converter.gd` | Replaces meshes in an imported scene with LOD nodes; the import options. | `build_lods`, `build_options` |
| `import_plugin.gd` | The import options and post-import hook; hands off to the converter. | `_get_import_options` |
| `plugin.gd` | Registers everything; the project settings and Tools menu. | `_enter_tree` |
| `godotite_export.gd` | Export: DAG files added, debug channel stripped, the demo left out. | `_customize_resource` |
| `godotite_project.gd` | Editor only: DAG files and the scenes referring to them. | `dag_references_in_scene` |
| `godotite_util.gd` | A build source keeping only its mesh's path. | `release_mesh`, `resolve_mesh` |
| `godotite_log.gd` | Timestamped build logging. | `log` |
| `demo/` | The demo: a noise heightmap, fly camera and overlay. | `godotite_demo.tscn` |

---

## Checking a DAG

Kept separate on purpose: none of this runs in a shipped game, and both are loaded only when their
button is pressed.

**Validator** (`tools/godotite_validate.gd`, *Validate DAG* on a `GodotiteLOD`) — seven independent
checks on a built DAG: structure, monotonic error and nested bounds, cut validity across many
thresholds and viewpoints, agreement between the three selectors, incremental agreement step by
step, incremental **drift** over many small steps, and **no cracks** (assembling cuts and confirming
every unpaired edge lies on the source outline). The selector checks fail if their camera path never
changes the cut, because a path like that could not tell a working selector from a frozen one.

**Measure tool** (`tools/godotite_measure.gd`, *Measure Error* on a `GodotiteLOD`) — the error a cut
actually shows, measured from the meshes rather than taken from the error the build recorded: for
full-detail vertices, the distance to the surface the cut draws, in pixels, at a range of
thresholds. It is what says whether a threshold of `T` pixels keeps its promise.
