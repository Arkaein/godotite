using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

namespace Godotite;

/// <summary>
/// Parsed source geometry plus everything derived from it that stays valid for the whole build:
/// welded positions, per-corner attributes, seam classification, feature sizes
/// and the error quadrics.
///
/// This is a plain C# type, not a Godot object. Nothing here crosses the script boundary, which is
/// the point of porting the builder whole — the per-position data is laid out as flat arrays indexed
/// by position rather than as dictionaries, and that layout is most of the speedup.
///
/// Quadrics are accumulated once from the ORIGINAL faces and never rebuilt, so a collapse at level 8
/// is still priced against the source surface and the source mapping rather than against level 7's
/// already-damaged one.
/// </summary>
public sealed partial class GodotiteMesh
{
    /// <summary>Absolute tolerance for welding positions. GodotiteBuilder.WELD_TOLERANCE must match:
    /// the validator reads that copy to recognise welded vertices.</summary>
    public const float WeldTolerance = 0.001f;

    /// <summary>Largest UV separation a seam is priced at. Beyond this the discontinuity is simply
    /// "a seam", and widening it further says nothing about how bad erasing it would be.</summary>
    public const float MaxSeamUvGap = 1.0f;

    public struct Triangle
    {
        /// <summary>Welded position indices.</summary>
        public int I0, I1, I2;
        /// <summary>Per-corner attribute indices, parallel to I0/I1/I2, so a seam keeps a different
        /// attribute on each side.</summary>
        public int C0, C1, C2;
        /// <summary>Source surface this triangle came from.</summary>
        public int Material;
        /// <summary>Stable identity, assigned at parse.</summary>
        public int Index;

        public readonly bool IsDegenerate => I0 == I1 || I1 == I2 || I2 == I0;
    }

    // --- source geometry ---
    public Vector3[] Positions = Array.Empty<Vector3>();
    public Vector3[] CornerNormals = Array.Empty<Vector3>();

    /// <summary>Each corner's source surface, which is its material. A collapse adopting a corner at
    /// a position shared by several surfaces takes one of its triangle's own surface: another's
    /// carries that surface's attributes, which on a shoreline were the water's zero blend weights,
    /// and drew the land black.</summary>
    public int[] CornerMaterial = Array.Empty<int>();
    public Vector2[] CornerUvs = Array.Empty<Vector2>();

    /// <summary>Tangent per corner, four floats each (xyz and the bitangent sign w), when
    /// <see cref="HasTangents"/>. Fixed at parse time, from the source or generated over the whole
    /// mesh, so every cluster that shares a corner agrees on it and normal maps show no seams at
    /// cluster borders.</summary>
    public float[] CornerTangents = Array.Empty<float>();
    public bool HasTangents;

    /// <summary>Godot's four custom vertex channels, CUSTOM0–3: four values per corner each, carried
    /// exactly like a UV — per corner, picked rather than blended when a collapse removes a vertex,
    /// and priced in the collapse cost. Material blend weights are the motivating use.</summary>
    public const int CustomChannelCount = 4;

    /// <summary>The source's vertex colour rides along as a fifth channel of the same kind, after the
    /// four custom ones: carried per corner, a seam where it changes, and priced like them.</summary>
    public const int ColorChannel = 4;
    public const int ChannelCount = 5;

    /// <summary>Per channel: its values, four floats per corner, or empty when no surface has it.</summary>
    public readonly float[][] CornerCustom = { Array.Empty<float>(), Array.Empty<float>(),
        Array.Empty<float>(), Array.Empty<float>(), Array.Empty<float>() };

    /// <summary>Per channel: Godot's ArrayCustomFormat to write it back in — RGBA8 unorm (0) or
    /// RGBA float (7) — CustomColor for the colour channel, or -1 when absent.</summary>
    public readonly int[] CustomFormat = { -1, -1, -1, -1, -1 };

    public bool HasCustom => Array.Exists(CustomFormat, format => format >= 0);

    /// <summary>
    /// The custom channel the cluster meshes carry their debug data in — material tag, cluster hue,
    /// level and error, for the debug views — or -1 when the source uses all four. The highest one
    /// the source leaves free. It used to be the colour channel, which overwrote the source's own
    /// vertex colours.
    /// </summary>
    public int DebugChannel => CustomFormat[3] < 0 ? 3 : CustomFormat[2] < 0 ? 2
        : CustomFormat[1] < 0 ? 1 : CustomFormat[0] < 0 ? 0 : -1;

    private float _customWeight = 0.5f;
    private float _colorWeight = 0.5f;
    public Triangle[] Triangles = Array.Empty<Triangle>();
    public bool SourceHasUvs;
    public int SurfaceCount;

    // --- derived, per position ---
    /// <summary>True where the corners meeting a position genuinely disagree. Seams are pinned
    /// during simplification, so over-reporting them directly costs detail.</summary>
    public bool[] IsSeam = Array.Empty<bool>();
    /// <summary>The single corner at a position, or -1 when it is a seam and therefore ambiguous.</summary>
    public int[] PositionCorner = Array.Empty<int>();
    /// <summary>Every corner at a position, flattened; index with PositionCornerStart.</summary>
    public int[] PositionCorners = Array.Empty<int>();
    public int[] PositionCornerStart = Array.Empty<int>();
    /// <summary>Mean length of the edges meeting each position — the local feature size.</summary>
    public float[] LocalEdgeLength = Array.Empty<float>();
    /// <summary>Squared cost of destroying the discontinuity at a seam position; 0 elsewhere.</summary>
    public double[] SeamError = Array.Empty<double>();

    /// <summary>
    /// Mean source edge length, the scale attribute error is expressed in.
    ///
    /// Double, not float, because it feeds a squared term: storing it as float32 moved seam errors
    /// in their seventh digit, which on a value of 1.3e7 is an absolute difference of over 1.
    /// </summary>
    public double AttributeLength = 1.0;

    /// <summary>Edge keys with a single incident triangle in the WHOLE mesh, as opposed to merely in
    /// the group being simplified. That distinction is what separates a genuine open boundary from a
    /// cluster interface.
    ///
    /// Filled by the DAG build, per level, from the geometry at that level — not here. Every reader
    /// runs inside the level loop, after that recomputation, so a copy built during parsing was never
    /// read; building it anyway cost 381 ms on the 980k-triangle terrain.</summary>
    public HashSet<long> MeshBoundaryEdges = new(EdgeKeyComparer.Instance);

    /// <summary>
    /// Edges with three or more triangles in the level's mesh, and how many: non-manifold edges,
    /// such as a shoreline where land, sea floor and water meet. An edge is locked in any triangle
    /// set holding fewer of its triangles than this, which for an ordinary edge, two, is the plain
    /// boundary rule (GodotiteDag.ComputeBoundaryEdges). Without it, a group holding two of a
    /// shoreline's three triangles saw the edge as interior and could move it while the group
    /// holding the third kept it locked: a crack.
    ///
    /// Filled for the source mesh with its adjacency, then per level with the mesh boundary.
    /// </summary>
    public Dictionary<long, int> NonManifoldEdges = new(EdgeKeyComparer.Instance);

    // --- quadrics ---
    //
    // Stored as floats, each position's quadric relative to its own origin: the position itself,
    // and for UV quadrics also the UV of its representative corner. In world coordinates a quadric
    // cannot be float — evaluating it cancels terms of order R² down to the error, and a hollow
    // world's R is hundreds of metres, with UVs in metres too. Relative to its own position every
    // term is on the scale of the surrounding triangles, and float keeps them to 1e-7 of that.
    // Coefficients are accumulated in double and rounded once; evaluation is in double, each
    // endpoint's quadric in its own frame, since the error of Q[a] + Q[b] at v is the sum of the
    // two evaluated separately. Half the memory of doubles: 80 B per source triangle on a mesh
    // with UVs.

