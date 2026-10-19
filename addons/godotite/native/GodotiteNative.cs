using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Godot;

namespace Godotite;

/// <summary>
/// The script-facing surface of the native builder. Everything inside is plain C#; this class exists
/// only so GDScript can reach it.
///
/// GodotiteBuilder runs a build with StartBuild, which reads the source on the calling thread and
/// runs every stage on a worker; polls IsBuilding, TakeMessages and ProgressLine until it is done;
/// then calls FinishBuild and PackDag on the main thread. The stages can also be called one at a
/// time, in order — Parse, BuildAdjacency, BuildLeafGroups, BuildDag, PackDag — on the calling
/// thread, which is what the profiling script does.
///
/// Load it by path rather than by class name — [GlobalClass] names resolve through the editor's
/// class cache, which a headless `--script` run does not have:
///
///     var native = load("res://addons/godotite/native/GodotiteNative.cs").new()
/// </summary>
[GlobalClass]
public partial class GodotiteNative : RefCounted
{
    private readonly GodotiteMesh _mesh = new();
    private readonly BuildProgress _progress = new();
    private Task? _build;

    /// <summary>
    /// Starts a whole build: reads the mesh here, since that is an engine call, then parses and
    /// builds the DAG on a worker thread. Poll <see cref="IsBuilding"/>, then call
    /// <see cref="FinishBuild"/> and <see cref="PackDag"/>, both on the main thread.
    /// </summary>
    public void StartBuild(Mesh mesh, float attributeWeight, float uvDistortionWeight,
        int minClusterTriangles, double materialSplitPenalty, double boundaryEdgeWeight,
        bool bridgeDisconnected, double bridgeJumpRadius, int clusterGroupSize,
        bool dropSmallComponents, double dropComponentFraction, bool coarsenSeamCurves,
        bool coarsenMeshBoundaries, double uvDensityLimit, bool includeTangents, float customAttributeWeight,
        float colorAttributeWeight, int cellTriangles)
    {
        _mesh.ReadSurfaces(mesh);
        // Its own thread rather than a pool one: it runs for the whole build, and the stages'
        // Parallel.For loops want every pool thread they can get.
        _build = Task.Factory.StartNew(() =>
        {
            if (cellTriangles > 0 && _mesh.SourceTriangleCount() > cellTriangles)
            {
                var cells = new GodotiteCellBuild(_mesh, _progress)
                {
                    CellTriangles = cellTriangles,
                    AttributeWeight = attributeWeight,
                    UvDistortionWeight = uvDistortionWeight,
                    IncludeTangents = includeTangents,
                    CustomWeight = customAttributeWeight,
                    ColorWeight = colorAttributeWeight,
                    NewClustering = cell => new GodotiteClustering(cell)
                    {
                        Progress = _progress,
                        MinClusterTriangles = minClusterTriangles,
                        MaterialSplitPenalty = materialSplitPenalty,
                        BoundaryEdgeWeight = boundaryEdgeWeight,
                        BridgeDisconnected = bridgeDisconnected,
                        BridgeJumpRadius = bridgeJumpRadius,
                    },
                    NewDag = cell => new GodotiteDag(cell)
                    {
                        ClusterGroupSize = clusterGroupSize,
                        MaterialSplitPenalty = materialSplitPenalty,
                        BridgeJumpRadius = bridgeJumpRadius,
                        DropSmallComponents = dropSmallComponents,
                        DropComponentFraction = dropComponentFraction,
                        CoarsenSeamCurves = coarsenSeamCurves,
                        CoarsenMeshBoundaries = coarsenMeshBoundaries,
                        UvDensityLimit = uvDensityLimit,
                        Progress = _progress,
                    },
                    Publish = dag => Volatile.Write(ref _dag, dag),
                };
                cells.Build();
                _progress.Message($"native: DAG built{BuildProgress.Memory()}");
                return;
            }
            _progress.Message($"native: parsing mesh{BuildProgress.Memory()}");
            _progress.Message(BuildProgress.ConserveMemoryNote());
            _mesh.Parse(attributeWeight, uvDistortionWeight, includeTangents, customAttributeWeight,
                colorAttributeWeight);
            if (_mesh.DebugChannel < 0)
                _progress.Message("native: the source uses all four custom channels, so clusters carry "
                    + "no debug data and the debug views will show nothing");
            _progress.Message($"native: building triangle adjacency{BuildProgress.Memory()}");
            BuildAdjacency();
            _progress.Message($"native: leaf clustering{BuildProgress.Memory()}");
            BuildLeafGroups(minClusterTriangles, materialSplitPenalty, boundaryEdgeWeight,
                bridgeDisconnected, bridgeJumpRadius);
            _progress.Message($"native: building DAG{BuildProgress.Memory()}");
            BuildDag(clusterGroupSize, materialSplitPenalty, bridgeJumpRadius, dropSmallComponents,
                dropComponentFraction, coarsenSeamCurves, coarsenMeshBoundaries, uvDensityLimit);
            _progress.Message($"native: DAG built{BuildProgress.Memory()}");
        }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
    }

    /// <summary>
    /// Bakes cluster meshes the running build has finished, oldest first, for up to
    /// <paramref name="budgetMs"/>. Main thread only; call it while polling, so prepared arrays are
    /// freed as the build goes rather than all held until PackDag. Returns how many were baked.
    /// </summary>
    public int BakeReady(double budgetMs) => Volatile.Read(ref _dag)?.BakeReady(budgetMs) ?? 0;

    /// <summary>True while a build started by StartBuild is still running.</summary>
    public bool IsBuilding() => _build is { IsCompleted: false };

    /// <summary>Progress messages reported since the last call, oldest first.</summary>
    public string[] TakeMessages() => _progress.TakeMessages();

    /// <summary>The step in progress as "step: done/total", or empty between steps.</summary>
    public string ProgressLine() => _progress.Line();

    /// <summary>Waits for the build and returns its error, or an empty string on success.</summary>
    public string FinishBuild()
    {
        if (_build == null)
            return "no build was started";
        try
        {
            _build.Wait();
            return "";
        }
        catch (AggregateException failure)
        {
            return failure.InnerException?.ToString() ?? failure.ToString();
        }
    }

    /// <summary>Parses a mesh and keeps the result for subsequent calls.</summary>
    public void Parse(Mesh mesh, float attributeWeight, float uvDistortionWeight, bool includeTangents,
        float customAttributeWeight)
        => _mesh.Parse(mesh, attributeWeight, uvDistortionWeight, includeTangents, customAttributeWeight);

    /// <summary>Per-phase timings from the last Parse().</summary>
    public Godot.Collections.Dictionary PhaseTimings()
    {
        var result = new Godot.Collections.Dictionary();
        foreach (System.Collections.Generic.KeyValuePair<string, double> entry in _mesh.PhaseMs)
            result[entry.Key] = entry.Value;
        return result;
    }

    private GodotiteClustering? _clustering;
    private GodotiteDag? _dag;

    /// <summary>Builds the whole DAG from the leaf groups already grown by BuildLeafGroups().</summary>
    public void BuildDag(int clusterGroupSize, double materialSplitPenalty, double bridgeJumpRadius,
        bool dropSmallComponents, double dropComponentFraction, bool coarsenSeamCurves,
        bool coarsenMeshBoundaries, double uvDensityLimit)
    {
        if (_clustering == null)
            return;
        _dag = new GodotiteDag(_mesh)
        {
            ClusterGroupSize = clusterGroupSize,
            MinClusterTriangles = _clustering.MinClusterTriangles,
            MaterialSplitPenalty = materialSplitPenalty,
            BridgeJumpRadius = bridgeJumpRadius,
            DropSmallComponents = dropSmallComponents,
            DropComponentFraction = dropComponentFraction,
            CoarsenSeamCurves = coarsenSeamCurves,
            CoarsenMeshBoundaries = coarsenMeshBoundaries,
            UvDensityLimit = uvDensityLimit,
            BridgingActive = _clustering.BridgingActive,
        };

        _dag.Progress = _progress;

        System.Collections.Generic.List<GodotiteDag.Cluster> leaves = MakeLeaves(_mesh, _dag, _clustering.Groups,
            _progress);
        // Nothing after leaf clustering reads its state or the triangle adjacency, so neither is
        // kept through the DAG build.
        _clustering = null;
        _mesh.ReleaseAdjacency();
        GodotiteDag.CollectGarbage();
        _dag.BuildClusterDag(leaves);
    }

    /// <summary>
    /// Leaf geometry in parallel, one task per group; baking afterwards, serially and in group
    /// order, for the reasons given on GodotiteDag.MakeCluster. Its own method so the groups are
    /// unreachable once it returns.
    /// </summary>
    internal static System.Collections.Generic.List<GodotiteDag.Cluster> MakeLeaves(GodotiteMesh mesh,
        GodotiteDag dag, System.Collections.Generic.List<System.Collections.Generic.List<int>> groups,
        BuildProgress progress)
    {
        var made = new GodotiteDag.Cluster?[groups.Count];
        progress.BeginStep("leaf clusters made", groups.Count);
        Parallel.For(0, groups.Count, g =>
        {
            System.Collections.Generic.List<int> group = groups[g];
            if (group.Count == 0)
            {
                progress.Advance();
                return;
            }
            var triangles = new System.Collections.Generic.List<GodotiteSimplifier.Triangle>(group.Count);
            foreach (int t in group)
            {
                GodotiteMesh.Triangle src = mesh.Triangles[t];
                triangles.Add(new GodotiteSimplifier.Triangle(src.I0, src.I1, src.I2)
                {
                    C0 = src.C0,
                    C1 = src.C1,
                    C2 = src.C2,
                    Material = src.Material,
                });
            }
            made[g] = dag.MakeCluster(triangles, 0,
                new System.Collections.Generic.List<GodotiteDag.Cluster>());
            progress.Advance();
        });
        progress.EndStep();

        var leaves = new System.Collections.Generic.List<GodotiteDag.Cluster>();
        foreach (GodotiteDag.Cluster? leaf in made)
        {
            if (leaf == null)
                continue;
            dag.QueueBake(leaf);
            leaves.Add(leaf);
        }
        return leaves;
    }

    /// <summary>
    /// The built hierarchy flattened into exactly the arrays GodotiteDAG stores, plus the cluster
    /// meshes. GDScript assembles the resource from these rather than C# constructing it, because
    /// GodotiteDAG is a GDScript class and building one from the other side means poking properties
    /// by name on a script object — fragile, and it would silently rot the moment a field is renamed.
    /// </summary>
    public Godot.Collections.Dictionary PackDag()
    {
        var result = new Godot.Collections.Dictionary();
        if (_dag == null || _dag.Root == null)
            return result;
        _dag.BakeQueued();

        System.Collections.Generic.List<GodotiteDag.Cluster> ordered = _dag.Ordered;
        int count = ordered.Count;
        var indexOf = new System.Collections.Generic.Dictionary<GodotiteDag.Cluster, int>(count);
        for (int i = 0; i < count; i++)
            indexOf[ordered[i]] = i;

        var levels = new int[count];
        var triangleCounts = new int[count];
        var errors = new float[count];
        var lodCenters = new Vector3[count];
        var lodRadii = new float[count];
        var lodInnerRadii = new float[count];
        var parentErrors = new float[count];
        var parentCenters = new Vector3[count];
        var parentRadii = new float[count];
        var parentInnerRadii = new float[count];
        var childOffsets = new int[count];
        var childCounts = new int[count];
        var surfaceOffsets = new int[count];
        var surfaceCounts = new int[count];
        var childIndices = new System.Collections.Generic.List<int>();
        var surfaceMaterials = new System.Collections.Generic.List<int>();
        var meshes = new Godot.Collections.Array();

        for (int i = 0; i < count; i++)
        {
            GodotiteDag.Cluster cluster = ordered[i];
            levels[i] = cluster.Level;
            triangleCounts[i] = cluster.TriangleCount;
            errors[i] = (float)cluster.Error;
            lodCenters[i] = cluster.LodCenter;
            lodRadii[i] = (float)cluster.LodRadius;
            lodInnerRadii[i] = (float)cluster.LodInnerRadius;
            // The root has no parent and stores INF, so it always counts as "parent too coarse".
            parentErrors[i] = double.IsInfinity(cluster.ParentError)
                ? float.PositiveInfinity
                : (float)cluster.ParentError;
            parentCenters[i] = cluster.ParentCenter;
            parentRadii[i] = (float)cluster.ParentRadius;
            parentInnerRadii[i] = (float)cluster.ParentInnerRadius;

            childOffsets[i] = childIndices.Count;
            childCounts[i] = cluster.Children.Count;
            foreach (GodotiteDag.Cluster child in cluster.Children)
                childIndices.Add(indexOf[child]);

            surfaceOffsets[i] = surfaceMaterials.Count;
            surfaceCounts[i] = cluster.SurfaceMaterials.Length;
            foreach (int material in cluster.SurfaceMaterials)
                surfaceMaterials.Add(material);

            meshes.Add(cluster.Mesh!);
        }

        result["cluster_count"] = count;
        result["root_index"] = indexOf[_dag.Root];
        result["levels"] = levels;
        result["triangle_counts"] = triangleCounts;
        result["errors"] = errors;
        result["lod_centers"] = lodCenters;
        result["lod_radii"] = lodRadii;
        result["lod_inner_radii"] = lodInnerRadii;
        result["parent_errors"] = parentErrors;
        result["parent_centers"] = parentCenters;
        result["parent_radii"] = parentRadii;
        result["parent_inner_radii"] = parentInnerRadii;
        result["child_offsets"] = childOffsets;
        result["child_counts"] = childCounts;
        result["child_indices"] = childIndices.ToArray();
        result["surface_material_offsets"] = surfaceOffsets;
        result["surface_material_counts"] = surfaceCounts;
        result["surface_materials"] = surfaceMaterials.ToArray();
        result["debug_channel"] = _dag.DebugChannel;
        result["meshes"] = meshes;
        return result;
    }

    /// <summary>Rebuilds PackDag()'s cluster meshes with vertex compression, crack-free
    /// (GodotiteCompress). Main thread only.</summary>
    public Vector2I CompressMeshes(Godot.Collections.Array meshes) => GodotiteCompress.CompressMeshes(meshes);

    /// <summary>Per-level group statistics from the last BuildDag(), for diagnosing DAG shape:
    /// level, groups, clusters in, clusters out, and the group-size histogram.</summary>
    public Godot.Collections.Array LevelStats() => _dag?.LevelStats ?? new Godot.Collections.Array();

    /// <summary>Grows leaf groups. Settings come from GodotiteBuilder's exports.</summary>
    public void BuildLeafGroups(int minClusterTriangles, double materialSplitPenalty,
        double boundaryEdgeWeight, bool bridgeDisconnected, double bridgeJumpRadius)
    {
        _clustering = new GodotiteClustering(_mesh)
        {
            Progress = _progress,
            MinClusterTriangles = minClusterTriangles,
            MaterialSplitPenalty = materialSplitPenalty,
            BoundaryEdgeWeight = boundaryEdgeWeight,
            BridgeDisconnected = bridgeDisconnected,
            BridgeJumpRadius = bridgeJumpRadius,
        };
        _clustering.CreateLeafGroups();
    }


    /// <summary>The process's resident memory now, in MB.</summary>
    public static double ResidentMb()
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        return process.WorkingSet64 / 1048576.0;
    }

