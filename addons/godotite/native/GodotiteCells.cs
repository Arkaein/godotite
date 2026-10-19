using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

namespace Godotite;

using Triangle = GodotiteSimplifier.Triangle;

/// <summary>
/// The chunked build, for meshes too large to build whole: build memory then follows the size of a
/// cell rather than of the mesh. The same shape as Nexus's out-of-core multi-triangulation builds
/// (Ponchio, Cignoni), which Nanite's design descends from.
///
/// 1. A pre-pass over the source arrays welds positions over the whole mesh and splits the
///    triangles into cells of at most CellTriangles, halving along the longest axis of their
///    centroids. Positions used by more than one cell are the border.
/// 2. Each cell in turn is parsed as a mesh of its own, its border positions pinned: the simplifier
///    and small-piece dropping treat them as a cluster interface, so they never move and every
///    cell meets its neighbours exactly at every level. The cell is built down to a sixteenth of
///    its triangles (CellReduction); its clusters are baked as they are made, and only its top
///    level, with the data of the positions that level uses, outlives it.
/// 3. The band, every triangle touching a border position, is parsed once, for the border
///    positions' quadrics, seams and corners exactly as the whole mesh would give them: a cell sees
///    only its own side of them.
/// 4. The merge assembles one mesh from the cells' top levels and the band, and builds on to the
///    root as an unchunked build would. The cell borders are free from here.
///
/// The cost is a line of full-detail triangles along each border up to the merge, and a DAG shaped
/// differently from an unchunked build's. Deterministic like the rest: cells are built in order.
/// </summary>
public sealed class GodotiteCellBuild
{
    /// <summary>Each cell is built down to this fraction of its triangles before the merge, so the
    /// merged mesh holds about this fraction of the source.</summary>
    public const int CellReduction = 16;

    public int CellTriangles = 4_000_000;
    public float AttributeWeight;
    public float UvDistortionWeight;
    public bool IncludeTangents;
    public float CustomWeight;
    public float ColorWeight;
    public Func<GodotiteMesh, GodotiteClustering> NewClustering = null!;
    public Func<GodotiteMesh, GodotiteDag> NewDag = null!;
    /// <summary>Hands the DAG to the builder as soon as it exists, so the main thread bakes clusters
    /// while the cells are still building.</summary>
    public Action<GodotiteDag> Publish = null!;

    private readonly GodotiteMesh _source;
    private readonly BuildProgress _progress;
    private GodotiteDag? _dag;

    public GodotiteCellBuild(GodotiteMesh source, BuildProgress progress)
    {
        _source = source;
        _progress = progress;
    }