    /// <summary>10 coefficients per position, relative to the position.</summary>
    public float[] BaseQuadrics = Array.Empty<float>();
    /// <summary>30 per position: 15 for U then 15 for V, relative to the position and to the UV
    /// of its representative corner (UvOrigin). Empty when the source has no UVs or UV distortion
    /// is switched off.</summary>
    public float[] UvQuadrics = Array.Empty<float>();
    /// <summary>Each position's UV origin: the UV of its representative corner, the corner
    /// UvErrorAt evaluates at. Cached, since evaluation needs it for both endpoints.</summary>
    private Vector2[] _uvOrigins = Array.Empty<Vector2>();

    /// <summary>Per-phase timings from the last Parse(), for finding where the port is slow.</summary>
    public readonly Dictionary<string, double> PhaseMs = new();

    private float _attributeWeight = 8.0f;
    private float _uvDistortionWeight = 1.0f;

    /// <summary>
    /// Godot core's `is_equal_approx` tolerance, which is NOT what C#'s Vector3.IsEqualApprox uses.
    ///
    /// Godot's core comparison uses CMP_EPSILON = 1e-5, while the C# binding's Mathf.IsEqualApprox
    /// uses Mathf.Epsilon = 1e-6. The C# version is therefore ten times stricter, and using it here
    /// classified 83 extra positions as attribute seams — every one of which would then be pinned
    /// during simplification, costing detail for no reason.
    /// </summary>
    private const float CmpEpsilon = 1e-5f;

    private static bool IsEqualApprox(float a, float b)
    {
        if (a == b)
            return true;
        float tolerance = CmpEpsilon * Math.Abs(a);
        if (tolerance < CmpEpsilon)
            tolerance = CmpEpsilon;
        return Math.Abs(a - b) < tolerance;
    }

    private static bool IsEqualApprox(Vector3 a, Vector3 b)
        => IsEqualApprox(a.X, b.X) && IsEqualApprox(a.Y, b.Y) && IsEqualApprox(a.Z, b.Z);

    private static bool IsEqualApprox(Vector2 a, Vector2 b)
        => IsEqualApprox(a.X, b.X) && IsEqualApprox(a.Y, b.Y);

    /// <summary>
    /// Hash comparer for edge keys, and not an optimisation — without it the build does not finish.
    ///
    /// .NET hashes a long by XOR-folding its halves, and an edge key is `lo + (hi &lt;&lt; 32)` where
    /// lo and hi are two vertex indices that a locally-numbered mesh keeps numerically close. The
    /// fold therefore collapses hundreds of thousands of distinct edges onto a handful of buckets,
    /// and the dictionary degenerates to linear scans: boundary-edge counting alone took 59.6 s of a
    /// 60 s parse.
    /// </summary>
    public sealed class EdgeKeyComparer : IEqualityComparer<long>
    {
        public static readonly EdgeKeyComparer Instance = new();

        public bool Equals(long a, long b) => a == b;

        /// <summary>splitmix64's finaliser, which avalanches every input bit.</summary>
        public int GetHashCode(long key)
        {
            ulong x = (ulong)key;
            x ^= x >> 30;
            x *= 0xbf58476d1ce4e5b9UL;
            x ^= x >> 27;
            x *= 0x94d049bb133111ebUL;
            x ^= x >> 31;
            return (int)x;
        }
    }

    /// <summary>Canonical key for the edge between two positions: the smaller index in the low 32
    /// bits, the larger in the high, so (a, b) and (b, a) are the same edge.</summary>
    public static long EdgeKey(int a, int b)
    {
        int lo = Math.Min(a, b);
        int hi = Math.Max(a, b);
        return lo + ((long)hi << 32);
    }

    /// <summary>
    /// Builds the whole model from an ArrayMesh: welding, corners, seams, edge
    /// lengths, seam error and both sets of quadrics.
    /// </summary>
    public void Parse(Mesh mesh, float attributeWeight, float uvDistortionWeight, bool includeTangents,
        float customWeight)
    {
        ReadSurfaces(mesh);
        Parse(attributeWeight, uvDistortionWeight, includeTangents, customWeight);
    }

    /// <summary>A source surface's arrays, copied out of the engine. Custom holds, per channel, four
    /// floats per vertex or null, and CustomFormats the format each came in.</summary>
    private sealed record SourceSurface(Vector3[] Vertices, Vector3[] Normals, Vector2[] Uvs,
        float[] Tangents, int[] Indices, float[]?[] Custom, int[] CustomFormats);

    private SourceSurface[] _source = Array.Empty<SourceSurface>();

    /// <summary>
    /// Copies the mesh's surface arrays out of the engine. The only engine call in parsing, split
    /// out so it can happen on the main thread while everything after it runs on a worker.
    /// </summary>
    public void ReadSurfaces(Mesh mesh)
    {
        SurfaceCount = mesh.GetSurfaceCount();
        _source = new SourceSurface[SurfaceCount];
        for (int surface = 0; surface < SurfaceCount; surface++)
        {
            Godot.Collections.Array arrays = mesh.SurfaceGetArrays(surface);
            Vector3[] vertices = arrays[(int)Mesh.ArrayType.Vertex].AsVector3Array();
            var custom = new float[]?[ChannelCount];
            var formats = new int[ChannelCount];
            long surfaceFormat = mesh is ArrayMesh arrayMesh ? (long)arrayMesh.SurfaceGetFormat(surface) : 0;
            for (int c = 0; c < CustomChannelCount; c++)
            {
                formats[c] = -1;
                Variant data = arrays[(int)Mesh.ArrayType.Custom0 + c];
                int format = (int)((surfaceFormat >> (CustomShift + c * CustomBits)) & CustomMask);
                if (data.VariantType == Variant.Type.PackedByteArray && format == CustomRgba8Unorm)
                {
                    byte[] bytes = data.AsByteArray();
                    if (bytes.Length != vertices.Length * 4)
                        continue;
                    var values = new float[bytes.Length];
                    for (int i = 0; i < bytes.Length; i++)
                        values[i] = bytes[i] / 255.0f;
                    custom[c] = values;
                    formats[c] = CustomRgba8Unorm;
                }
                else if (data.VariantType == Variant.Type.PackedFloat32Array && format == CustomRgbaFloat)
                {
                    float[] values = data.AsFloat32Array();
                    if (values.Length != vertices.Length * 4)
                        continue;
                    custom[c] = values;
                    formats[c] = CustomRgbaFloat;
                }
                else if (data.VariantType != Variant.Type.Nil)
                {
                    GD.PushWarning($"Godotite: CUSTOM{c} on surface {surface} is in a format other than RGBA8 "
                        + "unorm or RGBA float, and is dropped.");
                }
            }
            formats[ColorChannel] = -1;
            Color[] colors = arrays[(int)Mesh.ArrayType.Color].AsColorArray();
            if (colors.Length == vertices.Length && colors.Length > 0)
            {
                var values = new float[colors.Length * 4];
                for (int i = 0; i < colors.Length; i++)
                {
                    values[i * 4] = colors[i].R;
                    values[i * 4 + 1] = colors[i].G;
                    values[i * 4 + 2] = colors[i].B;
                    values[i * 4 + 3] = colors[i].A;
                }
                custom[ColorChannel] = values;
                formats[ColorChannel] = CustomColor;
            }
            _source[surface] = new SourceSurface(
                vertices,
                arrays[(int)Mesh.ArrayType.Normal].AsVector3Array(),
                arrays[(int)Mesh.ArrayType.TexUV].AsVector2Array(),
                arrays[(int)Mesh.ArrayType.Tangent].AsFloat32Array(),
                arrays[(int)Mesh.ArrayType.Index].AsInt32Array(),
                custom, formats);
        }
    }

    // Godot's custom-channel format bits (Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT and so on), and the two
    // formats carried through: RGBA8 unorm, and RGBA float.
    public const int CustomShift = 13;
    public const int CustomBits = 3;
    public const long CustomMask = 7;
    public const int CustomRgba8Unorm = 0;
    public const int CustomRgbaFloat = 7;
    /// <summary>Not a Godot format: marks the colour channel, written back as ARRAY_COLOR.</summary>
    public const int CustomColor = 100;

