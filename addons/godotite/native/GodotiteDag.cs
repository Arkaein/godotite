using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

namespace Godotite;

using Triangle = GodotiteSimplifier.Triangle;
using Edge = GodotiteSimplifier.Edge;

/// <summary>
/// Cluster hierarchy construction: group, merge, simplify, re-split, level by level, until one root
/// remains.
///
/// The invariants that make a cut work are established here, not in the simplifier:
///
///   * every cluster out of one group carries the SAME error and the SAME bounding shell, so two
///     clusters of a group reach the same LOD decision without communicating and a group is never
///     half-refined;
///   * error is clamped monotonic up the DAG, so the parent-vs-own comparison has exactly one
///     solution per root-to-leaf path — which is what makes a cut a cut;
///   * a parent's shell CONTAINS every child's shell, which is what keeps projected error monotonic
///     as well.
/// </summary>
public sealed class GodotiteDag
{

    public sealed class Cluster
    {
        // Both are released once the next level has been built from them (Release); after that
        // only TriangleCount remains.
        public List<Triangle> Triangles = new();
        public List<Edge> BoundaryEdges = new();
        public int TriangleCount;
        public int Level;
        public List<Cluster> Children = new();
        public ArrayMesh? Mesh;
        public int[] SurfaceMaterials = Array.Empty<int>();
        // Baked into the mesh's debug channel by Bake(); held here because baking happens after the
        // cluster is made, not during.
        public double DebugErrorFraction;
        // Mesh arrays built by MakeCluster, off the main thread, and consumed by Bake().
        public PreparedSurface[]? Prepared;

        /// <summary>Drops the triangles and boundary once the level above is built: its groups
        /// simplify their own copies, and packing needs only the count.</summary>
        public void Release()
        {
            Triangles = new List<Triangle>(0);
            BoundaryEdges = new List<Edge>(0);
        }

        // Describe the simplification that PRODUCED this cluster, shared identically across the
        // group it came from. Leaves carry error 0 — they are the source geometry.
        public double Error;
        public Vector3 LodCenter;
        // Doubles through all the child-folding arithmetic, truncated to float32 only when packed
        // into the DAG resource, so rounding does not compound level after level.
        public double LodRadius;
        public double LodInnerRadius;

        // The coarser alternative that would replace this cluster. INF on the root, so the root
        // always passes "parent is too coarse".
        public double ParentError = double.PositiveInfinity;
        public Vector3 ParentCenter;
        public double ParentRadius;
        public double ParentInnerRadius;
    }

    private sealed class GroupResult
    {
        public List<Cluster> Clusters = new();
        public List<Cluster> Children = new();
        public double Error;
        public Vector3 Center;
        public double Radius;
        public double InnerRadius;
        public int[] Rejects = Array.Empty<int>();
    }

    public int ClusterGroupSize = 4;
    /// <summary>Target triangles per cluster, used to decide how many parts a group re-splits into.</summary>
    public int MinClusterTriangles = 4096;
    /// <summary>
    /// Double, not float, and this is load-bearing. In double, 1.0 - clamp(0.05 * 4.0) is exactly
    /// 0.8, while 0.05f * 4.0 gives 0.7999999970197678. Group members are chosen with a strict
    /// greater-than, so when a penalised candidate is seen first and ties with a later unpenalised
    /// one, the exact value keeps the first and the float one switches — which changed 47 of 300
    /// groups at the leaf level alone.
    /// </summary>
    public double MaterialSplitPenalty = 0.05;
    public double BridgeJumpRadius = 1.0;
    public bool DropSmallComponents = true;
    public double DropComponentFraction = 0.25;
    public bool CoarsenSeamCurves = true;
    public bool CoarsenMeshBoundaries;
    public double UvDensityLimit = 4.0;
    public bool BridgingActive;

    public Cluster? Root;
    public List<Cluster> Ordered = new();

    /// <summary>Per-level group shape, recorded during the build. Cluster size is supposed to stay
    /// near the target up the DAG, and only the group sizes actually chosen say whether it does.</summary>
    public readonly Godot.Collections.Array LevelStats = new();

    /// <summary>Where to report progress, if anywhere. Read from another thread.</summary>
    public BuildProgress? Progress;

    // Clusters awaiting Bake(), in the order they were made. The build runs off the main thread
    // and ArrayMesh creation must not, so the main thread bakes them as the build goes (BakeReady)
    // and at the end (BakeQueued) — in the order they would have happened inline, which is all the
    // debug-hue counter needs to stay identical. Baking early frees each cluster's prepared arrays
    // instead of holding every one until the build ends.
    private readonly ConcurrentQueue<Cluster> _bakeQueue = new();

    public void QueueBake(Cluster cluster) => _bakeQueue.Enqueue(cluster);

    /// <summary>Bakes queued clusters, in order, until the queue is empty or
    /// <paramref name="budgetMs"/> has passed. Main thread only. Returns how many it baked.</summary>
    public int BakeReady(double budgetMs)
    {
        long started = System.Diagnostics.Stopwatch.GetTimestamp();
        int baked = 0;
        while (System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds < budgetMs
            && _bakeQueue.TryDequeue(out Cluster? cluster))
        {
            Bake(cluster);
            baked++;
        }
        return baked;
    }

    /// <summary>Bakes every queued cluster, in order. Main thread only.</summary>
    public void BakeQueued()
    {
        while (_bakeQueue.TryDequeue(out Cluster? cluster))
            Bake(cluster);
    }

    private GodotiteMesh _mesh;

    /// <summary>Switches the mesh the clusters index: each cell of a chunked build has its own, and
    /// the merge another (GodotiteCells.cs).</summary>
    public void UseMesh(GodotiteMesh mesh) => _mesh = mesh;

    /// <summary>
    /// For a cell of a chunked build: stop once a level is down to this many triangles, or stops
    /// shrinking, and leave its clusters in <see cref="Top"/> rather than making a root. 0 builds
    /// to the root.
    /// </summary>
    public int StopAtTriangles;
    public List<Cluster> Top = new();

    /// <summary>Prefixed to each level's progress, to say which cell it belongs to.</summary>
    public string LevelLabel = "";

    /// <summary>The custom channel the baked clusters carry their debug data in (GodotiteMesh).</summary>
    public int DebugChannel => _mesh.DebugChannel;

    public GodotiteDag(GodotiteMesh mesh) => _mesh = mesh;

    // --- geometry helpers ---

    public static long EdgeKey(int a, int b) => GodotiteMesh.EdgeKey(a, b);

    /// <summary>Edges with a single incident triangle in this set — the set's outer boundary.</summary>
    /// <summary>
    /// The edges a triangle set does not close: those with one of its triangles, and non-manifold
    /// edges with fewer of its triangles than the level's mesh has (levelCounts, the mesh's
    /// NonManifoldEdges). Both must stay where they are while the set is simplified, since triangles
    /// outside the set use them too.
    /// </summary>
    public static List<Edge> ComputeBoundaryEdges(List<Triangle> triangles,
        Dictionary<long, int>? levelCounts = null)
    {
        var counts = new Dictionary<long, int>(triangles.Count * 2,
            GodotiteMesh.EdgeKeyComparer.Instance);
        var edges = new Dictionary<long, Edge>(triangles.Count * 2,
            GodotiteMesh.EdgeKeyComparer.Instance);
        var order = new List<long>(triangles.Count * 3);
        foreach (Triangle tri in triangles)
        {
            Tally(counts, edges, order, tri.I0, tri.I1);
            Tally(counts, edges, order, tri.I1, tri.I2);
            Tally(counts, edges, order, tri.I2, tri.I0);
        }
        var boundaries = new List<Edge>();
        bool nonManifold = levelCounts is { Count: > 0 };
        foreach (long key in order)
        {
            int count = counts[key];
            if (count == 1 || (nonManifold && levelCounts!.TryGetValue(key, out int full) && count < full))
                boundaries.Add(edges[key]);
        }
        return boundaries;
    }