    public void Build()
    {
        _progress.Message($"native: planning cells{BuildProgress.Memory()}");
        GodotiteMesh.CellPlan plan = _source.PlanCells(CellTriangles, IncludeTangents);
        _progress.Message($"native: {plan.Cells.Count} cells of up to {CellTriangles:N0} triangles, "
            + $"{plan.BorderCount:N0} positions on their borders, a band of {plan.Band.Length:N0} triangles "
            + $"round them{BuildProgress.Memory()}");

        // The band first: the border positions' data, as the merge will need it.
        var parts = new List<GodotiteMesh.MeshPart> { BorderPart(plan) };
        GodotiteDag.CollectGarbage();

        var top = new List<GodotiteDag.Cluster>();
        int[] customFormat = Array.Empty<int>();
        bool bridging = false;
        for (int c = 0; c < plan.Cells.Count; c++)
        {
            string label = $"cell {c + 1}/{plan.Cells.Count}, ";
            _progress.Message($"native: {label}parsing {plan.Cells[c].Length:N0} triangles{BuildProgress.Memory()}");
            GodotiteMesh cell = Parse(plan, plan.Cells[c]);
            cell.Pinned = new bool[cell.Positions.Length];
            for (int p = 0; p < cell.Positions.Length; p++)
                cell.Pinned[p] = plan.Border[cell.GlobalPosition[p]];
            customFormat = (int[])cell.CustomFormat.Clone();

            List<GodotiteDag.Cluster> leaves = Leaves(cell, label, out bool cellBridging);
            bridging |= cellBridging;
            GodotiteDag dag = _dag!;
            dag.StopAtTriangles = Math.Max(plan.Cells[c].Length / CellReduction, 1);
            dag.LevelLabel = label;
            _progress.Message($"native: {label}building DAG{BuildProgress.Memory()}");
            dag.BuildClusterDag(leaves);

            // The top level, carried to the merge in the whole mesh's numbering, with the data of its
            // positions; the band carries the border's.
            var used = new SortedSet<int>();
            foreach (GodotiteDag.Cluster cluster in dag.Top)
            {
                foreach (Triangle tri in cluster.Triangles)
                {
                    if (!cell.Pinned[tri.I0])
                        used.Add(tri.I0);
                    if (!cell.Pinned[tri.I1])
                        used.Add(tri.I1);
                    if (!cell.Pinned[tri.I2])
                        used.Add(tri.I2);
                }
            }
            var part = new GodotiteMesh.MeshPart();
            cell.Export(used, part);
            parts.Add(part);
            foreach (GodotiteDag.Cluster cluster in dag.Top)
            {
                List<Triangle> triangles = cluster.Triangles;
                for (int t = 0; t < triangles.Count; t++)
                    triangles[t] = Renumber(triangles[t], cell.GlobalPosition, cell.GlobalCorner);
                top.Add(cluster);
            }
            _progress.Message($"native: {label}{dag.Top.Count} clusters carried to the merge{BuildProgress.Memory()}");
            dag.Top = new List<GodotiteDag.Cluster>();
            GodotiteDag.CollectGarbage();
        }

        // The merge: one mesh from every cell's top level, built on to the root.
        _source.ReleaseSource();
        GodotiteMesh merged = GodotiteMesh.Assemble(parts, plan, customFormat, IncludeTangents, AttributeWeight,
            UvDistortionWeight, CustomWeight, ColorWeight, out Dictionary<int, int> positionOf,
            out Dictionary<int, int> cornerOf);
        parts.Clear();
        foreach (GodotiteDag.Cluster cluster in top)
        {
            List<Triangle> triangles = cluster.Triangles;
            for (int t = 0; t < triangles.Count; t++)
            {
                Triangle tri = triangles[t];
                triangles[t] = new Triangle(positionOf[tri.I0], positionOf[tri.I1], positionOf[tri.I2])
                {
                    C0 = cornerOf[tri.C0],
                    C1 = cornerOf[tri.C1],
                    C2 = cornerOf[tri.C2],
                    Material = tri.Material,
                };
            }
        }
        int mergedTriangles = 0;
        foreach (GodotiteDag.Cluster cluster in top)
            mergedTriangles += cluster.Triangles.Count;
        _progress.Message($"native: merging {top.Count} clusters, {mergedTriangles:N0} triangles over "
            + $"{merged.Positions.Length:N0} positions{BuildProgress.Memory()}");

        GodotiteDag final = _dag!;
        final.UseMesh(merged);
        final.StopAtTriangles = 0;
        final.LevelLabel = "merged, ";
        final.BridgingActive = bridging;
        final.RecomputeMeshBoundaryEdges(top);
        foreach (GodotiteDag.Cluster cluster in top)
            cluster.BoundaryEdges = GodotiteDag.ComputeBoundaryEdges(cluster.Triangles, merged.NonManifoldEdges);
        final.BuildClusterDag(top);
    }

    /// <summary>A cell's leaf clusters, made on the DAG, which is created for the first cell. Its own
    /// method so the clustering and adjacency are unreachable once it returns.</summary>
    private List<GodotiteDag.Cluster> Leaves(GodotiteMesh cell, string label, out bool bridging)
    {
        cell.BuildTriangleAdjacency();
        _progress.Message($"native: {label}leaf clustering{BuildProgress.Memory()}");
        GodotiteClustering clustering = NewClustering(cell);
        clustering.CreateLeafGroups();
        if (_dag == null)
        {
            _dag = NewDag(cell);
            Publish(_dag);
        }
        else
        {
            _dag.UseMesh(cell);
        }
        _dag.MinClusterTriangles = clustering.MinClusterTriangles;
        _dag.BridgingActive = clustering.BridgingActive;
        bridging = clustering.BridgingActive;
        List<GodotiteDag.Cluster> leaves = GodotiteNative.MakeLeaves(cell, _dag, clustering.Groups, _progress);
        cell.ReleaseAdjacency();
        return leaves;
    }