    /// <summary>Parses the surfaces read by <see cref="ReadSurfaces"/>. No engine calls. A negative
    /// <paramref name="colorWeight"/> prices vertex colour like the custom channels.</summary>
    public void Parse(float attributeWeight, float uvDistortionWeight, bool includeTangents, float customWeight,
        float colorWeight = -1.0f)
    {
        _attributeWeight = attributeWeight;
        _uvDistortionWeight = uvDistortionWeight;
        _customWeight = customWeight;
        _colorWeight = colorWeight < 0.0f ? customWeight : colorWeight;
        // A channel is carried if any surface has it; surfaces without it get zeros.
        var customLists = new List<float>?[ChannelCount];
        for (int c = 0; c < ChannelCount; c++)
        {
            CustomFormat[c] = -1;
            foreach (SourceSurface source in _source)
            {
                if (source.CustomFormats[c] >= 0)
                {
                    CustomFormat[c] = source.CustomFormats[c];
                    break;
                }
            }
            if (CustomFormat[c] >= 0)
                customLists[c] = new List<float>();
        }

        // Every surface appends to one shared pool with its indices offset to match. Reading
        // vertices from surface 0 while building triangles from every surface's indices is silent
        // corruption on any multi-surface mesh, and it went unnoticed once already.
        var vertices = new List<Vector3>();
        var cornerNormals = new List<Vector3>();
        var cornerUvs = new List<Vector2>();
        var cornerTangents = new List<float>();
        // Surfaces without source tangents, whose corners get generated ones.
        var generateFor = new List<(int First, int Count)>();
        var surfaceIndices = new int[SurfaceCount][];
        var surfaceCornerOffset = new int[SurfaceCount];
        var surfaceTriangleOffset = new int[SurfaceCount + 1];

        for (int surface = 0; surface < SurfaceCount; surface++)
        {
            Vector3[] surfaceVertices = _source[surface].Vertices;
            Vector3[] normals = _source[surface].Normals;
            Vector2[] uvs = _source[surface].Uvs;
            if (uvs.Length == surfaceVertices.Length && uvs.Length > 0)
                SourceHasUvs = true;

            surfaceCornerOffset[surface] = vertices.Count;
            bool hasNormals = normals.Length == surfaceVertices.Length;
            bool hasUvs = uvs.Length == surfaceVertices.Length;
            vertices.AddRange(surfaceVertices);
            for (int i = 0; i < surfaceVertices.Length; i++)
            {
                cornerNormals.Add(hasNormals ? normals[i] : new Vector3(0, 0, 1));
                cornerUvs.Add(hasUvs ? uvs[i] : Vector2.Zero);
            }
            for (int c = 0; c < ChannelCount; c++)
            {
                if (customLists[c] == null)
                    continue;
                float[]? values = _source[surface].Custom[c];
                customLists[c]!.AddRange(values ?? new float[surfaceVertices.Length * 4]);
            }
            if (includeTangents)
            {
                float[] tangents = _source[surface].Tangents;
                if (tangents.Length == surfaceVertices.Length * 4)
                    cornerTangents.AddRange(tangents);
                else
                {
                    generateFor.Add((cornerTangents.Count / 4, surfaceVertices.Length));
                    cornerTangents.AddRange(new float[surfaceVertices.Length * 4]);
                }
            }

            surfaceIndices[surface] = _source[surface].Indices;
            surfaceTriangleOffset[surface + 1] =
                surfaceTriangleOffset[surface] + surfaceIndices[surface].Length / 3;
        }

        // A cell of a chunked build has UVs whenever the whole mesh does (GodotiteCells.cs), even if
        // none of its triangles come from a surface that carries them.
        SourceHasUvs |= _forceSourceHasUvs;
        _source = Array.Empty<SourceSurface>();
        int[] cornerPosition = WeldPositions(vertices);
        CornerNormals = cornerNormals.ToArray();
        CornerUvs = cornerUvs.ToArray();
        for (int c = 0; c < ChannelCount; c++)
            CornerCustom[c] = customLists[c]?.ToArray() ?? Array.Empty<float>();
        HasTangents = includeTangents;
        CornerTangents = includeTangents ? cornerTangents.ToArray() : Array.Empty<float>();
        if (generateFor.Count > 0)
            GenerateTangents(vertices, surfaceIndices, surfaceCornerOffset, generateFor);

        CornerMaterial = new int[vertices.Count];
        for (int surface = 0; surface < SurfaceCount; surface++)
        {
            int end = surface + 1 < SurfaceCount ? surfaceCornerOffset[surface + 1] : vertices.Count;
            Array.Fill(CornerMaterial, surface, surfaceCornerOffset[surface], end - surfaceCornerOffset[surface]);
        }

        Triangles = new Triangle[surfaceTriangleOffset[SurfaceCount]];
        for (int surface = 0; surface < SurfaceCount; surface++)
        {
            int[] indices = surfaceIndices[surface];
            int cornerOffset = surfaceCornerOffset[surface];
            int triangleOffset = surfaceTriangleOffset[surface];
            int material = surface;
            Parallel.For(0, indices.Length / 3, k =>
            {
                int c0 = indices[k * 3] + cornerOffset;
                int c1 = indices[k * 3 + 1] + cornerOffset;
                int c2 = indices[k * 3 + 2] + cornerOffset;
                Triangles[triangleOffset + k] = new Triangle
                {
                    I0 = cornerPosition[c0],
                    I1 = cornerPosition[c1],
                    I2 = cornerPosition[c2],
                    C0 = c0,
                    C1 = c1,
                    C2 = c2,
                    Material = material,
                    Index = triangleOffset + k,
                };
            });
        }

        long t = System.Diagnostics.Stopwatch.GetTimestamp();
        long Lap(string name)
        {
            long now = System.Diagnostics.Stopwatch.GetTimestamp();
            PhaseMs[name] = (now - t) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
            t = now;
            return now;
        }
        Lap("read_surfaces");
        ClassifySeamPositions(cornerPosition);
        Lap("classify_seams");
        BuildPositionIncidence();
        Lap("position_incidence");
        ComputeMeanEdgeLength();
        Lap("mean_edge_length");
        ComputeSeamError();
        Lap("seam_error");
        BuildUvQuadrics();
        Lap("uv_quadrics");
        BuildBaseQuadrics();
        Lap("base_quadrics");
        _incidenceStart = Array.Empty<int>();
        _incidence = Array.Empty<int>();
    }

    /// <summary>
    /// Welds corners into positions and returns each corner's position, setting
    /// <see cref="Positions"/>. Positions are numbered in order of their first corner — the order a
    /// single pass with a dictionary gives, and part of the output, since every later stage breaks
    /// ties by position index.
    ///
    /// Done in parallel without changing that: corners are split into buckets by a hash of their
    /// weld key, keeping ascending corner order, and each bucket finds, for each corner, the first
    /// corner with the same key. Equal keys always share a bucket, so that answer does not depend on
    /// how many buckets or threads there are. One ascending pass then numbers the first corners.
    /// </summary>
    internal int[] WeldPositions(List<Vector3> vertices)
    {
        int n = vertices.Count;
        var keys = new Vector3I[n];
        var bucketOf = new int[n];
        Parallel.For(0, n, i =>
        {
            // Quantised, because two copies of a seam vertex are rarely bit-identical.
            //
            // The rounding mode is stated rather than left to the default (banker's rounding in
            // both MathF.Round and Mathf.Round). Either mode would do; what matters is that it is
            // fixed, because a coordinate landing exactly on .5 welds to a different position under
            // each — one vertex in 145,066 on Sponza, which is enough to change the DAG.
            Vector3 v = vertices[i];
            var key = new Vector3I(
                (int)MathF.Round(v.X / WeldTolerance, MidpointRounding.AwayFromZero),
                (int)MathF.Round(v.Y / WeldTolerance, MidpointRounding.AwayFromZero),
                (int)MathF.Round(v.Z / WeldTolerance, MidpointRounding.AwayFromZero));
            keys[i] = key;
            ulong hash = (uint)key.X * 0x9E3779B97F4A7C15UL
                ^ (uint)key.Y * 0xC2B2AE3D27D4EB4FUL
                ^ (uint)key.Z * 0x165667B19E3779F9UL;
            bucketOf[i] = (int)(hash >> (64 - WeldBucketBits));
        });

        int buckets = 1 << WeldBucketBits;
        var bucketStart = new int[buckets + 1];
        foreach (int bucket in bucketOf)
            bucketStart[bucket + 1]++;
        for (int b = 0; b < buckets; b++)
            bucketStart[b + 1] += bucketStart[b];
        var members = new int[n];
        var cursor = new int[buckets];
        Array.Copy(bucketStart, cursor, buckets);
        for (int i = 0; i < n; i++)
            members[cursor[bucketOf[i]]++] = i;

        var firstCorner = new int[n];
        Parallel.For(0, buckets, b =>
        {
            var first = new Dictionary<Vector3I, int>(bucketStart[b + 1] - bucketStart[b]);
            for (int m = bucketStart[b]; m < bucketStart[b + 1]; m++)
            {
                int corner = members[m];
                if (!first.TryGetValue(keys[corner], out int earliest))
                {
                    earliest = corner;
                    first[keys[corner]] = corner;
                }
                firstCorner[corner] = earliest;
            }
        });

        // firstCorner[i] <= i, so it is always numbered before it is needed.
        var cornerPosition = new int[n];
        var positions = new List<Vector3>();
        for (int i = 0; i < n; i++)
        {
            if (firstCorner[i] == i)
            {
                cornerPosition[i] = positions.Count;
                positions.Add(vertices[i]);
            }
            else
            {
                cornerPosition[i] = cornerPosition[firstCorner[i]];
            }
        }
        Positions = positions.ToArray();
        return cornerPosition;
    }

