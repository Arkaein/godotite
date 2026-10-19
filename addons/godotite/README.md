# Godotite

Seamless level of detail for large static meshes in Godot, after the idea behind Unreal's Nanite.

Godotite builds a mesh into a hierarchy of small clusters, from full detail down to a single coarse
root. Every frame, a `GodotiteLOD` node draws the coarsest clusters that look right from the camera:
full detail close up, far fewer triangles in the distance, and never a crack between them. A
multi-million-triangle terrain or scan then costs what its on-screen detail costs, not what the
whole mesh would.

It needs nothing from your materials, shaders or scenes: a `GodotiteLOD` draws the mesh's own
materials, and a game using it needs no C#.

Godotite is an LLM-assisted project: most of its code and documentation were written by Claude
(Anthropic), directed, tested and reviewed by the author.

- [Requirements](#requirements)
- [Installing](#installing)
- [Try the demo](#try-the-demo)
- [Using Godotite on your own meshes](#using-godotite-on-your-own-meshes)
- [Quality: the error threshold](#quality-the-error-threshold)
- [DAG files and version control](#dag-files-and-version-control)
- [Exporting a game](#exporting-a-game)
- [Checking and tuning](#checking-and-tuning)
- [Building large meshes](#building-large-meshes)
- [Settings](#settings)
- [Limits](#limits)

## Requirements

- **Godot 4.5 or later.**
- **To build:** the .NET version of Godot, the .NET SDK it asks for (.NET 8 for Godot 4.5), and a
  C# project in your project. Building runs in C# for speed.
- **To run:** nothing extra. Drawing is GDScript, so a game using Godotite can export without .NET
  ([Exporting a game](#exporting-a-game)).

## Installing

1. Copy `addons/godotite` into your project's `addons` folder, or install it from the Asset
   Library.
2. If the project has no C# yet, create it: **Project › Tools › C# › Create C# solution**.
3. Build the C# once: the **Build** button (the hammer) at the top right of the editor, or
   `dotnet build` in the project folder.
4. Enable the plugin: **Project › Project Settings › Plugins › Godotite**.

A `GodotiteBuilder` warns if building is not possible yet, and says what is missing.

## Try the demo

Open `addons/godotite/demo/godotite_demo.tscn`, select **DemoTerrain** and press **Generate**. It
makes a noise heightmap (2.1 million triangles at the default Resolution, up to about 8.4 million)
and builds its LOD, in a few seconds. Save the scene and run it.

Fly with WASD, Q and E and the mouse. In the overlay:

- `[` and `]` change the error threshold, and the triangle count follows.
- `\` freezes the clusters drawn, so you can fly away and see what was chosen.
- Tab cycles the cluster view (a color per cluster), a checker, and the terrain's own colors.
- C changes what the cluster colors show: cluster, level or error.
- H hides the overlay; V uncaps the frame rate.

The demo's folder is left out of exported games. Delete it once you no longer need it.

## Using Godotite on your own meshes

There are two ways to build a mesh. Both use the same builder and settings, and give the same
result.

### Importing

For a mesh that arrives as a scene file (`.glb`, `.gltf`, `.blend` and anything else Godot imports
as a scene): select the file, tick **Godotite › Build Lod** in the Import dock, and press
**Reimport**. Every mesh of 131,072 triangles or more is replaced by a `GodotiteLOD` of the same
name, in the same place; smaller ones are left as they are.

The DAG (the built hierarchy) is kept inside the imported scene, so there is nothing else to manage.
Godot rebuilds it whenever the file is reimported, which includes a fresh checkout of the project.

The editor is frozen while an import builds: Godot's import does not let the editor redraw. To watch
a long build, start the editor from a terminal, where its progress appears as it goes.

### Building in a scene

For a mesh already in a scene, or one made by code:

1. Add a **GodotiteBuilder** node and set its **Source** to the MeshInstance3D holding the mesh.
2. Press **Regenerate**.

The build runs in the background, with its progress in the Output panel. The first build creates a
`GodotiteLOD` next to the builder, named after the source (Terrain makes TerrainLOD), and hides the
source, since the LOD now draws it. Later builds update that LOD in place.

**Save the source mesh in a file of its own** (the Mesh property's menu › Save As...). A hidden
source then keeps only the file's path, so neither the editor nor the game loads the full mesh when
the scene opens; showing the source loads it again, to compare with the LOD. A mesh stored in the
scene is always loaded with it, and the builder warns about it. A script on the source node (a
mesh generator, say) should not take an empty mesh to mean "not generated": use
`GodotiteUtil.resolve_mesh(node)`, which gives the mesh either way.

Any Mesh works as a source, including Godot's primitive meshes.

### What carries over

Each surface's material, UVs, normals and tangents (generated where the source has none), vertex
colors and custom channels (CUSTOM0 to 3) all carry into every cluster, and simplification takes
care not to stretch textures or move seams and color borders. Meshes made of many separate pieces
and non-manifold edges (a shoreline where land, seabed and water meet) are fine.

## Quality: the error threshold

How much detail is drawn is set once for the whole project: **Project Settings › Godotite › LOD ›
Error Threshold**. It is the largest error, in pixels on the actual screen, that a drawn cluster may
show. Lower draws more detail and more triangles. 2, the default, is close to indistinguishable from
full detail; 5 is a performance setting, where popping can show along material borders.

- **At runtime**, for a graphics-quality setting: `GodotiteLOD.set_global_error_threshold(value)`.
  Every LOD follows it from the next frame. `GodotiteLOD.get_global_error_threshold()` reads it.
- **For one node**, rarely: a GodotiteLOD's own **Error Threshold** overrides the project's. 0, the
  default, follows the project. In an imported scene, reach the node through Editable Children or an
  inherited scene.

A GodotiteLOD's **Draw Call Budget** can also cap its draw calls, raising its threshold a little each
frame while it is over.

## DAG files and version control

**Where they go.** A builder saves its DAG to a file of its own in the project's DAG folder:
**Project Settings › Godotite › Build › DAG Folder**, `res://godotite_generated/` by default. The
first build names the file after the scene, the LOD and the DAG's UID
(`world_TerrainLOD_7l83gtp1c7jc.res`), so names never collide. Set the builder's **Dag Path** to
choose the file yourself. Imported scenes keep their DAGs inside them instead.

**Moving things is safe.** Later builds overwrite the file the LOD already uses, wherever it is, under
the same UID. Moving or renaming scenes, nodes or DAG files breaks nothing and needs no rebuild.

**A missing DAG does not break the scene.** A GodotiteLOD refers to its DAG file by UID, so a scene
whose DAG has not been built opens normally, and the LOD and its builder show a warning. Regenerate,
or **Project › Tools › Godotite: Rebuild Missing DAGs** for the whole project, writes the file back
where the scene expects it. Builds are deterministic: a rebuilt DAG is the same as the one it
replaces.

**Version control.** DAGs are large, about 23 bytes per source triangle (some 90 MB for 4 million
triangles), and they are derived data: the source meshes and scenes are what matter. Choose one:

- **Ignore them and rebuild** (recommended): add the DAG folder to `.gitignore`, commit the source
  meshes, and run Rebuild Missing DAGs after cloning. Every machine that builds or exports needs the
  .NET version of Godot.
- **Commit them with Git LFS**, when people or a build server export without .NET: add the folder to
  `.gitattributes`, for example `godotite_generated/** filter=lfs diff=lfs merge=lfs -text`.
- **Import instead of building in scenes**: nothing to manage, but every machine rebuilds on import,
  which needs .NET and takes the build time.

**Unused files.** **Project › Tools › Godotite: Find Unused DAGs** lists DAG files that no saved
scene, resource or script refers to (left behind by deleted scenes or nodes), and deletes them after
asking. Save open scenes first: only saved files are searched.

## Exporting a game

Export as usual. Godotite's export plugin adds every DAG an exported scene uses, whatever the
export's resource filter, and strips the data only the debug views need (4 bytes per vertex), from
imported scenes' DAGs too. It also leaves the demo's scene out (its three small scripts still go in
when exporting all resources: Godot compiles scripts before other export plugins see them), unless
the project's main scene is in the demo's folder: then the demo goes in, and its DAG keeps the
debug data for the cluster view.

### Without .NET

Drawing is GDScript, so a game using Godotite needs no .NET. But the .NET editor puts .NET into
every export of a project that has a C# solution file (`.sln`): the project's build and the .NET
runtime, about 75 MB on Linux, in a `data_<assembly name>_<platform>` folder beside the game, even
when no C# file is exported. Godot has no export setting to turn this off. If your game uses C#
itself, that is what it needs. If only Godotite's builder does, leave .NET out:

1. Once, in the export preset's **Resources** tab: `*.cs` in **Filters to exclude files/folders
   from project** (not the filter above it, which adds files).
2. For each export, rename the solution file (the `.sln` in the project folder, named after
   **Project Settings › Dotnet › Project › Assembly Name**) so the export finds none, and rename it
   back afterwards, since the editor builds through it. Around a command-line export:

   ```
   mv MyGame.sln MyGame.sln.off && godot --headless --export-release "Linux" build/mygame.x86_64; mv MyGame.sln.off MyGame.sln
   ```

What to expect:

- **No `data_` folder** is written. Export into an empty folder: a game finds and loads the
  `data_` folder an earlier export left beside it, since the folder is named after the assembly,
  not the game.
- **Errors naming a C# file and a missing solution** ("This project contains C# files but no
  solution file was found") mean a `.cs` file is still exported: check the exclude filter. The
  export still finishes, with .NET left out, but carries the C# files.
- The game runs without .NET, on the .NET templates too (tested on Linux, Godot 4.5.1). Exporting
  from the standard editor, with its templates, should also leave .NET out; not tested yet.
- **To check,** run the game with `--verbose`: with .NET it logs `.NET: Initializing module...`;
  without it, no `.NET` lines. Without .NET, a game also starts faster and uses about 50 MB less
  memory (Linux, measured on a small scene).

## Checking and tuning

**The buttons on a GodotiteLOD:**

- **Validate DAG** checks the hierarchy: its structure, that error never decreases towards the
  root, that every choice of clusters covers the mesh exactly once, that the ways of choosing agree,
  and that no choice leaves a crack. It prints a report ending PASS or FAIL.
- **Measure Error** tries a range of thresholds from the current camera and reports, for each, the
  error actually seen in pixels and what it cost in triangles and draw calls: a threshold chosen from
  numbers rather than guessed. It measures at most 20,000 full-detail vertices.
- **Apply Debug View** shows what the Debug group picks: the clusters chosen from a point, one level
  of the hierarchy, or all of it.

Both checks print their progress in the Output panel and keep the editor drawing while they run.
They take seconds on a few million triangles, longer on very large meshes.

**Seeing the clusters.** Set a GodotiteLOD's **Material** to
`addons/godotite/tools/cluster_debug.tres`: each cluster gets a color, by cluster, level or error
(Color Mode). `graybox_checker.tres` shows texture stretching. Clear Material to go back to the
mesh's own.

**Cluster size.** **Min Cluster Triangles** (4096) is the one build setting worth knowing. Larger
clusters mean fewer draw calls and cheaper selection; smaller ones choose detail more finely. 4096
and 8192 measure within a few percent of each other; much smaller is slower. 0 picks a size from
the mesh.

## Building large meshes

Building takes roughly 5 to 10 seconds per million source triangles on a desktop CPU, and about
1.5 GB of memory plus 0.2 KB per source triangle.

- **Meshes over 4 million triangles build in cells** (Cell Triangles): each cell is built alone,
  then the cells are joined and built on to the root, so memory follows the cell size rather than the
  whole mesh. Lower Cell Triangles if a build runs out of memory.
- **Start Godot with `DOTNET_GCConserveMemory=9`** in the environment for about a third less build
  memory: `DOTNET_GCConserveMemory=9 godot --editor --path my_project`. It must be set before Godot
  starts; the build log says whether it is on.
- **Diagnostics:** `GODOTITE_MEMORY_TRACE=1` logs the managed memory at each stage (slower), and
  `GODOTITE_REJECTS=1` logs why simplification stopped at each level. Every Godotite line is
  timestamped.

## Settings

Every builder and LOD setting is described in the editor: hover it in the Inspector, or open
**GodotiteBuilder** or **GodotiteLOD** in **Help › Search Help**. Most meshes need none changed.

The import options are the builder's settings, under the same names: **Godotite › Build Lod** and
**Min Cluster Triangles**, and under **Godotite › Advanced** the Clusters, Error Weights,
Boundaries, Disconnected Pieces and Output groups. Godot shows no descriptions for import options;
GodotiteBuilder's help has them.

The project settings are **Godotite › LOD › Error Threshold** (2) and **Godotite › Build › DAG
Folder** (`res://godotite_generated/`).

## Limits

- Static meshes only: no skinning or animation.
- Godotite draws; it does not add collision. Give the mesh, or a simpler one, a collision shape of
  its own.
- **Build a mesh split into chunks (terrain tiles, say) as one mesh.** Built separately, each
  chunk's shared edge is an open edge to it, simplified on its own, so cracks can open between
  neighboring chunks. Join them before building; Godotite clusters the whole anyway.
- A mesh under about 130,000 triangles is usually cheaper drawn as it is.
- Not in scope: virtual texturing, streaming, GPU-driven rendering.

For how it works, clusters, the hierarchy and why it never cracks, see [ALGORITHM.md](ALGORITHM.md).
Changes are listed in [CHANGELOG.md](CHANGELOG.md). Godotite is released under the MIT license
([LICENSE](LICENSE)).