    /// <summary>The border positions' data, from the band. Its own method so the band's mesh is
    /// unreachable once it returns.</summary>
    private GodotiteMesh.MeshPart BorderPart(GodotiteMesh.CellPlan plan)
    {
        GodotiteMesh band = Parse(plan, plan.Band);
        var border = new List<int>();
        for (int p = 0; p < band.Positions.Length; p++)
        {
            if (plan.Border[band.GlobalPosition[p]])
                border.Add(p);
        }
        var part = new GodotiteMesh.MeshPart();
        band.Export(border, part);
        return part;
    }

    private GodotiteMesh Parse(GodotiteMesh.CellPlan plan, int[] triangles)
        => _source.SubMesh(triangles, plan, AttributeWeight, UvDistortionWeight, IncludeTangents, CustomWeight,
            ColorWeight);

    private static Triangle Renumber(Triangle tri, int[] positions, int[] corners)
        => new(positions[tri.I0], positions[tri.I1], positions[tri.I2])
        {
            C0 = corners[tri.C0],
            C1 = corners[tri.C1],
            C2 = corners[tri.C2],
            Material = tri.Material,
        };
}

/// <summary>The chunked build's side of the parsed mesh (GodotiteCellBuild).</summary>
public sealed partial class GodotiteMesh
{
    /// <summary>Per position, true where a neighbouring cell of a chunked build shares it: it must
    /// never move. Empty outside a cell.</summary>
    public bool[] Pinned = Array.Empty<bool>();

    /// <summary>For a cell, the band or the merge: each position's and corner's number in the whole
    /// mesh. Empty for a mesh parsed whole.</summary>
    public int[] GlobalPosition = Array.Empty<int>();
    public int[] GlobalCorner = Array.Empty<int>();

    // The whole mesh's values, which a part of it must use to price collapses the same way.
    private double _forcedAttributeLength;
    private bool _forceSourceHasUvs;

    public int SourceTriangleCount()
    {
        long count = 0;
        foreach (SourceSurface source in _source)
            count += source.Indices.Length / 3;
        return (int)Math.Min(count, int.MaxValue);
    }

    /// <summary>Frees the source arrays once every cell has been parsed from them.</summary>
    public void ReleaseSource() => _source = Array.Empty<SourceSurface>();

    /// <summary>What a chunked build decides over the whole mesh before any cell. Triangles and
    /// corners are numbered as an unchunked parse numbers them: surface by surface, in source order.</summary>
    public sealed class CellPlan
    {
        public int[] SurfaceCornerOffset = Array.Empty<int>();
        public int[] SurfaceTriangleOffset = Array.Empty<int>();
        /// <summary>Each corner's welded position over the whole mesh, and each position's
        /// coordinates: its first corner's, as an unchunked weld gives.</summary>
        public int[] CornerPosition = Array.Empty<int>();
        public Vector3[] Positions = Array.Empty<Vector3>();
        /// <summary>Positions used by triangles of more than one cell.</summary>
        public bool[] Border = Array.Empty<bool>();
        public int BorderCount;
        /// <summary>Each cell's triangles, ascending.</summary>
        public List<int[]> Cells = new();
        /// <summary>Every triangle touching a border position, ascending.</summary>
        public int[] Band = Array.Empty<int>();
        public double AttributeLength = 1.0;
        public bool SourceHasUvs;
    }