    /// <summary>Welding splits corners into 2^this buckets: plenty to spread over any core count,
    /// few enough that each keeps a useful dictionary.</summary>
    private const int WeldBucketBits = 8;

    /// <summary>
    /// Tangents for the corners of surfaces that came without them: per triangle, the directions of
    /// increasing U and V across it (Lengyel's method, the same convention as MikkTSpace and
    /// SurfaceTool.GenerateTangents), summed at each corner, made perpendicular to the corner's
    /// normal, with w recording whether V runs along normal × tangent or against it.
    ///
    /// Summed per corner, not per welded position: corners split at a UV seam must keep their own
    /// tangents, exactly as they keep their own UVs.
    /// </summary>
    private void GenerateTangents(List<Vector3> vertices, int[][] surfaceIndices, int[] surfaceCornerOffset,
        List<(int First, int Count)> generateFor)
    {
        var tangentSum = new Vector3[vertices.Count];
        var bitangentSum = new Vector3[vertices.Count];
        var wanted = new bool[vertices.Count];
        foreach ((int first, int count) in generateFor)
        {
            for (int c = first; c < first + count; c++)
                wanted[c] = true;
        }
        for (int surface = 0; surface < SurfaceCount; surface++)
        {
            int[] indices = surfaceIndices[surface];
            int offset = surfaceCornerOffset[surface];
            for (int k = 0; k + 2 < indices.Length; k += 3)
            {
                int c0 = indices[k] + offset, c1 = indices[k + 1] + offset, c2 = indices[k + 2] + offset;
                if (!wanted[c0])
                    continue;
                Vector3 e1 = vertices[c1] - vertices[c0], e2 = vertices[c2] - vertices[c0];
                Vector2 d1 = CornerUvs[c1] - CornerUvs[c0], d2 = CornerUvs[c2] - CornerUvs[c0];
                float det = d1.X * d2.Y - d2.X * d1.Y;
                if (MathF.Abs(det) < 1e-12f)
                    continue;
                float r = 1.0f / det;
                Vector3 t = (e1 * d2.Y - e2 * d1.Y) * r;
                Vector3 b = (e2 * d1.X - e1 * d2.X) * r;
                tangentSum[c0] += t; tangentSum[c1] += t; tangentSum[c2] += t;
                bitangentSum[c0] += b; bitangentSum[c1] += b; bitangentSum[c2] += b;
            }
        }
        for (int c = 0; c < vertices.Count; c++)
        {
            if (!wanted[c])
                continue;
            Vector3 n = CornerNormals[c];
            Vector3 t = tangentSum[c] - n * n.Dot(tangentSum[c]);
            if (t.LengthSquared() < 1e-20f)
            {
                // No usable UV gradient (no UVs, or degenerate): any direction across the surface.
                Vector3 axis = MathF.Abs(n.X) < 0.9f ? Vector3.Right : Vector3.Up;
                t = axis - n * n.Dot(axis);
            }
            t = t.Normalized();
            float w = n.Cross(t).Dot(bitangentSum[c]) < 0.0f ? -1.0f : 1.0f;
            CornerTangents[c * 4] = t.X;
            CornerTangents[c * 4 + 1] = t.Y;
            CornerTangents[c * 4 + 2] = t.Z;
            CornerTangents[c * 4 + 3] = w;
        }
    }

    // Which triangles touch each position, ascending, a triangle listed once per corner it has there.
    // Only needed while parsing: it lets per-position sums be GATHERED in parallel instead of
    // scattered from triangles serially. Gathering in ascending triangle order performs each
    // position's additions in exactly the order the scatter did, so every sum is bit-identical.
    private int[] _incidenceStart = Array.Empty<int>();
    private int[] _incidence = Array.Empty<int>();

    private void BuildPositionIncidence()
    {
        _incidenceStart = new int[Positions.Length + 1];
        foreach (Triangle tri in Triangles)
        {
            _incidenceStart[tri.I0 + 1]++;
            _incidenceStart[tri.I1 + 1]++;
            _incidenceStart[tri.I2 + 1]++;
        }
        for (int p = 0; p < Positions.Length; p++)
            _incidenceStart[p + 1] += _incidenceStart[p];
        _incidence = new int[_incidenceStart[Positions.Length]];
        var cursor = new int[Positions.Length];
        Array.Copy(_incidenceStart, cursor, Positions.Length);
        for (int t = 0; t < Triangles.Length; t++)
        {
            _incidence[cursor[Triangles[t].I0]++] = t;
            _incidence[cursor[Triangles[t].I1]++] = t;
            _incidence[cursor[Triangles[t].I2]++] = t;
        }
    }

    /// <summary>
    /// Works out which welded positions carry a genuine attribute discontinuity. A position with
    /// several corners is only a seam if those corners actually disagree; duplicate vertices whose
    /// attributes match weld away completely and cost nothing.
    /// </summary>
    private void ClassifySeamPositions(int[] cornerPosition)
    {
        int count = Positions.Length;
        IsSeam = new bool[count];
        PositionCorner = new int[count];
        var firstCorner = new int[count];
        var perPosition = new List<int>[count];
        for (int i = 0; i < count; i++)
        {
            PositionCorner[i] = -1;
            firstCorner[i] = -1;
        }

        for (int corner = 0; corner < cornerPosition.Length; corner++)
        {
            int position = cornerPosition[corner];
            if (firstCorner[position] < 0)
            {
                firstCorner[position] = corner;
                PositionCorner[position] = corner;
                perPosition[position] = new List<int> { corner };
                continue;
            }
            perPosition[position].Add(corner);
            if (IsSeam[position])
                continue;
            int existing = firstCorner[position];
            if (!IsEqualApprox(CornerNormals[corner], CornerNormals[existing])
                || !IsEqualApprox(CornerUvs[corner], CornerUvs[existing])
                || CustomGap(corner, existing) > 1e-4f)
            {
                IsSeam[position] = true;
                PositionCorner[position] = -1;
            }
        }

        // Flatten, so the hot paths index arrays instead of chasing list objects.
        PositionCornerStart = new int[count + 1];
        int total = 0;
        for (int i = 0; i < count; i++)
        {
            PositionCornerStart[i] = total;
            total += perPosition[i]?.Count ?? 0;
        }
        PositionCornerStart[count] = total;
        PositionCorners = new int[total];
        for (int i = 0; i < count; i++)
        {
            var corners = perPosition[i];
            if (corners == null)
                continue;
            corners.CopyTo(PositionCorners, PositionCornerStart[i]);
        }
    }