    /// <summary>The process's peak resident memory since start or the last ResetPeakResident(), in MB.</summary>
    public static double PeakResidentMb()
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        return process.PeakWorkingSet64 / 1048576.0;
    }

    /// <summary>Resets the peak to the current resident memory, so a measurement counts only what
    /// follows. Linux only; elsewhere the peak keeps counting from process start.</summary>
    public static void ResetPeakResident()
    {
        try
        {
            System.IO.File.WriteAllText("/proc/self/clear_refs", "5");
        }
        catch (Exception)
        {
            // Not Linux, or not permitted.
        }
    }

    /// <summary>Builds triangle adjacency from the parsed mesh.</summary>
    public void BuildAdjacency() => _mesh.BuildTriangleAdjacency();
}

/// <summary>
/// What a build on a worker thread tells the main thread: a queue of messages, each printed once,
/// and the step in progress as a done/total count. Thread-safe; the build writes, the builder polls.
/// </summary>
public sealed class BuildProgress
{
    private readonly ConcurrentQueue<string> _messages = new();
    private readonly object _stepLock = new();
    private string _step = "";
    private int _total;
    private int _done;

    public void Message(string message) => _messages.Enqueue(message);

    /// <summary>
    /// Set GODOTITE_MEMORY_TRACE=1 to collect garbage fully before each memory report and include
    /// live managed memory: slower, but it separates what the build holds from garbage not yet
    /// collected.
    /// </summary>
    private static readonly bool Trace = System.Environment.GetEnvironmentVariable("GODOTITE_MEMORY_TRACE") == "1";