    /// <summary>The pre-pass: welding, the cells, the border and the band. Also generates the
    /// tangents of surfaces that came without them, in the source arrays, since a cell would see
    /// only its own side of a corner's triangles.</summary>
    public CellPlan PlanCells(int cellTriangles, bool includeTangents)
    {
        var plan = new CellPlan();
        int surfaces = _source.Length;
        plan.SurfaceCornerOffset = new int[surfaces + 1];
        plan.SurfaceTriangleOffset = new int[surfaces + 1];
        for (int s = 0; s < surfaces; s++)
        {
            SourceSurface source = _source[s];
            plan.SurfaceCornerOffset[s + 1] = plan.SurfaceCornerOffset[s] + source.Vertices.Length;
            plan.SurfaceTriangleOffset[s + 1] = plan.SurfaceTriangleOffset[s] + source.Indices.Length / 3;
            if (source.Uvs.Length == source.Vertices.Length && source.Uvs.Length > 0)
                plan.SourceHasUvs = true;
            if (includeTangents && source.Tangents.Length != source.Vertices.Length * 4)
                _source[s] = source with { Tangents = SurfaceTangents(source) };
        }

        var vertices = new List<Vector3>(plan.SurfaceCornerOffset[surfaces]);
        foreach (SourceSurface source in _source)
            vertices.AddRange(source.Vertices);
        var weld = new GodotiteMesh();
        plan.CornerPosition = weld.WeldPositions(vertices);
        plan.Positions = weld.Positions;
        vertices = null;

        int n = plan.SurfaceTriangleOffset[surfaces];
        var corners = new int[n * 3];
        for (int s = 0; s < surfaces; s++)
        {
            int[] indices = _source[s].Indices;
            int triangleOffset = plan.SurfaceTriangleOffset[s];
            int cornerOffset = plan.SurfaceCornerOffset[s];
            int[] cornerPosition = plan.CornerPosition;
            Parallel.For(0, indices.Length / 3, k =>
            {
                for (int e = 0; e < 3; e++)
                    corners[(triangleOffset + k) * 3 + e] = cornerPosition[indices[k * 3 + e] + cornerOffset];
            });
        }

        // The mean edge length, summed in the order an unchunked parse sums it (ComputeMeanEdgeLength).
        Vector3[] positions = plan.Positions;
        double total = 0.0;
        for (int t = 0; t < n; t++)
        {
            int a = corners[t * 3], b = corners[t * 3 + 1], c = corners[t * 3 + 2];
            total += positions[b].DistanceTo(positions[a]);
            total += positions[c].DistanceTo(positions[b]);
            total += positions[a].DistanceTo(positions[c]);
        }
        plan.AttributeLength = n > 0 ? total / (n * 3.0) : 1.0;

        var centroids = new Vector3[n];
        Parallel.For(0, n, t => centroids[t] =
            (positions[corners[t * 3]] + positions[corners[t * 3 + 1]] + positions[corners[t * 3 + 2]]) / 3.0f);
        var all = new int[n];
        for (int t = 0; t < n; t++)
            all[t] = t;
        Split(all, centroids, Math.Max(cellTriangles, 1), plan.Cells);
        centroids = null;

        var cellOf = new int[n];
        for (int c = 0; c < plan.Cells.Count; c++)
        {
            foreach (int t in plan.Cells[c])
                cellOf[t] = c;
        }
        var firstCell = new int[positions.Length];
        Array.Fill(firstCell, -1);
        plan.Border = new bool[positions.Length];
        for (int t = 0; t < n; t++)
        {
            for (int e = 0; e < 3; e++)
            {
                int p = corners[t * 3 + e];
                if (firstCell[p] < 0)
                    firstCell[p] = cellOf[t];
                else if (firstCell[p] != cellOf[t])
                    plan.Border[p] = true;
            }
        }
        foreach (bool border in plan.Border)
        {
            if (border)
                plan.BorderCount++;
        }
        var band = new List<int>();
        for (int t = 0; t < n; t++)
        {
            if (plan.Border[corners[t * 3]] || plan.Border[corners[t * 3 + 1]] || plan.Border[corners[t * 3 + 2]])
                band.Add(t);
        }
        plan.Band = band.ToArray();
        return plan;
    }