    /// <summary>
    /// Mean edge length of the source mesh, and the local counterpart per position.
    ///
    /// Computed unconditionally. It used to live inside seam error, which returns early when a mesh
    /// has no seams — leaving the scale at its default of 1.0 and silently mis-scaling everything
    /// else that depends on it.
    /// </summary>
    private void ComputeMeanEdgeLength()
    {
        if (Triangles.Length == 0)
            return;
        int n = Triangles.Length;
        // Edge lengths per triangle, in the order the three edges were always visited: (I0, I1),
        // (I1, I2), (I2, I0), each measured from its second end.
        var lengths = new float[n * 3];
        Parallel.For(0, n, t =>
        {
            Triangle tri = Triangles[t];
            lengths[t * 3] = Positions[tri.I1].DistanceTo(Positions[tri.I0]);
            lengths[t * 3 + 1] = Positions[tri.I2].DistanceTo(Positions[tri.I1]);
            lengths[t * 3 + 2] = Positions[tri.I0].DistanceTo(Positions[tri.I2]);
        });
        // One running sum over every edge in order: cheap, and inherently sequential.
        double totalLength = 0.0;
        foreach (float length in lengths)
            totalLength += length;
        AttributeLength = totalLength / (n * 3.0);
        // A cell of a chunked build prices attributes at the whole mesh's scale (GodotiteCells.cs).
        if (_forcedAttributeLength > 0.0)
            AttributeLength = _forcedAttributeLength;

        LocalEdgeLength = new float[Positions.Length];
        Parallel.For(0, Positions.Length, p =>
        {
            float sum = 0.0f;
            int count = 0;
            int previous = -1;
            for (int k = _incidenceStart[p]; k < _incidenceStart[p + 1]; k++)
            {
                int t = _incidence[k];
                if (t == previous)
                    continue; // every edge of this triangle was already visited below
                previous = t;
                Triangle tri = Triangles[t];
                AddIfEnd(tri.I0, tri.I1, lengths[t * 3]);
                AddIfEnd(tri.I1, tri.I2, lengths[t * 3 + 1]);
                AddIfEnd(tri.I2, tri.I0, lengths[t * 3 + 2]);
            }
            LocalEdgeLength[p] = count > 0 ? sum / count : (float)AttributeLength;

            void AddIfEnd(int a, int b, float length)
            {
                if (a == p) { sum += length; count++; }
                if (b == p) { sum += length; count++; }
            }
        });
    }

    /// <summary>
    /// The scale to price attribute damage at, around this position. Attribute error is
    /// dimensionless and has to be converted into the quadric's units of squared world distance; a
    /// single mesh-wide mean is only right when every triangle is about the same size, and Sponza
    /// spans nearly 30,000x.
    /// </summary>
    public double AttributeScaleAt(int position)
    {
        if (position < 0 || position >= LocalEdgeLength.Length)
            return AttributeLength;
        return LocalEdgeLength[position];
    }

    /// <summary>
    /// Prices each seam by how far apart the attributes meeting there actually are. A position whose
    /// corners disagree slightly costs little; one bridging two unrelated UV islands costs a lot.
    /// </summary>
    private void ComputeSeamError()
    {
        SeamError = new double[Positions.Length];
        if (_attributeWeight <= 0.0f)
            return;

        for (int position = 0; position < Positions.Length; position++)
        {
            if (!IsSeam[position])
                continue;
            int start = PositionCornerStart[position];
            int end = PositionCornerStart[position + 1];
            double spread = 0.0;
            for (int a = start; a < end; a++)
            {
                for (int b = a + 1; b < end; b++)
                {
                    int ca = PositionCorners[a];
                    int cb = PositionCorners[b];
                    // The UV term is clamped; the normal term is bounded by construction. UV
                    // distance is not bounded at all, and on a tiled map it reaches tens — which
                    // once produced cluster errors of 52,069 on a model of radius 2,972.
                    spread = Math.Max(spread, CornerGap(ca, cb));
                }
            }
            SeamError[position] = SeamErrorOf(position, spread);
        }
    }

    /// <summary>How far apart two corners' attributes are: normal, UV (clamped) and custom channels.
    /// A seam's spread is the largest of these between its corners.</summary>
    public double CornerGap(int a, int b)
    {
        // The UV term is clamped; the normal term is bounded by construction. UV distance is not
        // bounded at all, and on a tiled map it reaches tens — which once produced cluster errors
        // of 52,069 on a model of radius 2,972.
        double uvGap = Math.Min(CornerUvs[a].DistanceTo(CornerUvs[b]), MaxSeamUvGap);
        double normalGap = 1.0 - CornerNormals[a].Dot(CornerNormals[b]);
        return normalGap + uvGap + CustomGap(a, b);
    }

    /// <summary>A discontinuity of `spread` at `position` as squared error in world units.</summary>
    private double SeamErrorOf(int position, double spread)
    {
        double length = _attributeWeight * spread * Math.Sqrt(AttributeLength * AttributeScaleAt(position));
        return length * length;
    }

    /// <summary>
    /// The corner at `kept` that each corner at `removed` becomes when the edge collapses: the
    /// nearest of its own material, as GodotiteSimplifier.PickCorner chooses from a triangle's
    /// context; -1 where `kept` has no corner of that material. Indexed from
    /// PositionCornerStart[removed]. Null when neither position is a seam, the one-corner case.
    /// </summary>
    private int[]? MatchCorners(int removed, int kept)
    {
        if (!IsSeam[removed] && !IsSeam[kept])
            return null;
        int start = PositionCornerStart[removed], end = PositionCornerStart[removed + 1];
        var match = new int[end - start];
        for (int g = start; g < end; g++)
        {
            int gone = PositionCorners[g];
            double best = double.PositiveInfinity;
            int bestCorner = -1;
            for (int k = PositionCornerStart[kept]; k < PositionCornerStart[kept + 1]; k++)
            {
                int corner = PositionCorners[k];
                if (CornerMaterial[corner] != CornerMaterial[gone])
                    continue;
                double gap = CornerGap(gone, corner);
                if (gap < best)
                {
                    best = gap;
                    bestCorner = corner;
                }
            }
            match[g - start] = bestCorner;
        }
        return match;
    }

    /// <summary>
    /// What collapsing `removed` onto `kept` destroys of the discontinuity at `removed`, as squared
    /// error: the jumps between its corners that no longer exist once each corner has become its
    /// match at `kept` (MatchCorners), two corners becoming one, or one with no match at all.
    /// * Nothing off a seam.
    /// * Along a seam, nothing: each side's corner becomes its own side's at the next position, and
    ///   the seam's curve only coarsens. How much each side's attributes change is the snap's cost
    ///   (CustomErrorAt, UvErrorAt), not the seam's. Charging the whole seam here, as was done,
    ///   priced every seam curve as if collapsing along it erased it, and the curves never coarsened
    ///   while anything else could: the hollow world's shorelines (land, sea floor and water) kept
    ///   their full detail for four levels, and the cut grew with their length.
    /// * Onto a position without a seam, or across to a seam that cannot keep these sides apart,
    ///   the seam, or the part of it lost.
    /// </summary>
    public double LostSeamError(int removed, int kept)
    {
        if (!IsSeam[removed])
            return 0.0;
        if (!IsSeam[kept] || _attributeWeight <= 0.0f)
            return SeamError[removed];
        int[] match = MatchCorners(removed, kept)!;
        int start = PositionCornerStart[removed], end = PositionCornerStart[removed + 1];
        double lost = 0.0;
        for (int a = start; a < end; a++)
        {
            if (match[a - start] < 0)
                return SeamError[removed];
            for (int b = a + 1; b < end; b++)
            {
                if (match[a - start] == match[b - start])
                    lost = Math.Max(lost, CornerGap(PositionCorners[a], PositionCorners[b]));
            }
        }
        return lost > 0.0 ? SeamErrorOf(removed, lost) : 0.0;
    }