    /// <summary>
    /// Whether the garbage collector's ConserveMemory setting is on. Off, the collector lets the heap
    /// grow well past what is live, and a build peaks about a third higher: measured 0.81 against
    /// 0.53 KB per source triangle at 9, on the 980k terrain. It can only be set before the runtime
    /// starts, and the editor ignores the project's runtimeconfig.json, so the environment variable
    /// is the only way in.
    /// </summary>
    public static string ConserveMemoryNote()
    {
        long level = GC.GetConfigurationVariables().TryGetValue("GCConserveMem", out object? value)
            ? Convert.ToInt64(value, CultureInfo.InvariantCulture) : 0;
        return level > 0
            ? $"native: GC conserve memory {level}"
            : "native: GC conserve memory off; start Godot with DOTNET_GCConserveMemory=9 in the "
                + "environment for about a third less build memory";
    }

    /// <summary>The process's memory, for appending to a progress message: resident now and at
    /// peak, and live managed memory when tracing.</summary>
    public static string Memory()
    {
        string live = "";
        if (Trace)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            live = $", {GC.GetTotalMemory(false) / 1048576.0:F0} MB live";
        }
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        return $" [{process.WorkingSet64 / 1048576.0:F0} MB resident, peak {process.PeakWorkingSet64 / 1048576.0:F0} MB, "
            + $"managed heap {GC.GetGCMemoryInfo().HeapSizeBytes / 1048576.0:F0} MB, committed {GC.GetGCMemoryInfo().TotalCommittedBytes / 1048576.0:F0} MB{(System.Runtime.GCSettings.IsServerGC ? " server" : "")}{live}, engine {OS.GetStaticMemoryUsage() / 1048576.0:F0} MB]";
    }

    public void BeginStep(string step, int total)
    {
        lock (_stepLock)
        {
            _step = step;
            _total = total;
            Volatile.Write(ref _done, 0);
        }
    }

    public void Advance() => Interlocked.Increment(ref _done);

    public void EndStep()
    {
        lock (_stepLock)
            _total = 0;
    }

    public string[] TakeMessages()
    {
        var taken = new System.Collections.Generic.List<string>();
        while (_messages.TryDequeue(out string? message))
            taken.Add(message);
        return taken.ToArray();
    }

    public string Line()
    {
        lock (_stepLock)
            return _total > 0 ? $"{_step}: {Volatile.Read(ref _done)}/{_total}" : "";
    }
}