    /// <summary>Halves the triangles at the median of their centroids along the longest axis until
    /// every part is at most <paramref name="limit"/>; the parts, each ascending, in order.</summary>
    private static void Split(int[] items, Vector3[] centroids, int limit, List<int[]> cells)
    {
        if (items.Length <= limit)
        {
            Array.Sort(items);
            cells.Add(items);
            return;
        }
        Vector3 min = centroids[items[0]], max = min;
        foreach (int t in items)
        {
            min = min.Min(centroids[t]);
            max = max.Max(centroids[t]);
        }
        Vector3 size = max - min;
        int axis = size.X >= size.Y && size.X >= size.Z ? 0 : size.Y >= size.Z ? 1 : 2;
        var keys = new float[items.Length];
        for (int i = 0; i < items.Length; i++)
            keys[i] = centroids[items[i]][axis];
        Array.Sort(keys, items);
        int mid = items.Length / 2;
        Split(items[..mid], centroids, limit, cells);
        Split(items[mid..], centroids, limit, cells);
    }

    /// <summary>Tangents for a surface that came without them, by the rule an unchunked parse
    /// applies (GenerateTangents): per corner, so a whole surface at once is exact.</summary>
    private static float[] SurfaceTangents(SourceSurface source)
    {
        int n = source.Vertices.Length;
        bool hasNormals = source.Normals.Length == n;
        bool hasUvs = source.Uvs.Length == n;
        var tangentSum = new Vector3[n];
        var bitangentSum = new Vector3[n];
        int[] indices = source.Indices;
        for (int k = 0; k + 2 < indices.Length; k += 3)
        {
            int c0 = indices[k], c1 = indices[k + 1], c2 = indices[k + 2];
            Vector3 e1 = source.Vertices[c1] - source.Vertices[c0], e2 = source.Vertices[c2] - source.Vertices[c0];
            Vector2 uv0 = hasUvs ? source.Uvs[c0] : Vector2.Zero;
            Vector2 d1 = (hasUvs ? source.Uvs[c1] : Vector2.Zero) - uv0;
            Vector2 d2 = (hasUvs ? source.Uvs[c2] : Vector2.Zero) - uv0;
            float det = d1.X * d2.Y - d2.X * d1.Y;
            if (MathF.Abs(det) < 1e-12f)
                continue;
            float r = 1.0f / det;
            Vector3 t = (e1 * d2.Y - e2 * d1.Y) * r;
            Vector3 b = (e2 * d1.X - e1 * d2.X) * r;
            tangentSum[c0] += t; tangentSum[c1] += t; tangentSum[c2] += t;
            bitangentSum[c0] += b; bitangentSum[c1] += b; bitangentSum[c2] += b;
        }
        var tangents = new float[n * 4];
        for (int c = 0; c < n; c++)
        {
            Vector3 normal = hasNormals ? source.Normals[c] : new Vector3(0, 0, 1);
            Vector3 t = tangentSum[c] - normal * normal.Dot(tangentSum[c]);
            if (t.LengthSquared() < 1e-20f)
            {
                Vector3 axis = MathF.Abs(normal.X) < 0.9f ? Vector3.Right : Vector3.Up;
                t = axis - normal * normal.Dot(axis);
            }
            t = t.Normalized();
            tangents[c * 4] = t.X;
            tangents[c * 4 + 1] = t.Y;
            tangents[c * 4 + 2] = t.Z;
            tangents[c * 4 + 3] = normal.Cross(t).Dot(bitangentSum[c]) < 0.0f ? -1.0f : 1.0f;
        }
        return tangents;
    }