    /// <summary>
    /// Accumulates an attribute quadric per position, one for U and one for V.
    ///
    /// Over a single triangle the texture coordinate is affine in position, s(p) = g·p + d, so the
    /// error of representing (p, s) by that face's mapping is the square of a linear form — the same
    /// shape as a plane quadric, in four dimensions (x, y, z, s). A 5x5 symmetric matrix stores it
    /// in 15 coefficients. The gradient is chosen to lie IN the face plane, making it the natural
    /// extension of the mapping rather than an arbitrary one.
    /// </summary>
    private void BuildUvQuadrics()
    {
        if (!SourceHasUvs || _uvDistortionWeight <= 0.0f)
        {
            UvQuadrics = Array.Empty<float>();
            _uvOrigins = Array.Empty<Vector2>();
            return;
        }
        int n = Triangles.Length;
        var gradients = new Vector3[n * 2];
        var mapped = new bool[n];
        Parallel.For(0, n, t =>
        {
            Triangle tri = Triangles[t];
            Vector3 p0 = Positions[tri.I0];
            Vector3 e1 = Positions[tri.I1] - p0;
            Vector3 e2 = Positions[tri.I2] - p0;
            Vector3 normal = e1.Cross(e2);
            float area2 = normal.LengthSquared();
            // A degenerate face defines no mapping, and contributes no area to look wrong.
            if (area2 <= 0.0f)
                return;
            Vector3 alongE1 = e2.Cross(normal);
            Vector3 alongE2 = normal.Cross(e1);
            Vector2 uv0 = CornerUvs[tri.C0];
            Vector2 uv1 = CornerUvs[tri.C1];
            Vector2 uv2 = CornerUvs[tri.C2];
            for (int channel = 0; channel < 2; channel++)
            {
                float s0 = channel == 0 ? uv0.X : uv0.Y;
                float s1 = channel == 0 ? uv1.X : uv1.Y;
                float s2 = channel == 0 ? uv2.X : uv2.Y;
                gradients[t * 2 + channel] = (alongE1 * (s1 - s0) + alongE2 * (s2 - s0)) / area2;
            }
            mapped[t] = true;
        });

        // At a seam, only the triangles on the representative corner's side contribute: the side
        // UvErrorAt evaluates. Summing both sides mixes two unrelated mappings — at a cube-face seam
        // with UVs in metres, points hundreds of metres apart in UV — and prices every collapse
        // there as if the texture tore across the whole island. The seam itself is priced by
        // SeamError.
        UvQuadrics = new float[Positions.Length * 30];
        _uvOrigins = new Vector2[Positions.Length];
        Parallel.For(0, Positions.Length, p =>
        {
            int representative = IsSeam[p] ? RepresentativeCorner(p) : -1;
            Vector3 origin = Positions[p];
            int originCorner = RepresentativeCorner(p);
            Vector2 uvOrigin = originCorner >= 0 ? CornerUvs[originCorner] : Vector2.Zero;
            _uvOrigins[p] = uvOrigin;
            Span<double> sum = stackalloc double[30];
            for (int k = _incidenceStart[p]; k < _incidenceStart[p + 1]; k++)
            {
                int t = _incidence[k];
                if (!mapped[t])
                    continue;
                if (representative >= 0)
                {
                    Triangle tri = Triangles[t];
                    int corner = tri.I0 == p ? tri.C0 : tri.I1 == p ? tri.C1 : tri.C2;
                    if (!IsEqualApprox(CornerUvs[corner], CornerUvs[representative]))
                        continue;
                }
                // The plane's offset in this position's frame: s = g.(x - p0) + s0 becomes
                // s - uvOrigin = g.(x - origin) + offset. In double, since it can be a difference
                // of close values and is squared into the quadric.
                Triangle face = Triangles[t];
                Vector3 p0 = Positions[face.I0];
                Vector2 uv0 = CornerUvs[face.C0];
                for (int channel = 0; channel < 2; channel++)
                {
                    Vector3 g = gradients[t * 2 + channel];
                    double offset = (channel == 0 ? (double)uv0.X - uvOrigin.X : (double)uv0.Y - uvOrigin.Y)
                        - (g.X * ((double)p0.X - origin.X) + g.Y * ((double)p0.Y - origin.Y)
                            + g.Z * ((double)p0.Z - origin.Z));
                    AccumulateUvQuadric(sum.Slice(channel * 15, 15), g, offset);
                }
            }
            for (int k = 0; k < 30; k++)
                UvQuadrics[p * 30 + k] = (float)sum[k];
        });
    }


    /// <summary>Adds the outer product of (g.x, g.y, g.z, -1, d) with itself, upper triangle.</summary>
    private static void AccumulateUvQuadric(Span<double> quadric, Vector3 gradient, double offset)
    {
        Span<double> form = stackalloc double[5]
        {
            gradient.X, gradient.Y, gradient.Z, -1.0, offset,
        };
        int k = 0;
        for (int i = 0; i < 5; i++)
        {
            for (int j = i; j < 5; j++)
            {
                quadric[k] += form[i] * form[j];
                k++;
            }
        }
    }

    private void BuildBaseQuadrics()
    {
        int n = Triangles.Length;
        var normals = new Vector3[n];
        var planar = new bool[n];
        Parallel.For(0, n, t =>
        {
            Triangle tri = Triangles[t];
            Vector3 v0 = Positions[tri.I0];
            Vector3 normal = (Positions[tri.I1] - v0).Cross(Positions[tri.I2] - v0);
            if (normal == Vector3.Zero)
                return; // zero-area triangle defines no plane
            normals[t] = normal.Normalized();
            planar[t] = true;
        });

        BaseQuadrics = new float[Positions.Length * 10];
        Parallel.For(0, Positions.Length, p =>
        {
            Vector3 origin = Positions[p];
            double xx = 0, xy = 0, xz = 0, xw = 0, yy = 0, yz = 0, yw = 0, zz = 0, zw = 0, ww = 0;
            for (int k = _incidenceStart[p]; k < _incidenceStart[p + 1]; k++)
            {
                int t = _incidence[k];
                if (!planar[t])
                    continue;
                Vector3 normal = normals[t];
                Vector3 v0 = Positions[Triangles[t].I0];
                // The plane's offset in this position's frame, in double: n.(x - origin) + d.
                double d = -(normal.X * ((double)v0.X - origin.X) + normal.Y * ((double)v0.Y - origin.Y)
                    + normal.Z * ((double)v0.Z - origin.Z));
                xx += (double)normal.X * normal.X;
                xy += (double)normal.X * normal.Y;
                xz += (double)normal.X * normal.Z;
                xw += normal.X * d;
                yy += (double)normal.Y * normal.Y;
                yz += (double)normal.Y * normal.Z;
                yw += normal.Y * d;
                zz += (double)normal.Z * normal.Z;
                zw += normal.Z * d;
                ww += d * d;
            }
            int b = p * 10;
            BaseQuadrics[b] = (float)xx;
            BaseQuadrics[b + 1] = (float)xy;
            BaseQuadrics[b + 2] = (float)xz;
            BaseQuadrics[b + 3] = (float)xw;
            BaseQuadrics[b + 4] = (float)yy;
            BaseQuadrics[b + 5] = (float)yz;
            BaseQuadrics[b + 6] = (float)yw;
            BaseQuadrics[b + 7] = (float)zz;
            BaseQuadrics[b + 8] = (float)zw;
            BaseQuadrics[b + 9] = (float)ww;
        });
    }

    /// <summary>v^T (Q[a] + Q[b]) v for homogeneous v: the error of collapsing edge (a, b) onto v.
    /// Each quadric is evaluated in its own position's frame.</summary>
    public double QuadricErrorAt(int a, int b, Vector3 v)
        => BaseQuadricAt(a, v) + BaseQuadricAt(b, v);

    private double BaseQuadricAt(int position, Vector3 v)
    {
        int i = position * 10;
        Vector3 origin = Positions[position];
        double x = (double)v.X - origin.X;
        double y = (double)v.Y - origin.Y;
        double z = (double)v.Z - origin.Z;
        return BaseQuadrics[i] * x * x + 2.0 * BaseQuadrics[i + 1] * x * y
            + 2.0 * BaseQuadrics[i + 2] * x * z + 2.0 * BaseQuadrics[i + 3] * x
            + BaseQuadrics[i + 4] * y * y + 2.0 * BaseQuadrics[i + 5] * y * z
            + 2.0 * BaseQuadrics[i + 6] * y
            + BaseQuadrics[i + 7] * z * z + 2.0 * BaseQuadrics[i + 8] * z
            + BaseQuadrics[i + 9];
    }