    private static void Tally(Dictionary<long, int> counts, Dictionary<long, Edge> edges,
        List<long> order, int a, int b)
    {
        long key = EdgeKey(a, b);
        if (counts.TryGetValue(key, out int count))
        {
            counts[key] = count + 1;
            return;
        }
        counts[key] = 1;
        edges[key] = new Edge { I0 = a, I1 = b, Key = key };
        order.Add(key);
    }

    /// <summary>
    /// Approximate minimal enclosing sphere (Ritter): two passes, linear, within a few percent of
    /// optimal. An AABB centre and half-diagonal is badly loose for a curved patch — the box centre
    /// sits off the surface and the diagonal overshoots by up to sqrt(3) — and both errors compound
    /// through every union up the DAG.
    /// </summary>
    public Vector3 EnclosingSphereCenter(List<Triangle> triangles)
    {
        if (triangles.Count == 0)
            return Vector3.Zero;
        Vector3 seed = _mesh.Positions[triangles[0].I0];
        Vector3 farA = FarthestFrom(seed, triangles);
        Vector3 farB = FarthestFrom(farA, triangles);
        Vector3 center = (farA + farB) * 0.5f;
        // The radius accumulates in DOUBLE while the centre stays a float32 Vector3. Accumulating
        // the radius in float32 instead drifts the centre by ~6e-5 over a few hundred expansions:
        // small, but bounds decide the cut.
        double radius = farA.DistanceTo(farB) * 0.5;
        foreach (Triangle tri in triangles)
        {
            Expand(ref center, ref radius, _mesh.Positions[tri.I0]);
            Expand(ref center, ref radius, _mesh.Positions[tri.I1]);
            Expand(ref center, ref radius, _mesh.Positions[tri.I2]);
        }
        return center;
    }

    private static void Expand(ref Vector3 center, ref double radius, Vector3 position)
    {
        Vector3 offset = position - center;
        double distance = offset.Length();
        if (distance <= radius)
            return;
        // Keep the far side of the sphere fixed, so the growth is minimal.
        double growth = (distance - radius) * 0.5;
        radius += growth;
        center += offset / (float)distance * (float)growth;
    }

    private Vector3 FarthestFrom(Vector3 point, List<Triangle> triangles)
    {
        Vector3 best = point;
        float bestDistance = -1.0f;
        foreach (Triangle tri in triangles)
        {
            Consider(point, _mesh.Positions[tri.I0], ref best, ref bestDistance);
            Consider(point, _mesh.Positions[tri.I1], ref best, ref bestDistance);
            Consider(point, _mesh.Positions[tri.I2], ref best, ref bestDistance);
        }
        return best;
    }

    private static void Consider(Vector3 point, Vector3 candidate, ref Vector3 best,
        ref float bestDistance)
    {
        float distance = point.DistanceSquaredTo(candidate);
        if (distance > bestDistance)
        {
            bestDistance = distance;
            best = candidate;
        }
    }

    /// <summary>
    /// Outer and inner radius of the shell around `center` containing these triangles.
    ///
    /// Outer is a max over VERTICES, which is exact — distance to a point is convex, so it peaks at
    /// a corner. Inner is a min over TRIANGLES, which vertices cannot give: the closest point of a
    /// triangle to the centre is usually on an edge or in the face, and a vertex minimum would
    /// report the shell as thinner than it is. That error points the wrong way — it would overstate
    /// the distance to the geometry and let the selector skip detail it should have drawn.
    /// </summary>
    public Vector2 MeasureShell(Vector3 center, List<Triangle> triangles)
    {
        float outer = 0.0f;
        float inner = float.PositiveInfinity;
        foreach (Triangle tri in triangles)
        {
            Vector3 a = _mesh.Positions[tri.I0];
            Vector3 b = _mesh.Positions[tri.I1];
            Vector3 c = _mesh.Positions[tri.I2];
            outer = Math.Max(outer, Math.Max(center.DistanceTo(a),
                Math.Max(center.DistanceTo(b), center.DistanceTo(c))));
            inner = Math.Min(inner, PointTriangleDistance(center, a, b, c));
        }
        return new Vector2(outer, float.IsInfinity(inner) ? 0.0f : inner);
    }