    /// <summary>
    /// The given triangles of the whole mesh, ascending, parsed as a mesh of their own: a cell or the
    /// band. Corners keep their source order, and every vertex its welded position's coordinates,
    /// so it welds exactly as the whole mesh does.
    /// </summary>
    public GodotiteMesh SubMesh(int[] triangles, CellPlan plan, float attributeWeight, float uvDistortionWeight,
        bool includeTangents, float customWeight, float colorWeight)
    {
        var sub = new GodotiteMesh
        {
            SurfaceCount = SurfaceCount,
            _forcedAttributeLength = plan.AttributeLength,
            _forceSourceHasUvs = plan.SourceHasUvs,
        };
        var globalCorners = new List<int>();
        var surfaces = new SourceSurface[_source.Length];
        int next = 0;
        for (int s = 0; s < _source.Length; s++)
        {
            SourceSurface source = _source[s];
            int first = next;
            while (next < triangles.Length && triangles[next] < plan.SurfaceTriangleOffset[s + 1])
                next++;
            int count = next - first;
            int surfaceTriangle = plan.SurfaceTriangleOffset[s];
            int vertexCount = source.Vertices.Length;
            // Numbered in source order, not order of use, so seams and representative corners come
            // out as the whole mesh has them.
            var local = new int[vertexCount];
            for (int k = 0; k < count; k++)
            {
                int t = triangles[first + k] - surfaceTriangle;
                for (int e = 0; e < 3; e++)
                    local[source.Indices[t * 3 + e]] = 1;
            }
            int used = 0;
            for (int v = 0; v < vertexCount; v++)
                local[v] = local[v] != 0 ? used++ : -1;
            var indices = new int[count * 3];
            for (int k = 0; k < count; k++)
            {
                int t = triangles[first + k] - surfaceTriangle;
                for (int e = 0; e < 3; e++)
                    indices[k * 3 + e] = local[source.Indices[t * 3 + e]];
            }

            bool hasNormals = source.Normals.Length == vertexCount;
            bool hasUvs = source.Uvs.Length == vertexCount;
            bool hasTangents = source.Tangents.Length == vertexCount * 4;
            var vertices = new Vector3[used];
            var normals = hasNormals ? new Vector3[used] : Array.Empty<Vector3>();
            var uvs = hasUvs ? new Vector2[used] : Array.Empty<Vector2>();
            var tangents = hasTangents ? new float[used * 4] : Array.Empty<float>();
            var custom = new float[]?[ChannelCount];
            for (int c = 0; c < ChannelCount; c++)
                custom[c] = source.Custom[c] != null ? new float[used * 4] : null;
            int cornerOffset = plan.SurfaceCornerOffset[s];
            for (int v = 0; v < vertexCount; v++)
            {
                int i = local[v];
                if (i < 0)
                    continue;
                int corner = cornerOffset + v;
                globalCorners.Add(corner);
                vertices[i] = plan.Positions[plan.CornerPosition[corner]];
                if (hasNormals)
                    normals[i] = source.Normals[v];
                if (hasUvs)
                    uvs[i] = source.Uvs[v];
                if (hasTangents)
                    Array.Copy(source.Tangents, v * 4, tangents, i * 4, 4);
                for (int c = 0; c < ChannelCount; c++)
                {
                    if (custom[c] != null)
                        Array.Copy(source.Custom[c]!, v * 4, custom[c]!, i * 4, 4);
                }
            }
            surfaces[s] = new SourceSurface(vertices, normals, uvs, tangents, indices, custom,
                (int[])source.CustomFormats.Clone());
        }
        sub._source = surfaces;
        sub.Parse(attributeWeight, uvDistortionWeight, includeTangents, customWeight, colorWeight);
        sub.GlobalCorner = globalCorners.ToArray();
        sub.GlobalPosition = new int[sub.Positions.Length];
        foreach (Triangle tri in sub.Triangles)
        {
            sub.GlobalPosition[tri.I0] = plan.CornerPosition[sub.GlobalCorner[tri.C0]];
            sub.GlobalPosition[tri.I1] = plan.CornerPosition[sub.GlobalCorner[tri.C1]];
            sub.GlobalPosition[tri.I2] = plan.CornerPosition[sub.GlobalCorner[tri.C2]];
        }
        return sub;
    }

    /// <summary>Positions with their per-position data and every corner at them, numbered as in
    /// the whole mesh: what one cell, or the band, gives the merge.</summary>
    public sealed class MeshPart
    {
        public readonly List<int> Positions = new();
        public readonly List<Vector3> Coordinates = new();
        public readonly List<float> BaseQuadrics = new();
        public readonly List<float> UvQuadrics = new();
        public readonly List<Vector2> UvOrigins = new();
        public readonly List<float> LocalEdgeLength = new();
        public readonly List<double> SeamError = new();
        public readonly List<bool> IsSeam = new();
        public readonly List<int> PositionCorner = new();
        public readonly List<int> CornerStart = new() { 0 };
        public readonly List<int> CornerList = new();