    /// <summary>Squared texture-coordinate error of snapping edge (a, b) onto `target`.</summary>
    public double UvErrorAt(int a, int b, int target)
    {
        if (UvQuadrics.Length == 0)
            return 0.0;
        // A seam position has several corners with different UVs by definition; any of them
        // represents the mapping on its own side, and destroying the discontinuity itself is
        // already priced by SeamError.
        int corner = PositionCorner[target];
        if (corner < 0)
        {
            int start = PositionCornerStart[target];
            if (start >= PositionCornerStart[target + 1])
                return 0.0;
            corner = PositionCorners[start];
        }

        Vector2 uv = CornerUvs[corner];
        Vector3 p = Positions[target];
        // Each endpoint's quadric in its own frame; see BaseQuadrics.
        double sumU = 0.0;
        double sumV = 0.0;
        for (int e = 0; e < 2; e++)
        {
            int end = e == 0 ? a : b;
            Vector3 origin = Positions[end];
            Vector2 uvOrigin = _uvOrigins[end];
            double x = (double)p.X - origin.X;
            double y = (double)p.Y - origin.Y;
            double z = (double)p.Z - origin.Z;
            sumU += UvQuadricAt(end * 30, x, y, z, (double)uv.X - uvOrigin.X);
            sumV += UvQuadricAt(end * 30 + 15, x, y, z, (double)uv.Y - uvOrigin.Y);
        }
        double total = Math.Max(sumU, 0.0) + Math.Max(sumV, 0.0);
        // Bounded like the seam gap, and for the same reason: once the texture has slid by a whole
        // UV unit it is as wrong as it gets. Unbounded, a collapse that meets a seam from the far
        // side still sums two unrelated mappings — hundreds of units apart where UVs are metres —
        // and a hollow world's top levels reported errors of twice their own radius.
        total = Math.Min(total, MaxSeamUvGap * MaxSeamUvGap);

        // Scaled by the GEOMETRIC MEAN of the mesh-wide and local feature sizes. The global mean
        // alone makes cost independent of polygon size and undercharges big flat polygons ~8x; the
        // local edge alone makes cost go as size squared and overcharges them ~9x. The geometric
        // mean makes cost go as size itself, which leaves error/extent flat across the size range.
        double edgeLength = Positions[a].DistanceTo(Positions[b]);
        if (edgeLength <= 0.0)
            edgeLength = (AttributeScaleAt(a) + AttributeScaleAt(b)) * 0.5;
        double scale = _uvDistortionWeight * Math.Sqrt(AttributeLength * edgeLength);
        return total * scale * scale;
    }

    /// <summary>One channel's UV quadric at (x, y, z, s, 1), from its 15 upper-triangle
    /// coefficients; off-diagonal terms count twice in the full symmetric product.</summary>
    private double UvQuadricAt(int i, double x, double y, double z, double s)
    {
        float[] q = UvQuadrics;
        return q[i] * x * x + 2.0 * (q[i + 1] * x * y + q[i + 2] * x * z + q[i + 3] * x * s + q[i + 4] * x)
            + q[i + 5] * y * y + 2.0 * (q[i + 6] * y * z + q[i + 7] * y * s + q[i + 8] * y)
            + q[i + 9] * z * z + 2.0 * (q[i + 10] * z * s + q[i + 11] * z)
            + q[i + 12] * s * s + 2.0 * q[i + 13] * s
            + q[i + 14];
    }

    /// <summary>The largest difference between two corners in any custom channel or colour value.</summary>
    public float CustomGap(int a, int b)
    {
        float gap = 0.0f;
        for (int c = 0; c < ChannelCount; c++)
        {
            float[] values = CornerCustom[c];
            if (values.Length == 0)
                continue;
            for (int k = 0; k < 4; k++)
                gap = MathF.Max(gap, MathF.Abs(values[a * 4 + k] - values[b * 4 + k]));
        }
        return gap;
    }

    /// <summary>
    /// Squared custom-attribute error of snapping edge (a, b) onto `target`: the removed vertex's
    /// custom values and vertex colour are replaced by the survivor's, so the difference between
    /// them is what shows.
    /// With blend weights in the channels, that is a material transition moving — visible, and so
    /// priced as error, which keeps transitions detailed until they are far away. Scaled to world
    /// units like the UV error, by <c>customWeight</c>, and the vertex colour by its own weight, since
    /// colour may hold data rather than something seen (the hollow world's sun intervals).
    /// </summary>
    public double CustomErrorAt(int a, int b, int target)
    {
        if (!HasCustom || (_customWeight <= 0.0f && _colorWeight <= 0.0f))
            return 0.0;
        int removed = target == a ? b : a;
        // With one weight for everything, summed and scaled once, exactly as before the colour had
        // its own, so builds that do not set it stay bit-identical.
        bool shared = _colorWeight == _customWeight;
        double total;
        int[]? match = MatchCorners(removed, target);
        if (match == null)
        {
            int kept = RepresentativeCorner(target), gone = RepresentativeCorner(removed);
            if (kept < 0 || gone < 0)
                return 0.0;
            total = CustomChange(gone, kept, shared);
        }
        else
        {
            // At a seam, each corner against the one it becomes, the largest change: a corner
            // from each side, compared, priced the jump across the seam as if it moved.
            total = 0.0;
            int start = PositionCornerStart[removed];
            for (int g = 0; g < match.Length; g++)
            {
                if (match[g] >= 0)
                    total = Math.Max(total, CustomChange(PositionCorners[start + g], match[g], shared));
            }
        }
        double edgeLength = Positions[a].DistanceTo(Positions[b]);
        if (edgeLength <= 0.0)
            edgeLength = (AttributeScaleAt(a) + AttributeScaleAt(b)) * 0.5;
        double scale = (shared ? _customWeight : 1.0) * Math.Sqrt(AttributeLength * edgeLength);
        return total * scale * scale;
    }

    /// <summary>Squared change in the custom channels and colour from corner `gone` to `kept`.</summary>
    private double CustomChange(int gone, int kept, bool shared)
    {
        double total = 0.0;
        for (int c = 0; c < ChannelCount; c++)
        {
            float[] values = CornerCustom[c];
            float weight = c == ColorChannel ? _colorWeight : _customWeight;
            if (values.Length == 0 || weight <= 0.0f)
                continue;
            double squared = shared ? 1.0 : (double)weight * weight;
            for (int k = 0; k < 4; k++)
            {
                double d = values[kept * 4 + k] - values[gone * 4 + k];
                total += shared ? d * d : d * d * squared;
            }
        }
        return total;
    }

    /// <summary>A corner standing for a position: its only one, or the first at a seam.</summary>
    private int RepresentativeCorner(int position)
    {
        int corner = PositionCorner[position];
        if (corner >= 0)
            return corner;
        int start = PositionCornerStart[position];
        return start < PositionCornerStart[position + 1] ? PositionCorners[start] : -1;
    }

    /// <summary>What it costs to collapse edge (i0, i1) onto `target`: how far the surface moves,
    /// plus how far the texture slides and the custom attributes change. All of it must be weighed
    /// by the same rule that later picks the surviving endpoint, or the edge is queued at one cost
    /// and collapsed at another.</summary>
    public double SnapCost(int i0, int i1, int target)
        => QuadricErrorAt(i0, i1, Positions[target]) + UvErrorAt(i0, i1, target) + CustomErrorAt(i0, i1, target);

    /// <summary>Cost of collapsing edge (i0, i1) onto `target`: the snap, plus the discontinuity
    /// destroyed at the end removed (LostSeamError).</summary>
    public double CollapseCostOnto(int i0, int i1, int target)
        => SnapCost(i0, i1, target) + LostSeamError(target == i0 ? i1 : i0, target);

    /// <summary>Cost of collapsing edge (i0, i1): the cheaper of its two directions.</summary>
    public double CollapseCost(int i0, int i1)
        => Math.Min(CollapseCostOnto(i0, i1, i0), CollapseCostOnto(i0, i1, i1));

    // --- triangle adjacency ---