    /// <summary>Closest distance from a point to a triangle, by region test on the plane basis.</summary>
    public static float PointTriangleDistance(Vector3 point, Vector3 a, Vector3 b, Vector3 c)
    {
        Vector3 ab = b - a;
        Vector3 ac = c - a;
        Vector3 ap = point - a;
        // The dot products come out of float32 vector maths, but every combination of them is done
        // in DOUBLE. It matters here more than anywhere
        // else in the build: vc = d1*d4 - d3*d2 is a difference of near-equal products, and when the
        // sphere centre lies almost on the surface — exactly the case an inner radius measures — the
        // cancellation in float32 swamps the result. Two leaf clusters disagreed on their inner
        // radius for precisely this reason, one of them by 40% of a value of 0.00027.
        double d1 = ab.Dot(ap);
        double d2 = ac.Dot(ap);
        if (d1 <= 0.0 && d2 <= 0.0)
            return ap.Length();
        Vector3 bp = point - b;
        double d3 = ab.Dot(bp);
        double d4 = ac.Dot(bp);
        if (d3 >= 0.0 && d4 <= d3)
            return bp.Length();
        Vector3 cp = point - c;
        double d5 = ab.Dot(cp);
        double d6 = ac.Dot(cp);
        if (d6 >= 0.0 && d5 <= d6)
            return cp.Length();
        double vc = d1 * d4 - d3 * d2;
        if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0)
        {
            double t = IsEqualApprox(d1, d3) ? 0.0 : d1 / (d1 - d3);
            return (point - (a + ab * (float)t)).Length();
        }
        double vb = d5 * d2 - d1 * d6;
        if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0)
        {
            double t = IsEqualApprox(d2, d6) ? 0.0 : d2 / (d2 - d6);
            return (point - (a + ac * (float)t)).Length();
        }
        double va = d3 * d6 - d5 * d4;
        if (va <= 0.0 && d4 - d3 >= 0.0 && d5 - d6 >= 0.0)
        {
            double denominator = (d4 - d3) + (d5 - d6);
            double w = IsZeroApprox(denominator) ? 0.0 : (d4 - d3) / denominator;
            return (point - (b + (c - b) * (float)w)).Length();
        }
        double denom = va + vb + vc;
        if (IsZeroApprox(denom))
            return ap.Length();
        return (point - (a + ab * (float)(vb / denom) + ac * (float)(vc / denom))).Length();
    }

    private static bool IsEqualApprox(double a, double b)
    {
        if (a == b)
            return true;
        double tolerance = Math.Max(1e-5 * Math.Abs(a), 1e-5);
        return Math.Abs(a - b) < tolerance;
    }

    private static bool IsZeroApprox(double value) => Math.Abs(value) < 1e-5;

    private static bool IsEqualApprox(float a, float b)
    {
        if (a == b)
            return true;
        float tolerance = Math.Max(1e-5f * Math.Abs(a), 1e-5f);
        return Math.Abs(a - b) < tolerance;
    }

    private static bool IsZeroApprox(float value) => Math.Abs(value) < 1e-5f;

    /// <summary>Smallest sphere enclosing two spheres.</summary>
    public static (Vector3 Center, float Radius) MergeSpheres(Vector3 centerA, double radiusA,
        Vector3 centerB, double radiusB)
    {
        Vector3 offset = centerB - centerA;
        // Scalars in double, the vector in float32 — the same split as the Ritter sphere above, for
        // the same reason.
        double distance = offset.Length();
        if (distance + radiusB <= radiusA)
            return (centerA, (float)radiusA);
        if (distance + radiusA <= radiusB)
            return (centerB, (float)radiusB);
        double radius = (distance + radiusA + radiusB) * 0.5;
        Vector3 center = centerA;
        if (distance > 0.0)
            center = centerA + offset / (float)distance * (float)(radius - radiusA);
        return (center, (float)radius);
    }

    public Aabb AabbFromTriangles(List<Triangle> triangles)
    {
        var min = new Vector3(float.PositiveInfinity, float.PositiveInfinity, float.PositiveInfinity);
        var max = new Vector3(float.NegativeInfinity, float.NegativeInfinity, float.NegativeInfinity);
        foreach (Triangle tri in triangles)
        {
            foreach (int vi in new[] { tri.I0, tri.I1, tri.I2 })
            {
                Vector3 v = _mesh.Positions[vi];
                min = min.Min(v);
                max = max.Max(v);
            }
        }
        return new Aabb(min, max - min);
    }

    // --- cluster construction ---

    /// <summary>Counts clusters as they are built, to give each a distinct debug hue. Creation order
    /// is deterministic, so the colouring is too.</summary>
    private int _clusterOrdinal;

    /// <summary>
    /// Builds a cluster's geometry, bounds and mesh arrays, but NOT its ArrayMesh — call Bake() for
    /// that.
    ///
    /// Split so everything expensive can run on worker threads while baking stays serial. Baking
    /// creates an engine object, and it advances the debug-hue counter, so baking in a fixed order on
    /// one thread is what keeps the build deterministic.
    ///
    /// `errorFraction` is the cluster's error relative to its own diameter, 0..1, for the debug
    /// views. It has to be passed in because the caller knows the group's shared error, which is
    /// assigned to the cluster only after construction.
    /// </summary>
    public Cluster MakeCluster(List<Triangle> triangles, int level, List<Cluster> children,
        double errorFraction = 0.0)
    {
        var cluster = new Cluster
        {
            Triangles = triangles,
            BoundaryEdges = ComputeBoundaryEdges(triangles, _mesh.NonManifoldEdges),
            TriangleCount = triangles.Count,
            Level = level,
            Children = children,
        };
        // Bounds BEFORE the mesh: baking the debug channels needs them, and computing them after
        // meant the mesh could not carry anything derived from the cluster's own size.
        cluster.LodCenter = EnclosingSphereCenter(triangles);
        Vector2 shell = MeasureShell(cluster.LodCenter, triangles);
        cluster.LodRadius = shell.X;
        cluster.LodInnerRadius = shell.Y;
        cluster.DebugErrorFraction = errorFraction;
        cluster.Prepared = PrepareSurfaces(triangles);
        return cluster;
    }

    /// <summary>
    /// Turns a cluster's prepared arrays into its ArrayMesh. Main thread only, and in a fixed order:
    /// see MakeCluster. Everything expensive already happened in PrepareSurfaces, on a worker thread;
    /// what is left is the debug-hue counter, which must see clusters in order, and one engine call
    /// per surface.
    /// </summary>
    public void Bake(Cluster cluster)
    {
        PreparedSurface[] prepared = cluster.Prepared ?? PrepareSurfaces(cluster.Triangles);

        // Everything the debug views need, baked per corner into a free custom channel, RGBA8
        // (GodotiteMesh.DebugChannel), which export strips again (godotite_export.gd).
        //
        // The tint used to be an `instance uniform`, which draws from one fixed-size buffer — roughly
        // 4096 instances — so visualising a large DAG either failed or forced the cluster size up to
        // suit the debug view rather than the geometry. A vertex channel has no such budget, and since
        // all four values are known at bake time the shader can switch between views without a
        // rebuild. It used to be the colour channel, which overwrote the source's own colours.
        //
        //   R  material tag        G  cluster hue        B  level        A  error / diameter
        //
        // The hue is golden-angle stepped so consecutive clusters land far apart on the wheel;
        // quantising it to 8 bits still leaves 256 distinguishable neighbours.
        float hue = (float)Mathf.PosMod(_clusterOrdinal * 0.6180339887498949, 1.0);
        _clusterOrdinal++;
        float levelChannel = Math.Clamp(cluster.Level / 255.0f, 0.0f, 1.0f);
        float errorChannel = (float)Math.Clamp(cluster.DebugErrorFraction, 0.0, 1.0);
        int debugChannel = _mesh.DebugChannel;

        var mesh = new ArrayMesh();
        var materials = new int[prepared.Length];
        for (int s = 0; s < prepared.Length; s++)
        {
            PreparedSurface surface = prepared[s];
            materials[s] = surface.Material;
            var arrays = new Godot.Collections.Array();
            arrays.Resize((int)Mesh.ArrayType.Max);
            arrays[(int)Mesh.ArrayType.Vertex] = surface.Positions;
            arrays[(int)Mesh.ArrayType.Normal] = surface.Normals;
            if (surface.Uvs != null)
                arrays[(int)Mesh.ArrayType.TexUV] = surface.Uvs;
            if (surface.Tangents != null)
                arrays[(int)Mesh.ArrayType.Tangent] = surface.Tangents;
            long format = 0;
            for (int c = 0; c < GodotiteMesh.ChannelCount; c++)
            {
                float[]? values = surface.Custom[c];
                if (values == null)
                    continue;
                int custom = _mesh.CustomFormat[c];
                if (c == GodotiteMesh.ColorChannel)
                {
                    var colors = new Color[values.Length / 4];
                    for (int i = 0; i < colors.Length; i++)
                        colors[i] = new Color(values[i * 4], values[i * 4 + 1], values[i * 4 + 2], values[i * 4 + 3]);
                    arrays[(int)Mesh.ArrayType.Color] = colors;
                    continue;
                }
                if (custom == GodotiteMesh.CustomRgba8Unorm)
                {
                    var bytes = new byte[values.Length];
                    for (int i = 0; i < values.Length; i++)
                        bytes[i] = (byte)Math.Clamp((int)MathF.Round(values[i] * 255.0f), 0, 255);
                    arrays[(int)Mesh.ArrayType.Custom0 + c] = bytes;
                }
                else
                {
                    arrays[(int)Mesh.ArrayType.Custom0 + c] = values;
                }
                format |= (long)custom << (GodotiteMesh.CustomShift + c * GodotiteMesh.CustomBits);
            }
            if (debugChannel >= 0)
            {
                var debug = new byte[surface.Positions.Length * 4];
                byte r = Unorm8(surface.Material / 15.0f), g = Unorm8(hue), b = Unorm8(levelChannel),
                    a = Unorm8(errorChannel);
                for (int i = 0; i < debug.Length; i += 4)
                {
                    debug[i] = r;
                    debug[i + 1] = g;
                    debug[i + 2] = b;
                    debug[i + 3] = a;
                }
                // RGBA8 unorm is format 0, so no format bits are needed.
                arrays[(int)Mesh.ArrayType.Custom0 + debugChannel] = debug;
            }
            arrays[(int)Mesh.ArrayType.Index] = surface.Indices;
            mesh.AddSurfaceFromArrays(Mesh.PrimitiveType.Triangles, arrays, null, null, (Mesh.ArrayFormat)format);
        }
        cluster.Mesh = mesh;
        cluster.SurfaceMaterials = materials;
        cluster.Prepared = null;
    }

    private static byte Unorm8(float value) => (byte)Math.Clamp((int)MathF.Round(value * 255.0f), 0, 255);

    /// <summary>
    /// One surface per material present. Clusters are deliberately NOT material-homogeneous:
    /// forcing that would make every material border a permanent group boundary, locked at every
    /// level, which is the accumulating-seam problem the group-and-resplit design exists to avoid.
    ///
    /// Position comes from the welded pool and attributes from the triangle's own corners, which is
    /// how an attribute discontinuity survives into the output instead of being averaged away.
    /// </summary>
    /// <summary>One surface's vertex and index arrays, ready for AddSurfaceFromArrays.</summary>
    public sealed class PreparedSurface
    {
        public int Material;
        public Vector3[] Positions = Array.Empty<Vector3>();
        public Vector3[] Normals = Array.Empty<Vector3>();
        public Vector2[]? Uvs;
        public float[]? Tangents;
        /// <summary>Per custom channel, then colour, four floats per vertex, or null where the mesh has
        /// none.</summary>
        public float[]?[] Custom = new float[]?[GodotiteMesh.ChannelCount];
        public int[] Indices = Array.Empty<int>();
    }

    /// <summary>A corner's attributes as raw bits, which is what SurfaceTool.Index() welds on.
    /// Tangent bits are all zero when the mesh carries none. Custom channels are folded into one
    /// 64-bit hash of their bits: up to 16 more values would make the key unwieldy, and a collision
    /// between two distinct corners at the same position, normal, UV and tangent is vanishingly
    /// unlikely.</summary>
    private readonly record struct CornerKey(int Px, int Py, int Pz, int Nx, int Ny, int Nz, int U, int V,
        int Tx, int Ty, int Tz, int Tw, long Custom);

    /// <summary>
    /// Builds one indexed surface per material present, sorted by material.
    ///
    /// Reproduces exactly what SurfaceTool + Index() made, without crossing into the engine four
    /// times per corner: corners are welded when their position, normal and UV are identical bit for
    /// bit — SurfaceTool hashes the raw bytes — and numbered in first-seen order. So corners either
    /// side of a seam keep their own normals and UVs and stay separate, as before. Plain C#, which is
    /// what lets it run on worker threads.
    /// </summary>
    private PreparedSurface[] PrepareSurfaces(List<Triangle> triangles)
    {
        var present = new List<int>();
        foreach (Triangle tri in triangles)
        {
            if (!present.Contains(tri.Material))
                present.Add(tri.Material);
        }
        present.Sort();

        bool hasUvs = _mesh.SourceHasUvs;
        bool hasTangents = _mesh.HasTangents;
        var surfaces = new PreparedSurface[present.Count];
        var positions = new List<Vector3>();
        var normals = new List<Vector3>();
        var uvs = new List<Vector2>();
        var tangents = new List<float>();
        bool hasCustom = _mesh.HasCustom;
        var custom = new List<float>?[GodotiteMesh.ChannelCount];
        for (int c = 0; c < custom.Length; c++)
            custom[c] = _mesh.CornerCustom[c].Length > 0 ? new List<float>() : null;
        var indices = new List<int>();
        var seen = new Dictionary<CornerKey, int>();
        for (int s = 0; s < present.Count; s++)
        {
            int material = present[s];
            positions.Clear();
            normals.Clear();
            uvs.Clear();
            tangents.Clear();
            foreach (List<float>? list in custom)
                list?.Clear();
            indices.Clear();
            seen.Clear();
            foreach (Triangle tri in triangles)
            {
                if (tri.Material != material)
                    continue;
                AddCorner(tri.I0, tri.C0);
                AddCorner(tri.I1, tri.C1);
                AddCorner(tri.I2, tri.C2);
            }
            surfaces[s] = new PreparedSurface
            {
                Material = material,
                Positions = positions.ToArray(),
                Normals = normals.ToArray(),
                Uvs = hasUvs ? uvs.ToArray() : null,
                Tangents = hasTangents ? tangents.ToArray() : null,
                Custom = Array.ConvertAll(custom, list => list?.ToArray()),
                Indices = indices.ToArray(),
            };
        }
        return surfaces;

        void AddCorner(int position, int corner)
        {
            Vector3 p = _mesh.Positions[position];
            Vector3 n = _mesh.CornerNormals[corner];
            Vector2 uv = hasUvs ? _mesh.CornerUvs[corner] : Vector2.Zero;
            float[] ct = _mesh.CornerTangents;
            int t = corner * 4;
            var key = new CornerKey(
                BitConverter.SingleToInt32Bits(p.X), BitConverter.SingleToInt32Bits(p.Y),
                BitConverter.SingleToInt32Bits(p.Z), BitConverter.SingleToInt32Bits(n.X),
                BitConverter.SingleToInt32Bits(n.Y), BitConverter.SingleToInt32Bits(n.Z),
                BitConverter.SingleToInt32Bits(uv.X), BitConverter.SingleToInt32Bits(uv.Y),
                hasTangents ? BitConverter.SingleToInt32Bits(ct[t]) : 0,
                hasTangents ? BitConverter.SingleToInt32Bits(ct[t + 1]) : 0,
                hasTangents ? BitConverter.SingleToInt32Bits(ct[t + 2]) : 0,
                hasTangents ? BitConverter.SingleToInt32Bits(ct[t + 3]) : 0,
                hasCustom ? CustomHash(corner) : 0);
            if (!seen.TryGetValue(key, out int index))
            {
                index = positions.Count;
                positions.Add(p);
                normals.Add(n);
                uvs.Add(uv);
                for (int c = 0; c < custom.Length; c++)
                {
                    List<float>? list = custom[c];
                    if (list == null)
                        continue;
                    float[] values = _mesh.CornerCustom[c];
                    for (int k = 0; k < 4; k++)
                        list.Add(values[corner * 4 + k]);
                }
                if (hasTangents)
                {
                    tangents.Add(ct[t]);
                    tangents.Add(ct[t + 1]);
                    tangents.Add(ct[t + 2]);
                    tangents.Add(ct[t + 3]);
                }
                seen[key] = index;
            }
            indices.Add(index);
        }
    }

    /// <summary>FNV-1a over the bits of a corner's custom channel and colour values.</summary>
    private long CustomHash(int corner)
    {
        ulong hash = 14695981039346656037UL;
        for (int c = 0; c < GodotiteMesh.ChannelCount; c++)
        {
            float[] values = _mesh.CornerCustom[c];
            if (values.Length == 0)
                continue;
            for (int k = 0; k < 4; k++)
            {
                hash ^= (uint)BitConverter.SingleToInt32Bits(values[corner * 4 + k]);
                hash *= 1099511628211UL;
            }
        }
        return (long)hash;
    }

    // --- grouping ---

    /// <summary>For each cluster, neighbour index -> boundary edges shared with it.</summary>
    public List<Dictionary<int, int>> BuildClusterAdjacency(List<Cluster> clusters)
    {
        var edgeToClusters = new Dictionary<long, List<int>>(GodotiteMesh.EdgeKeyComparer.Instance);
        var keyOrder = new List<long>();
        for (int i = 0; i < clusters.Count; i++)
        {
            foreach (Edge edge in clusters[i].BoundaryEdges)
            {
                if (!edgeToClusters.TryGetValue(edge.Key, out List<int>? sharing))
                {
                    sharing = new List<int>(2);
                    edgeToClusters[edge.Key] = sharing;
                    keyOrder.Add(edge.Key);
                }
                sharing.Add(i);
            }
        }

        var neighbours = new List<Dictionary<int, int>>(clusters.Count);
        for (int i = 0; i < clusters.Count; i++)
            neighbours.Add(new Dictionary<int, int>());
        foreach (long key in keyOrder)
        {
            List<int> sharing = edgeToClusters[key];
            if (sharing.Count < 2)
                continue;
            foreach (int a in sharing)
            {
                foreach (int b in sharing)
                {
                    if (a == b)
                        continue;
                    neighbours[a].TryGetValue(b, out int count);
                    neighbours[a][b] = count + 1;
                }
            }
        }
        return neighbours;
    }

    /// <summary>
    /// Greedily gathers clusters into adjacent groups, always taking the unused cluster sharing the
    /// most boundary edges with the group so far. A group that runs out of candidates is simply
    /// smaller; even a lone cluster forms a group of one and still gets simplified.
    /// </summary>
    public List<List<int>> GroupClusters(List<Cluster> clusters,
        List<Dictionary<int, int>> neighbours)
    {
        var clusterMaterials = new List<HashSet<int>>(clusters.Count);
        var materialOrder = new List<List<int>>(clusters.Count);
        foreach (Cluster cluster in clusters)
        {
            var present = new HashSet<int>();
            var order = new List<int>();
            foreach (Triangle tri in cluster.Triangles)
            {
                if (present.Add(tri.Material))
                    order.Add(tri.Material);
            }
            clusterMaterials.Add(present);
            materialOrder.Add(order);
        }

        var used = new bool[clusters.Count];
        var groups = new List<List<int>>();
        for (int i = 0; i < clusters.Count; i++)
        {
            if (used[i])
                continue;
            var group = new List<int> { i };
            used[i] = true;
            var groupMaterials = new HashSet<int>(clusterMaterials[i]);

            while (group.Count < ClusterGroupSize)
            {
                int best = -1;
                double bestScore = 0.0;
                foreach (int member in group)
                {
                    foreach (KeyValuePair<int, int> entry in neighbours[member])
                    {
                        int neighbour = entry.Key;
                        if (used[neighbour])
                            continue;
                        // Shared boundary edges remain the objective; a neighbour bringing a new
                        // material is discounted, so it needs proportionally more shared edges to
                        // win. The re-split scatters a new material across both halves, so this
                        // compounds up the DAG.
                        double score = entry.Value;
                        bool bringsNew = false;
                        foreach (int material in materialOrder[neighbour])
                        {
                            if (!groupMaterials.Contains(material))
                            {
                                bringsNew = true;
                                break;
                            }
                        }
                        if (bringsNew)
                            score *= 1.0 - Math.Clamp(MaterialSplitPenalty * 4.0, 0.0, 0.9);
                        if (score > bestScore)
                        {
                            bestScore = score;
                            best = neighbour;
                        }
                    }
                }
                if (best == -1 && BridgingActive)
                    best = NearestUnusedCluster(clusters, group, used);
                if (best == -1)
                    break;
                group.Add(best);
                used[best] = true;
                foreach (int material in materialOrder[best])
                    groupMaterials.Add(material);
            }
            groups.Add(group);
        }
        return groups;
    }

    /// <summary>
    /// Nearest still-unused cluster to any member, by bounding-sphere centre, and only within reach.
    /// Without the reach test this fires on CONNECTED meshes too — "no unused neighbour" merely
    /// means the group ran out of free adjacent clusters, which happens routinely at the end of a
    /// level — and then drags in a cluster from across the model.
    /// </summary>
    private int NearestUnusedCluster(List<Cluster> clusters, List<int> group, bool[] used)
    {
        int best = -1;
        double bestDistance = double.PositiveInfinity;
        for (int candidate = 0; candidate < clusters.Count; candidate++)
        {
            if (used[candidate])
                continue;
            foreach (int member in group)
            {
                double distance = clusters[member].LodCenter
                    .DistanceSquaredTo(clusters[candidate].LodCenter);
                if (distance >= bestDistance)
                    continue;
                double reach = BridgeJumpRadius * 2.0
                    * ((double)clusters[member].LodRadius + clusters[candidate].LodRadius);
                if (distance > reach * reach)
                    continue;
                bestDistance = distance;
                best = candidate;
            }
        }
        return best;
    }

    // --- merge and split ---

    /// <summary>
    /// Every child's triangles in one list, in group order. Triangles are structs, so this is a
    /// copy: the simplifier edits the group's list in place and cannot reach the children's. When
    /// they were objects, a shallow copy aliased them and silently corrupted every child cluster once
    /// its parent was built.
    /// </summary>
    private static List<Triangle> MergeTriangles(List<Cluster> children)
    {
        int count = 0;
        foreach (Cluster child in children)
            count += child.Triangles.Count;
        var merged = new List<Triangle>(count);
        foreach (Cluster child in children)
            merged.AddRange(child.Triangles);
        return merged;
    }

    /// <summary>
    /// Splits into spatially coherent parts by sorting centroids along the longest AABB axis.
    /// The original position rides along as a tie-break, making this a stable sort by construction:
    /// coincident centroids are common and ordering them by sort-implementation detail cannot be
    /// reproduced across implementations.
    /// </summary>
    private List<List<Triangle>> SplitTriangles(List<Triangle> triangles, int count)
    {
        var parts = new List<List<Triangle>>();
        if (count <= 1 || triangles.Count < count)
        {
            parts.Add(triangles);
            return parts;
        }

        Aabb aabb = AabbFromTriangles(triangles);
        int axis = 0;
        if (aabb.Size.Y >= aabb.Size.X && aabb.Size.Y >= aabb.Size.Z)
            axis = 1;
        else if (aabb.Size.Z >= aabb.Size.X && aabb.Size.Z >= aabb.Size.Y)
            axis = 2;

        var keyed = new List<(float Value, int Position)>(triangles.Count);
        for (int k = 0; k < triangles.Count; k++)
        {
            Triangle tri = triangles[k];
            Vector3 centroid = (_mesh.Positions[tri.I0] + _mesh.Positions[tri.I1]
                + _mesh.Positions[tri.I2]) / 3.0f;
            keyed.Add((centroid[axis], k));
        }
        keyed.Sort(static (a, b) =>
        {
            int byValue = a.Value.CompareTo(b.Value);
            return byValue != 0 ? byValue : a.Position.CompareTo(b.Position);
        });

        for (int partIndex = 0; partIndex < count; partIndex++)
        {
            int from = partIndex * keyed.Count / count;
            int to = (partIndex + 1) * keyed.Count / count;
            var part = new List<Triangle>(Math.Max(to - from, 0));
            for (int k = from; k < to; k++)
                part.Add(triangles[keyed[k].Position]);
            parts.Add(part);
        }
        return parts;
    }

    // --- dropping ---

    /// <summary>
    /// Drops whole connected pieces below `maxRadius`. Both the piece boundaries and the
    /// containment test are decided from the geometry present in THIS call: labels carried over
    /// from the source mesh go stale the moment simplification starts, and comparing stale triangle
    /// counts is what once tore holes in the surface.
    ///
    /// A piece touching an edge another group holds the other side of continues outside this call,
    /// whatever its triangle count says.
    /// </summary>
    private double DropSmall(List<Triangle> triangles, double maxRadius, List<Edge> lockedEdges,
        out List<Triangle> survivors)
    {
        survivors = triangles;
        int[] labels = LabelLocalComponents(triangles);

        var interfaceVertices = new HashSet<int>();
        foreach (Edge locked in lockedEdges)
        {
            if (!_mesh.MeshBoundaryEdges.Contains(locked.Key))
            {
                interfaceVertices.Add(locked.I0);
                interfaceVertices.Add(locked.I1);
            }
        }
        // A piece touching a position a neighbouring cell shares continues in that cell.
        if (_mesh.Pinned.Length > 0)
        {
            foreach (Triangle tri in triangles)
            {
                if (_mesh.Pinned[tri.I0])
                    interfaceVertices.Add(tri.I0);
                if (_mesh.Pinned[tri.I1])
                    interfaceVertices.Add(tri.I1);
                if (_mesh.Pinned[tri.I2])
                    interfaceVertices.Add(tri.I2);
            }
        }

        var escapes = new HashSet<int>();
        for (int t = 0; t < triangles.Count; t++)
        {
            Triangle tri = triangles[t];
            if (interfaceVertices.Contains(tri.I0) || interfaceVertices.Contains(tri.I1)
                || interfaceVertices.Contains(tri.I2))
            {
                escapes.Add(labels[t]);
            }
        }

        var present = new List<int>();
        var seen = new HashSet<int>();
        foreach (int label in labels)
        {
            if (seen.Add(label))
                present.Add(label);
        }

        double[] radii = ComponentRadii(triangles, labels, present.Count);
        var droppable = new HashSet<int>();
        double largestRadius = -1.0;
        int largestComponent = -1;
        foreach (int component in present)
        {
            double radius = radii[component];
            if (radius > largestRadius)
            {
                largestRadius = radius;
                largestComponent = component;
            }
            if (escapes.Contains(component))
                continue;
            if (radius <= maxRadius)
                droppable.Add(component);
        }

        if (droppable.Count == 0)
            return 0.0;
        // Keep something rather than emit an empty group: its children would have no parent to fold
        // into, and the DAG needs that edge to exist.
        if (droppable.Count == present.Count)
        {
            droppable.Remove(largestComponent);
            if (droppable.Count == 0)
                return 0.0;
        }

        var kept = new List<Triangle>();
        double worst = 0.0;
        foreach (int component in droppable)
            worst = Math.Max(worst, radii[component]);
        for (int t = 0; t < triangles.Count; t++)
        {
            if (!droppable.Contains(labels[t]))
                kept.Add(triangles[t]);
        }
        survivors = kept;
        return worst;
    }

    /// <summary>Connected pieces by shared EDGE — two pieces meeting at a single point are not
    /// joined, and treating them as one would make a droppable piece look like it escapes.</summary>
    private static int[] LabelLocalComponents(List<Triangle> triangles)
    {
        // Union-find over triangles, joined wherever two share an edge. This used to build a
        // dictionary holding a list per edge and flood-fill through it — an allocation per edge,
        // tens of thousands per group, on every group at every level.
        //
        // The labels come out identical to that flood fill's: it seeded components in ascending
        // triangle order, so each component's label is its rank by lowest triangle index, which is
        // exactly what numbering roots in first-seen order below produces.
        var parent = new int[triangles.Count];
        for (int t = 0; t < parent.Length; t++)
            parent[t] = t;
        var firstOnEdge = new Dictionary<long, int>(triangles.Count * 2, GodotiteMesh.EdgeKeyComparer.Instance);
        for (int t = 0; t < triangles.Count; t++)
        {
            Triangle tri = triangles[t];
            JoinOnEdge(firstOnEdge, parent, EdgeKey(tri.I0, tri.I1), t);
            JoinOnEdge(firstOnEdge, parent, EdgeKey(tri.I1, tri.I2), t);
            JoinOnEdge(firstOnEdge, parent, EdgeKey(tri.I2, tri.I0), t);
        }

        var labels = new int[triangles.Count];
        var labelOfRoot = new int[triangles.Count];
        Array.Fill(labelOfRoot, -1);
        int next = 0;
        for (int t = 0; t < triangles.Count; t++)
        {
            int root = Find(parent, t);
            if (labelOfRoot[root] == -1)
                labelOfRoot[root] = next++;
            labels[t] = labelOfRoot[root];
        }
        return labels;
    }

    private static void JoinOnEdge(Dictionary<long, int> firstOnEdge, int[] parent, long key, int triangle)
    {
        if (!firstOnEdge.TryGetValue(key, out int first))
        {
            firstOnEdge[key] = triangle;
            return;
        }
        int a = Find(parent, first);
        int b = Find(parent, triangle);
        if (a != b)
            parent[b] = a;
    }

    private static int Find(int[] parent, int t)
    {
        while (parent[t] != t)
        {
            parent[t] = parent[parent[t]];
            t = parent[t];
        }
        return t;
    }

    /// <summary>
    /// Every component's radius — farthest vertex from its triangles' mean centroid — in two passes.
    ///
    /// Computed one component at a time, this rescanned every triangle per component, which is
    /// quadratic on a fragmented group. The arithmetic is unchanged: each component still sums its
    /// own triangles in ascending order, so every radius comes out bit-identical.
    /// </summary>
    private double[] ComponentRadii(List<Triangle> triangles, int[] labels, int componentCount)
    {
        var centroids = new Vector3[componentCount];
        var counts = new int[componentCount];
        for (int t = 0; t < triangles.Count; t++)
        {
            Triangle tri = triangles[t];
            centroids[labels[t]] += (_mesh.Positions[tri.I0] + _mesh.Positions[tri.I1]
                + _mesh.Positions[tri.I2]) / 3.0f;
            counts[labels[t]]++;
        }
        for (int c = 0; c < componentCount; c++)
        {
            if (counts[c] > 0)
                centroids[c] /= counts[c];
        }
        var radii = new double[componentCount];
        for (int t = 0; t < triangles.Count; t++)
        {
            Triangle tri = triangles[t];
            Vector3 centroid = centroids[labels[t]];
            double radius = radii[labels[t]];
            radius = Math.Max(radius, centroid.DistanceTo(_mesh.Positions[tri.I0]));
            radius = Math.Max(radius, centroid.DistanceTo(_mesh.Positions[tri.I1]));
            radius = Math.Max(radius, centroid.DistanceTo(_mesh.Positions[tri.I2]));
            radii[labels[t]] = radius;
        }
        return radii;
    }

    // --- the build ---

    /// <summary>
    /// How many clusters a group's simplified geometry should be re-split into.
    ///
    /// Chosen from the triangles that actually came out, so cluster size stays near the target going
    /// up the DAG. A flat 2 only holds size constant if the group has exactly 4 clusters AND
    /// simplification reaches its 50% target: g clusters of c triangles merge to g*c, simplify to
    /// 0.5*g*c, and split in two give parts of 0.25*g*c.
    ///
    /// Both conditions fail in practice, in opposite directions — terrain groups average 3.9 falling
    /// to 2.2, decaying cluster size from 256 triangles to 60; Sponza holds group size but cannot
    /// reach the simplification target against locked material boundaries, inflating clusters from
    /// 245 to 2,888.
    ///
    /// The clamp is the progress guarantee: a group of g clusters must yield fewer than g, or the
    /// level does not shrink and the build cannot terminate.
    /// </summary>
    private int SplitCountFor(int triangleCount, int groupSize)
    {
        int target = Math.Max(MinClusterTriangles, 1);
        int parts = Math.Max(1, (int)Math.Round((double)triangleCount / target,
            MidpointRounding.AwayFromZero));
        return Math.Min(parts, Math.Max(1, groupSize - 1));
    }

    /// <summary>Rebuilds the mesh boundary from the union of these clusters' triangles: one incident
    /// triangle across the whole level means nothing is on the other side.</summary>
    internal void RecomputeMeshBoundaryEdges(List<Cluster> clusters)
    {
        // A boundary edge is a run of one in the half-edge grouping, a non-manifold edge a run of three
        // or more. Both are only ever queried, never iterated, so the order they are filled in cannot
        // reach the output.
        var triangleOffset = new int[clusters.Count + 1];
        for (int c = 0; c < clusters.Count; c++)
            triangleOffset[c + 1] = triangleOffset[c] + clusters[c].Triangles.Count;
        int halfEdges = triangleOffset[clusters.Count] * 3;
        var lower = new int[halfEdges];
        var upper = new int[halfEdges];
        Parallel.For(0, clusters.Count, c =>
        {
            List<Triangle> triangles = clusters[c].Triangles;
            for (int t = 0; t < triangles.Count; t++)
            {
                Triangle tri = triangles[t];
                GodotiteMesh.SetHalfEdges(tri.I0, tri.I1, tri.I2, (triangleOffset[c] + t) * 3,
                    lower, upper);
            }
        });
        int positionCount = _mesh.Positions.Length;
        long[] sorted = GodotiteMesh.GroupHalfEdges(positionCount, lower, upper,
            out int[] groupStart);

        var boundary = new HashSet<long>(GodotiteMesh.EdgeKeyComparer.Instance);
        var nonManifold = new Dictionary<long, int>(GodotiteMesh.EdgeKeyComparer.Instance);
        for (int v = 0; v < positionCount; v++)
        {
            int end = groupStart[v + 1];
            for (int a = groupStart[v]; a < end;)
            {
                int b = a + 1;
                while (b < end && (sorted[b] >> 32) == (sorted[a] >> 32))
                    b++;
                if (b - a == 1)
                    boundary.Add(EdgeKey(v, (int)(sorted[a] >> 32)));
                else if (b - a >= 3)
                    nonManifold[EdgeKey(v, (int)(sorted[a] >> 32))] = b - a;
                a = b;
            }
        }
        _mesh.MeshBoundaryEdges = boundary;
        _mesh.NonManifoldEdges = nonManifold;
    }

    private GroupResult BuildGroup(List<int> group, List<Cluster> clusters)
    {
        var result = new GroupResult();
        int level = 0;
        foreach (int index in group)
        {
            Cluster child = clusters[index];
            result.Children.Add(child);
            level = Math.Max(level, child.Level + 1);
        }
        List<Triangle> merged = MergeTriangles(result.Children);

        // Locked edges are the boundary of the merged set, so seams between the group's own
        // clusters are interior here and simplify freely.
        List<Edge> lockedEdges = ComputeBoundaryEdges(merged, _mesh.NonManifoldEdges);

        double droppedRadius = 0.0;
        if (DropSmallComponents && DropComponentFraction > 0.0)
        {
            // Relative to the group's own extent, so "small" scales with the thing being simplified
            // rather than with the model.
            double extent = MeasureShell(EnclosingSphereCenter(merged), merged).X;
            droppedRadius = DropSmall(merged, extent * DropComponentFraction, lockedEdges,
                out List<Triangle> survivors);
            if (droppedRadius > 0.0)
            {
                merged = survivors;
                lockedEdges = ComputeBoundaryEdges(merged, _mesh.NonManifoldEdges);
            }
        }

        var simplifier = new GodotiteSimplifier(_mesh)
        {
            CoarsenSeamCurves = CoarsenSeamCurves,
            CoarsenMeshBoundaries = CoarsenMeshBoundaries,
            UvDensityLimit = UvDensityLimit,
        };
        GodotiteSimplifier.Result simplified = simplifier.Simplify(merged, lockedEdges,
            (int)(merged.Count * 0.5));
        result.Rejects = simplified.Rejects;

        result.Error = simplified.MaxError;
        // Start from a tight sphere around the group's OWN geometry rather than from a child's.
        // The parent spans the same region as its children, so this usually already contains them
        // and no expansion happens — which is what stops slack compounding level by level.
        result.Center = EnclosingSphereCenter(simplified.Triangles);
        result.Radius = MeasureShell(result.Center, simplified.Triangles).X;
        // Clamp the quadric term first, then charge for what was dropped. The other order lets the
        // clamp deflate a legitimate dropped-geometry error back down to the cluster's own size.
        result.Error = Math.Min(result.Error, result.Radius * 2.0);
        result.Error = Math.Max(result.Error, droppedRadius);
        foreach (Cluster child in result.Children)
        {
            result.Error = Math.Max(result.Error, child.Error);
            (Vector3 center, float radius) = MergeSpheres(result.Center, result.Radius,
                child.LodCenter, child.LodRadius);
            result.Center = center;
            result.Radius = radius;
        }

        // The parent's shell must CONTAIN every child's shell, which is what keeps projected error
        // monotonic. Both terms folded in here can only shrink the inner radius, and shrinking is
        // the safe direction: it can only make the estimated distance smaller, hence projected error
        // larger, hence more refinement. Never a hole.
        result.InnerRadius = MeasureShell(result.Center, simplified.Triangles).Y;
        foreach (Cluster child in result.Children)
        {
            double offset = result.Center.DistanceTo(child.LodCenter);
            result.InnerRadius = Math.Min(result.InnerRadius,
                Math.Max(child.LodInnerRadius - offset, 0.0));
        }

        List<List<Triangle>> parts = SplitTriangles(simplified.Triangles,
            SplitCountFor(simplified.Triangles.Count, group.Count));
        foreach (List<Triangle> part in parts)
        {
            if (part.Count == 0)
                continue;
            // Error relative to the cluster's own diameter: scale-free, and already bounded by the
            // clamp that caps error at twice the radius.
            double errorFraction = result.Radius > 0.0
                ? Math.Clamp(result.Error / (2.0 * result.Radius), 0.0, 1.0)
                : 0.0;
            Cluster partCluster = MakeCluster(part, level, result.Children, errorFraction);
            partCluster.Error = result.Error;
            partCluster.LodCenter = result.Center;
            partCluster.LodRadius = result.Radius;
            partCluster.LodInnerRadius = result.InnerRadius;
            result.Clusters.Add(partCluster);
        }
        return result;
    }

    public void BuildClusterDag(List<Cluster> clusters)
    {
        int levelNumber = 0;
        while (clusters.Count > 1)
        {
            levelNumber++;
            long levelStarted = System.Diagnostics.Stopwatch.GetTimestamp();
            // Reclassify the mesh boundary against the geometry ACTUALLY IN HAND. The set decides
            // whether a locked edge is a coarsenable outline or a cluster interface that must never
            // move, and it was computed once from the source — so an edge created BY coarsening was
            // absent from it, came back as an interface, and pinned both endpoints for the rest of
            // the build. On Sponza the outline froze at ~8,200 edges from level 3, 5,200 of them
            // these phantoms, and simplification plateaued with it.
            RecomputeMeshBoundaryEdges(clusters);
            List<Dictionary<int, int>> neighbours = BuildClusterAdjacency(clusters);
            List<List<int>> groups = GroupClusters(clusters, neighbours);


            var sizes = new Godot.Collections.Array();
            int trianglesIn = 0;
            foreach (Cluster cluster in clusters)
                trianglesIn += cluster.Triangles.Count;
            foreach (List<int> group in groups)
                sizes.Add(group.Count);

            // Groups within a level are independent: each reads mesh state that is fixed for the
            // level (the mesh boundary was recomputed above, before any of them start) and writes
            // only its own result, simplifying its own copies of its children's triangles. So they
            // run in parallel, and everything that depends on ORDER happens afterwards on this
            // thread, walking the results in group order — which is what keeps the output identical
            // to a serial build.
            var results = new GroupResult[groups.Count];
            Progress?.BeginStep($"{LevelLabel}level {levelNumber}, groups simplified", groups.Count);
            Parallel.For(0, groups.Count, g =>
            {
                results[g] = BuildGroup(groups[g], clusters);
                Progress?.Advance();
            });
            Progress?.EndStep();

            var newClusters = new List<Cluster>();
            foreach (GroupResult result in results)
            {
                foreach (Cluster part in result.Clusters)
                    QueueBake(part);
                foreach (Cluster child in result.Children)
                {
                    child.ParentError = result.Error;
                    child.ParentCenter = result.Center;
                    child.ParentRadius = result.Radius;
                    child.ParentInnerRadius = result.InnerRadius;
                }
                newClusters.AddRange(result.Clusters);
            }

            // Only reachable if grouping found no adjacency at all. Union everything into a single
            // root rather than looping forever; returning clusters[0] would hand back a "root"
            // covering only part of the mesh.
            int trianglesOut = 0;
            foreach (Cluster cluster in newClusters)
                trianglesOut += cluster.Triangles.Count;
            LevelStats.Add(new Godot.Collections.Dictionary
            {
                { "clusters_in", clusters.Count },
                { "clusters_out", newClusters.Count },
                { "groups", groups.Count },
                { "triangles_in", trianglesIn },
                { "triangles_out", trianglesOut },
                { "group_sizes", sizes },
            });
            if (LogRejects)
                Progress?.Message($"{LevelLabel}level {levelNumber} collapses: {RejectSummary(results)}");
            Progress?.Message($"{LevelLabel}level {levelNumber}: {clusters.Count} -> {newClusters.Count} clusters, "
                + $"{trianglesIn} -> {trianglesOut} triangles, "
                + $"{System.Diagnostics.Stopwatch.GetElapsedTime(levelStarted).TotalSeconds:F1} s"
                + BuildProgress.Memory());

            // A cell stops here, its clusters left for the merge to group across the cells.
            if (StopAtTriangles > 0 && (trianglesOut <= StopAtTriangles || newClusters.Count >= clusters.Count))
            {
                foreach (Cluster cluster in clusters)
                    cluster.Release();
                clusters = newClusters;
                CollectGarbage();
                break;
            }

            if (newClusters.Count >= clusters.Count)
            {
                var allTriangles = new List<Triangle>();
                foreach (Cluster cluster in clusters)
                    allTriangles.AddRange(cluster.Triangles);
                int level = 0;
                foreach (Cluster cluster in clusters)
                    level = Math.Max(level, cluster.Level + 1);
                Cluster root = MakeCluster(allTriangles, level, new List<Cluster>(clusters));
                QueueBake(root);
                foreach (Cluster cluster in clusters)
                {
                    root.Error = Math.Max(root.Error, cluster.Error);
                    (Vector3 center, float radius) = MergeSpheres(root.LodCenter, root.LodRadius,
                        cluster.LodCenter, cluster.LodRadius);
                    root.LodCenter = center;
                    root.LodRadius = radius;
                }
                foreach (Cluster cluster in clusters)
                {
                    double offset = root.LodCenter.DistanceTo(cluster.LodCenter);
                    root.LodInnerRadius = Math.Min(root.LodInnerRadius,
                        Math.Max(cluster.LodInnerRadius - offset, 0.0));
                    cluster.ParentError = root.Error;
                    cluster.ParentCenter = root.LodCenter;
                    cluster.ParentRadius = root.LodRadius;
                    cluster.ParentInnerRadius = root.LodInnerRadius;
                }
                clusters = new List<Cluster> { root };
                break;
            }
            foreach (Cluster cluster in clusters)
                cluster.Release();
            clusters = newClusters;
            CollectGarbage();
        }
        if (StopAtTriangles > 0)
        {
            Top = clusters;
            return;
        }
        Root = clusters.Count > 0 ? clusters[0] : null;
        CollectLeavesFirst();
    }

    /// <summary>
    /// A full, compacting collection, at points where a lot has just become garbage: the end of each
    /// level, and the end of leaf clustering. Left to itself the collector let the heap grow to about
    /// twice what was live, and never returned the difference.
    /// </summary>
    public static void CollectGarbage()
    {
        System.Runtime.GCSettings.LargeObjectHeapCompactionMode =
            System.Runtime.GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
    }

    /// <summary>
    /// Set GODOTITE_REJECTS=1 to log, per level, how many collapses were applied and why the rest
    /// were refused. A level that stops halving shows which rule is holding it: how thin pieces
    /// along a first shoreline cut were found to stall the whole DAG.
    /// </summary>
    private static readonly bool LogRejects = System.Environment.GetEnvironmentVariable("GODOTITE_REJECTS") == "1";

    private static string RejectSummary(GroupResult[] results)
    {
        var totals = new int[(int)GodotiteSimplifier.Reject.Count];
        foreach (GroupResult result in results)
        {
            for (int r = 0; r < Math.Min(totals.Length, result.Rejects.Length); r++)
                totals[r] += result.Rejects[r];
        }
        var parts = new List<string>();
        for (int r = 0; r < totals.Length; r++)
            parts.Add($"{((GodotiteSimplifier.Reject)r).ToString().ToLowerInvariant()} {totals[r]:N0}");
        return string.Join(", ", parts);
    }

    /// <summary>
    /// Clusters ordered leaves first, which IS the numbering in the packed DAG. Sorted by level with
    /// ties broken by discovery order, so the numbering depends only on the traversal and not on the
    /// sort implementation.
    /// </summary>
    private void CollectLeavesFirst()
    {
        Ordered = new List<Cluster>();
        if (Root == null)
            return;
        var seen = new HashSet<Cluster>();
        var discovery = new Dictionary<Cluster, int>();
        var stack = new Stack<Cluster>();
        stack.Push(Root);
        while (stack.Count > 0)
        {
            Cluster cluster = stack.Pop();
            if (!seen.Add(cluster))
                continue;
            discovery[cluster] = Ordered.Count;
            Ordered.Add(cluster);
            foreach (Cluster child in cluster.Children)
                stack.Push(child);
        }
        Ordered.Sort((a, b) =>
        {
            int byLevel = a.Level.CompareTo(b.Level);
            return byLevel != 0 ? byLevel : discovery[a].CompareTo(discovery[b]);
        });
    }
}