        public readonly List<int> Corners = new();
        public readonly List<Vector3> Normals = new();
        public readonly List<int> Materials = new();
        public readonly List<Vector2> Uvs = new();
        public readonly List<float> Tangents = new();
        public readonly List<float>[] Custom =
            { new(), new(), new(), new(), new() };
    }

    /// <summary>Adds these positions (ascending), and every corner at them, to <paramref name="part"/>.</summary>
    public void Export(IEnumerable<int> positions, MeshPart part)
    {
        var carried = new HashSet<int>();
        foreach (int p in positions)
        {
            part.Positions.Add(GlobalPosition[p]);
            part.Coordinates.Add(Positions[p]);
            for (int k = 0; k < 10; k++)
                part.BaseQuadrics.Add(BaseQuadrics[p * 10 + k]);
            if (UvQuadrics.Length > 0)
            {
                for (int k = 0; k < 30; k++)
                    part.UvQuadrics.Add(UvQuadrics[p * 30 + k]);
                part.UvOrigins.Add(_uvOrigins[p]);
            }
            part.LocalEdgeLength.Add(LocalEdgeLength[p]);
            part.SeamError.Add(SeamError[p]);
            part.IsSeam.Add(IsSeam[p]);
            part.PositionCorner.Add(PositionCorner[p] >= 0 ? GlobalCorner[PositionCorner[p]] : -1);
            for (int i = PositionCornerStart[p]; i < PositionCornerStart[p + 1]; i++)
            {
                int corner = PositionCorners[i];
                part.CornerList.Add(GlobalCorner[corner]);
                if (!carried.Add(corner))
                    continue;
                part.Corners.Add(GlobalCorner[corner]);
                part.Normals.Add(CornerNormals[corner]);
                part.Materials.Add(CornerMaterial[corner]);
                part.Uvs.Add(CornerUvs[corner]);
                if (HasTangents)
                {
                    for (int k = 0; k < 4; k++)
                        part.Tangents.Add(CornerTangents[corner * 4 + k]);
                }
                for (int c = 0; c < ChannelCount; c++)
                {
                    if (CornerCustom[c].Length == 0)
                        continue;
                    for (int k = 0; k < 4; k++)
                        part.Custom[c].Add(CornerCustom[c][corner * 4 + k]);
                }
            }
            part.CornerStart.Add(part.CornerList.Count);
        }
    }