    /// <summary>Neighbour lists in CSR form: triangle t's neighbours are
    /// AdjacencyItems[AdjacencyStart[t] .. AdjacencyStart[t + 1]].</summary>
    public int[] AdjacencyStart = Array.Empty<int>();
    public int[] AdjacencyItems = Array.Empty<int>();

    /// <summary>Frees the adjacency once leaf clustering, its only reader, is done.</summary>
    public void ReleaseAdjacency()
    {
        AdjacencyStart = Array.Empty<int>();
        AdjacencyItems = Array.Empty<int>();
    }

    /// <summary>
    /// Two triangles are adjacent when they share an edge. An edge with more than two incident
    /// triangles makes every pair of them adjacent, which is deliberate — non-manifold joins are
    /// still connectivity as far as clustering is concerned.
    ///
    /// ORDER IS PART OF THE CONTRACT. Region growing walks these lists and takes the first candidate
    /// it can use, so a different ordering grows different clusters and the whole DAG changes. Keys
    /// are therefore tracked in first-seen order rather than left to hash ordering, which would make
    /// the build depend on the hash implementation.
    /// </summary>
    public void BuildTriangleAdjacency()
    {
        // Half-edge h = 3t + e is edge e of triangle t: (I0, I1), (I1, I2), (I2, I0). Grouped and
        // sorted (GroupHalfEdges), each run of equal upper vertex is one edge, its members in
        // ascending h — so ascending triangle — and its first member is the edge's first occurrence
        // in the triangle list. Ordering edges by first occurrence is exactly the first-seen order a
        // dictionary walk used to give, without the dictionary or a list per edge.
        int n = Triangles.Length;
        int halfEdges = n * 3;
        var lower = new int[halfEdges];
        var upper = new int[halfEdges];
        for (int t = 0; t < n; t++)
            SetHalfEdges(Triangles[t].I0, Triangles[t].I1, Triangles[t].I2, t * 3, lower, upper);
        long[] sorted = GroupHalfEdges(Positions.Length, lower, upper, out int[] groupStart);

        // For every half-edge, the [start, end) of its edge's run in `sorted`.
        var runStart = new int[halfEdges];
        var runEnd = new int[halfEdges];
        Parallel.For(0, Positions.Length, v =>
        {
            int start = groupStart[v], end = groupStart[v + 1];
            for (int a = start; a < end;)
            {
                int b = a + 1;
                while (b < end && (sorted[b] >> 32) == (sorted[a] >> 32))
                    b++;
                for (int m = a; m < b; m++)
                {
                    int h = (int)(uint)sorted[m];
                    runStart[h] = a;
                    runEnd[h] = b;
                }
                a = b;
            }
        });

        // Edges with three or more triangles: runs of three or more. Only ever queried, so the order
        // they are found in cannot reach the output.
        var nonManifold = new Dictionary<long, int>(EdgeKeyComparer.Instance);
        for (int v = 0; v < Positions.Length; v++)
        {
            int end = groupStart[v + 1];
            for (int a = groupStart[v]; a < end;)
            {
                int b = a + 1;
                while (b < end && (sorted[b] >> 32) == (sorted[a] >> 32))
                    b++;
                if (b - a >= 3)
                    nonManifold[EdgeKey(v, (int)(sorted[a] >> 32))] = b - a;
                a = b;
            }
        }
        NonManifoldEdges = nonManifold;

        // Neighbours are collected twice, once to size the output and once to fill it: cheaper than
        // keeping a list per triangle alive between the passes.
        var counts = new int[n];
        Parallel.For(0, n, () => new List<int>(), (t, _, scratch) =>
        {
            CollectNeighbours(t, sorted, runStart, runEnd, scratch);
            counts[t] = scratch.Count;
            return scratch;
        }, _ => { });
        AdjacencyStart = new int[n + 1];
        for (int t = 0; t < n; t++)
            AdjacencyStart[t + 1] = AdjacencyStart[t] + counts[t];
        AdjacencyItems = new int[AdjacencyStart[n]];
        Parallel.For(0, n, () => new List<int>(), (t, _, scratch) =>
        {
            CollectNeighbours(t, sorted, runStart, runEnd, scratch);
            scratch.CopyTo(AdjacencyItems, AdjacencyStart[t]);
            return scratch;
        }, _ => { });
    }

    /// <summary>Writes the three half-edges of triangle (i0, i1, i2) from <paramref name="h"/> on, in
    /// edge order (i0, i1), (i1, i2), (i2, i0), each as its lower and upper position.</summary>
    public static void SetHalfEdges(int i0, int i1, int i2, int h, int[] lower, int[] upper)
    {
        lower[h] = Math.Min(i0, i1);
        upper[h] = Math.Max(i0, i1);
        lower[h + 1] = Math.Min(i1, i2);
        upper[h + 1] = Math.Max(i1, i2);
        lower[h + 2] = Math.Min(i2, i0);
        upper[h + 2] = Math.Max(i2, i0);
    }

    /// <summary>
    /// Groups half-edges under their lower position and sorts each group by (upper position,
    /// half-edge index), groups in parallel. Returns <c>upper &lt;&lt; 32 | h</c> per half-edge;
    /// position v's group is <c>[groupStart[v], groupStart[v + 1])</c>. Within a group, each run of
    /// equal upper position is one edge, its half-edges ascending.
    /// </summary>
    public static long[] GroupHalfEdges(int positionCount, int[] lower, int[] upper,
        out int[] groupStart)
    {
        int halfEdges = lower.Length;
        var start = new int[positionCount + 1];
        foreach (int v in lower)
            start[v + 1]++;
        for (int v = 0; v < positionCount; v++)
            start[v + 1] += start[v];
        var sorted = new long[halfEdges];
        var cursor = new int[positionCount];
        Array.Copy(start, cursor, positionCount);
        for (int h = 0; h < halfEdges; h++)
            sorted[cursor[lower[h]]++] = ((long)upper[h] << 32) | (uint)h;
        Parallel.For(0, positionCount, v =>
        {
            // Insertion sort: a group is a vertex's edges, a handful of entries. Array.Sort ran 3–4×
            // slower here through the first two DAG levels — its generic helper was left on
            // unoptimised JIT code while the simplifier was still being compiled.
            for (int i = start[v] + 1; i < start[v + 1]; i++)
            {
                long item = sorted[i];
                int j = i - 1;
                while (j >= start[v] && sorted[j] > item)
                {
                    sorted[j + 1] = sorted[j];
                    j--;
                }
                sorted[j + 1] = item;
            }
        });
        groupStart = start;
        return sorted;
    }

    /// <summary>Triangle <paramref name="t"/>'s neighbours in contract order: its distinct edges by
    /// first occurrence, and each edge's other triangles ascending, each neighbour listed once.</summary>
    private static void CollectNeighbours(int t, long[] sorted, int[] runStart, int[] runEnd,
        List<int> into)
    {
        into.Clear();
        // An edge's first occurrence is the h at the head of its run; sort t's (up to) three edges
        // by it, dropping repeats of the same edge.
        Span<int> heads = stackalloc int[3];
        int edges = 0;
        for (int e = 0; e < 3; e++)
        {
            int head = runStart[t * 3 + e];
            if (heads[..edges].Contains(head))
                continue;
            int at = edges++;
            while (at > 0 && FirstOccurrence(sorted, heads[at - 1]) > FirstOccurrence(sorted, head))
            {
                heads[at] = heads[at - 1];
                at--;
            }
            heads[at] = head;
        }
        for (int e = 0; e < edges; e++)
        {
            int end = runEnd[(int)(uint)sorted[heads[e]]];
            for (int m = heads[e]; m < end; m++)
            {
                // Contains() is a linear scan, but these lists hold a handful of entries — a
                // manifold edge yields two.
                int other = (int)(uint)sorted[m] / 3;
                if (other != t && !into.Contains(other))
                    into.Add(other);
            }
        }
    }

    private static int FirstOccurrence(long[] sorted, int head) => (int)(uint)sorted[head];

    public Vector3 TriangleNormal(int i0, int i1, int i2)
    {
        Vector3 v0 = Positions[i0];
        return (Positions[i1] - v0).Cross(Positions[i2] - v0).Normalized();
    }
}