    /// <summary>
    /// The merge's mesh: every position and corner the parts carry, renumbered in whole-mesh order.
    /// A position carried by more than one part takes the first's data, so the band, first, wins
    /// for the border. Returns the renumbering too.
    /// </summary>
    public static GodotiteMesh Assemble(List<MeshPart> parts, CellPlan plan, int[] customFormat, bool hasTangents,
        float attributeWeight, float uvDistortionWeight, float customWeight, float colorWeight,
        out Dictionary<int, int> positionOf, out Dictionary<int, int> cornerOf)
    {
        var positionAt = new Dictionary<int, (int Part, int Index)>();
        var cornerAt = new Dictionary<int, (int Part, int Index)>();
        for (int i = 0; i < parts.Count; i++)
        {
            for (int j = 0; j < parts[i].Positions.Count; j++)
                positionAt.TryAdd(parts[i].Positions[j], (i, j));
            for (int j = 0; j < parts[i].Corners.Count; j++)
                cornerAt.TryAdd(parts[i].Corners[j], (i, j));
        }
        var positionIds = new int[positionAt.Count];
        positionAt.Keys.CopyTo(positionIds, 0);
        Array.Sort(positionIds);
        var cornerIds = new int[cornerAt.Count];
        cornerAt.Keys.CopyTo(cornerIds, 0);
        Array.Sort(cornerIds);
        positionOf = new Dictionary<int, int>(positionIds.Length);
        for (int i = 0; i < positionIds.Length; i++)
            positionOf[positionIds[i]] = i;
        cornerOf = new Dictionary<int, int>(cornerIds.Length);
        for (int i = 0; i < cornerIds.Length; i++)
            cornerOf[cornerIds[i]] = i;

        int positionCount = positionIds.Length;
        int cornerCount = cornerIds.Length;
        bool uvQuadrics = parts.Exists(part => part.UvQuadrics.Count > 0);
        var mesh = new GodotiteMesh
        {
            SurfaceCount = plan.SurfaceCornerOffset.Length - 1,
            SourceHasUvs = plan.SourceHasUvs,
            HasTangents = hasTangents,
            AttributeLength = plan.AttributeLength,
            _attributeWeight = attributeWeight,
            _uvDistortionWeight = uvDistortionWeight,
            _customWeight = customWeight,
            _colorWeight = colorWeight < 0.0f ? customWeight : colorWeight,
            GlobalPosition = positionIds,
            GlobalCorner = cornerIds,
            Positions = new Vector3[positionCount],
            BaseQuadrics = new float[positionCount * 10],
            UvQuadrics = uvQuadrics ? new float[positionCount * 30] : Array.Empty<float>(),
            _uvOrigins = uvQuadrics ? new Vector2[positionCount] : Array.Empty<Vector2>(),
            LocalEdgeLength = new float[positionCount],
            SeamError = new double[positionCount],
            IsSeam = new bool[positionCount],
            PositionCorner = new int[positionCount],
            PositionCornerStart = new int[positionCount + 1],
            CornerNormals = new Vector3[cornerCount],
            CornerMaterial = new int[cornerCount],
            CornerUvs = new Vector2[cornerCount],
            CornerTangents = hasTangents ? new float[cornerCount * 4] : Array.Empty<float>(),
        };
        Array.Copy(customFormat, mesh.CustomFormat, Math.Min(customFormat.Length, mesh.CustomFormat.Length));
        for (int c = 0; c < ChannelCount; c++)
            mesh.CornerCustom[c] = mesh.CustomFormat[c] >= 0 ? new float[cornerCount * 4] : Array.Empty<float>();

        var cornerLists = new List<int>();
        for (int m = 0; m < positionCount; m++)
        {
            (int pi, int j) = positionAt[positionIds[m]];
            MeshPart part = parts[pi];
            mesh.Positions[m] = part.Coordinates[j];
            for (int k = 0; k < 10; k++)
                mesh.BaseQuadrics[m * 10 + k] = part.BaseQuadrics[j * 10 + k];
            if (uvQuadrics)
            {
                for (int k = 0; k < 30; k++)
                    mesh.UvQuadrics[m * 30 + k] = part.UvQuadrics[j * 30 + k];
                mesh._uvOrigins[m] = part.UvOrigins[j];
            }
            mesh.LocalEdgeLength[m] = part.LocalEdgeLength[j];
            mesh.SeamError[m] = part.SeamError[j];
            mesh.IsSeam[m] = part.IsSeam[j];
            mesh.PositionCorner[m] = part.PositionCorner[j] >= 0 ? cornerOf[part.PositionCorner[j]] : -1;
            mesh.PositionCornerStart[m] = cornerLists.Count;
            for (int i = part.CornerStart[j]; i < part.CornerStart[j + 1]; i++)
                cornerLists.Add(cornerOf[part.CornerList[i]]);
        }
        mesh.PositionCornerStart[positionCount] = cornerLists.Count;
        mesh.PositionCorners = cornerLists.ToArray();

        for (int m = 0; m < cornerCount; m++)
        {
            (int pi, int j) = cornerAt[cornerIds[m]];
            MeshPart part = parts[pi];
            mesh.CornerNormals[m] = part.Normals[j];
            mesh.CornerMaterial[m] = part.Materials[j];
            mesh.CornerUvs[m] = part.Uvs[j];
            if (hasTangents)
            {
                for (int k = 0; k < 4; k++)
                    mesh.CornerTangents[m * 4 + k] = part.Tangents[j * 4 + k];
            }
            for (int c = 0; c < ChannelCount; c++)
            {
                if (mesh.CornerCustom[c].Length == 0)
                    continue;
                for (int k = 0; k < 4; k++)
                    mesh.CornerCustom[c][m * 4 + k] = part.Custom[c][j * 4 + k];
            }
        }
        return mesh;
    }
}
