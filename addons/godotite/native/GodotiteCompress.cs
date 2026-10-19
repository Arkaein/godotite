using System;
using System.Collections.Generic;
using Godot;

namespace Godotite;

/// <summary>
/// Rebuilds a finished DAG's cluster meshes with Godot's vertex compression
/// (ARRAY_FLAG_COMPRESS_ATTRIBUTES) without opening cracks between clusters (GODOTITE.md step 19).
///
/// Godot stores a compressed position as three 16-bit fractions of its surface's bounding box, and
/// truncates rather than rounds. A vertex shared by two clusters is quantized in each one's own
/// box, so the two can decode a step apart: a hairline crack. Three things close it:
/// * **Aligned boxes.** Each cluster's box is a cube, a power of two in size, its origin a whole
///   number of its own steps (size / 65535) from a grid corner below the whole DAG, and forced on
///   every surface by two unused vertices at its corners. A larger box's lattice is then a subset of
///   every smaller box's. Aligning origins to the step rather than the size is what keeps boxes
///   small: aligned to its size, a box usually straddled a cell boundary and had to double, to four
///   times the cluster at the median.
/// * **Snapping.** Every vertex is moved onto the lattice of the largest compressed box it appears
///   in, then nudged up by half the smallest box's step, so truncation lands on the same lattice
///   point in every box, as far from either edge as it can be. All clusters decode it alike, up to
///   float rounding. A quarter step was only a couple of float ulps on a small hollow world box.
/// * **A margin**, the whole DAG's step, round every box, so snapping never moves a vertex out.
/// * **A cap.** Only clusters whose box is at most MaxBoxOverMedian times the median box are
///   compressed. The rest, the few coarsest, keep float positions, set to the lattice points exactly.
///   Without it a vertex reaching the root would sit on the root's lattice at every level, up close
///   too: half of 1/65535 of the whole mesh, ~8 mm on the hollow world and 12 cm on a 10 km one, and
///   near vertices merged. With it, precision follows cluster size instead of mesh size, for 10 of
///   493 clusters left uncompressed on the terrain, 16 of 1946 on the hollow world and 54 of 201 on
///   Sponza, whose clusters vary more in size.
/// * **A floor.** Clusters whose box is under the median by more than MinBoxUnderMedian stay
///   uncompressed too. The nudge is half the smallest box's step, and in the largest box that is
///   a fraction of a step a float can only hold to about 2^-8 of it; past a ratio of ~128 between
///   the two it rounds away, truncation can land a step low, and the vertex cracks open by a step
///   of the largest box. A one-triangle leaf left at a chunked build's cell border (1.2 m, against
///   265 m boxes above it) opened a 7 mm crack this way. Bounding both ends keeps the ratio at 64.
///
/// Vertices are matched by the builder's weld key, not their exact bits: level 0 keeps the source's
/// own positions while coarser levels use the welded pool, so one vertex can differ sub-millimetre
/// between levels. Every vertex of a weld cell goes to the one point snapped from the first seen.
/// Main thread only: it reads and rebuilds engine meshes.
/// </summary>
public static class GodotiteCompress
{
    private const double Levels = 65535.0;

    /// <summary>Largest box compressed, in median cluster boxes: with power-of-two sizes and a
    /// cluster growing ~1.4x a level, about four levels above the median.</summary>
    private const double MaxBoxOverMedian = 4.0;

    /// <summary>Smallest box compressed, as a fraction of the median: with the cap, compressed boxes
    /// span at most 64x, so the nudge stays two bits clear of float rounding.</summary>
    private const double MinBoxUnderMedian = 16.0;

    /// <summary>Compresses the cluster meshes in place; returns how many clusters were left
    /// uncompressed for their size, and how many surfaces for their normals or tangents.</summary>
    public static Vector2I CompressMeshes(Godot.Collections.Array meshes)
    {
        // Bounds of every cluster, and of the whole DAG.
        var min = new Vector3[meshes.Count];
        var max = new Vector3[meshes.Count];
        var all = new Aabb();
        bool any = false;
        for (int m = 0; m < meshes.Count; m++)
        {
            min[m] = Vector3.Inf;
            max[m] = -Vector3.Inf;
            ArrayMesh? mesh = meshes[m].As<ArrayMesh>();
            if (mesh == null)
                continue;
            for (int s = 0; s < mesh.GetSurfaceCount(); s++)
            {
                foreach (Vector3 p in mesh.SurfaceGetArrays(s)[(int)Mesh.ArrayType.Vertex].AsVector3Array())
                {
                    min[m] = min[m].Min(p);
                    max[m] = max[m].Max(p);
                }
            }
            var bounds = new Aabb(min[m], max[m] - min[m]);
            all = any ? all.Merge(bounds) : bounds;
            any = true;
        }
        if (!any)
            return Vector2I.Zero;

        // Snapping moves a vertex by at most half the coarsest step, which is at most the whole
        // DAG's box step; that, plus the nudge, is the margin every box keeps.
        double margin = BoxSize(Math.Max(all.Size.X, Math.Max(all.Size.Y, all.Size.Z))) / Levels * 2.0;
        // The grid's corner, below every cluster's box.
        var grid = new Vector3D(all.Position.X - 2.0 * margin, all.Position.Y - 2.0 * margin,
            all.Position.Z - 2.0 * margin);
        var origin = new Vector3[meshes.Count];
        var size = new double[meshes.Count];
        for (int m = 0; m < meshes.Count; m++)
        {
            if (meshes[m].As<ArrayMesh>() == null)
                continue;
            (origin[m], size[m]) = AlignedBox(min[m], max[m], margin, grid);
        }
        var sorted = new List<double>();
        for (int m = 0; m < meshes.Count; m++)
        {
            if (meshes[m].As<ArrayMesh>() != null)
                sorted.Add(size[m]);
        }
        sorted.Sort();
        double cap = sorted[sorted.Count / 2] * MaxBoxOverMedian;
        double floor = sorted[sorted.Count / 2] / MinBoxUnderMedian;

        // The largest and smallest compressed box each vertex appears in, and its first position seen.
        var boxes = new Dictionary<(int, int, int), (double Largest, double Smallest, Vector3 First)>();
        for (int m = 0; m < meshes.Count; m++)
        {
            ArrayMesh? mesh = meshes[m].As<ArrayMesh>();
            if (mesh == null || size[m] > cap || size[m] < floor)
                continue;
            for (int s = 0; s < mesh.GetSurfaceCount(); s++)
            {
                foreach (Vector3 p in mesh.SurfaceGetArrays(s)[(int)Mesh.ArrayType.Vertex].AsVector3Array())
                {
                    var key = Key(p);
                    boxes[key] = boxes.TryGetValue(key, out var seen)
                        ? (Math.Max(seen.Largest, size[m]), Math.Min(seen.Smallest, size[m]), seen.First)
                        : (size[m], size[m], p);
                }
            }
        }

        // Where each weld cell's vertices go: nudged in compressed clusters, and the lattice point
        // itself, which the compressed ones decode to, in the others.
        var snapped = new Dictionary<(int, int, int), (Vector3 Nudged, Vector3 Exact)>(boxes.Count);
        foreach (var (key, box) in boxes)
        {
            snapped[key] = (Snap(box.First, grid, box.Largest / Levels, 0.5 * box.Smallest / Levels),
                Snap(box.First, grid, box.Largest / Levels, 0.0));
        }

        int uncompressed = 0, kept = 0;
        for (int m = 0; m < meshes.Count; m++)
        {
            ArrayMesh? mesh = meshes[m].As<ArrayMesh>();
            if (mesh == null)
                continue;
            bool compress = size[m] <= cap && size[m] >= floor;
            if (!compress)
                uncompressed++;
            kept += Rebuild(mesh, origin[m], size[m], snapped, compress);
        }
        return new Vector2I(uncompressed, kept);
    }

    /// <summary>The builder's weld key (GodotiteMesh.WeldPositions).</summary>
    private static (int, int, int) Key(Vector3 p) => (
        (int)MathF.Round(p.X / GodotiteMesh.WeldTolerance, MidpointRounding.AwayFromZero),
        (int)MathF.Round(p.Y / GodotiteMesh.WeldTolerance, MidpointRounding.AwayFromZero),
        (int)MathF.Round(p.Z / GodotiteMesh.WeldTolerance, MidpointRounding.AwayFromZero));

    /// <summary>The smallest power of two at least `extent`.</summary>
    private static double BoxSize(double extent) => Math.Pow(2.0, Math.Ceiling(Math.Log2(Math.Max(extent, 1e-6))));

    /// <summary>A position relative to the grid's corner, in double.</summary>
    private readonly record struct Vector3D(double X, double Y, double Z);

    /// <summary>A cube holding [min, max] plus margin, a power of two in size, its origin a whole
    /// number of its steps from the grid's corner.</summary>
    private static (Vector3 Origin, double Size) AlignedBox(Vector3 min, Vector3 max, double margin, Vector3D grid)
    {
        double lo0 = min.X - margin - grid.X, lo1 = min.Y - margin - grid.Y, lo2 = min.Z - margin - grid.Z;
        double hi0 = max.X + margin - grid.X, hi1 = max.Y + margin - grid.Y, hi2 = max.Z + margin - grid.Z;
        double size = BoxSize(Math.Max(hi0 - lo0, Math.Max(hi1 - lo1, hi2 - lo2)));
        // Rounding the origin down by up to a step can leave the far side a step short; doubling
        // then always fits.
        while (true)
        {
            double step = size / Levels;
            double o0 = Math.Floor(lo0 / step) * step, o1 = Math.Floor(lo1 / step) * step,
                o2 = Math.Floor(lo2 / step) * step;
            if (o0 + size >= hi0 && o1 + size >= hi1 && o2 + size >= hi2)
                return (new Vector3((float)(o0 + grid.X), (float)(o1 + grid.Y), (float)(o2 + grid.Z)), size);
            size *= 2.0;
        }
    }

    /// <summary>Rebuilds one cluster mesh; returns how many of its surfaces had to stay
    /// uncompressed because their normals or tangents did not survive the encoding.</summary>
    private static int Rebuild(ArrayMesh mesh, Vector3 origin, double size,
        Dictionary<(int, int, int), (Vector3 Nudged, Vector3 Exact)> snapped, bool compress)
    {
        int surfaces = mesh.GetSurfaceCount();
        var arrays = new Godot.Collections.Array[surfaces];
        var formats = new long[surfaces];
        var names = new string[surfaces];
        var materials = new Material?[surfaces];
        var compressed = new bool[surfaces];
        for (int s = 0; s < surfaces; s++)
        {
            arrays[s] = mesh.SurfaceGetArrays(s);
            formats[s] = (long)mesh.SurfaceGetFormat(s);
            names[s] = mesh.SurfaceGetName(s);
            materials[s] = mesh.SurfaceGetMaterial(s);
            compressed[s] = compress;
            if (compress)
                SteerTangents(arrays[s]);
        }
        AddSurfaces(mesh, arrays, formats, names, materials, compressed, origin, size, snapped);
        if (!compress)
            return 0;

        // A surface whose normals or tangents still do not survive the encoding stays
        // uncompressed: none on the terrain, 11 surfaces on the hollow world and 130 on Sponza,
        // the ones facing straight down -Z, see SteerTangents.
        int kept = 0;
        for (int s = 0; s < surfaces; s++)
        {
            if (!SurvivesEncoding(arrays[s], mesh.SurfaceGetArrays(s)))
            {
                compressed[s] = false;
                kept++;
            }
        }
        if (kept > 0)
            AddSurfaces(mesh, arrays, formats, names, materials, compressed, origin, size, snapped);
        return kept;
    }

    private static void AddSurfaces(ArrayMesh mesh, Godot.Collections.Array[] arrays, long[] formats,
        string[] names, Material?[] materials, bool[] compressed, Vector3 origin, double size,
        Dictionary<(int, int, int), (Vector3 Nudged, Vector3 Exact)> snapped)
    {
        mesh.ClearSurfaces();
        var corner = origin + new Vector3((float)size, (float)size, (float)size);
        for (int s = 0; s < arrays.Length; s++)
        {
            // A copy, so the original arrays stay for a second pass and for the check.
            Godot.Collections.Array a = arrays[s].Duplicate();
            Vector3[] positions = a[(int)Mesh.ArrayType.Vertex].AsVector3Array();
            // A vertex only in uncompressed clusters has no snapped point and stays where it is.
            for (int i = 0; i < positions.Length; i++)
            {
                if (snapped.TryGetValue(Key(positions[i]), out var to))
                    positions[i] = compressed[s] ? to.Nudged : to.Exact;
            }
            if (compressed[s])
            {
                // Two unused vertices at the box's corners make it the surface's bounding box,
                // which is what Godot quantizes against.
                a[(int)Mesh.ArrayType.Vertex] = Append(positions, origin, corner);
                PadAttributes(a);
            }
            else
            {
                a[(int)Mesh.ArrayType.Vertex] = positions;
            }
            // Custom channel formats have to be passed again; the rest comes from the arrays.
            long customBits = 0;
            for (int c = 0; c < 4; c++)
                customBits |= formats[s] & (7L << (GodotiteMesh.CustomShift + c * GodotiteMesh.CustomBits));
            mesh.AddSurfaceFromArrays(Mesh.PrimitiveType.Triangles, a, null, null,
                (Mesh.ArrayFormat)(customBits | (compressed[s] ? (long)Mesh.ArrayFormat.FlagCompressAttributes : 0L)));
            mesh.SurfaceSetName(s, names[s]);
            if (materials[s] != null)
                mesh.SurfaceSetMaterial(s, materials[s]);
        }
    }

    /// <summary>
    /// Godot encodes a compressed vertex's normal and tangent as one rotation, the basis with rows
    /// tangent, normal × tangent and normal, through Basis.GetAxisAngle. That treats any basis whose
    /// matrix is symmetric to within 0.01 as a singular case, a rotation near 180° or near none, and
    /// decodes it imprecisely or plain wrong: normals flipped, shading black. About 0.2% of vertices
    /// on the terrain and the hollow world, in nearly every cluster. Their tangents are turned about
    /// the normal, a degree at a time, until the basis is clear of it. The same normal and tangent
    /// always turn the same way, so a vertex shared by two clusters stays alike in both, and a
    /// tangent a degree or two off is invisible in normal mapping. A normal facing straight down
    /// -Z cannot be helped: every tangent then makes a basis near 180°, and Godot decodes it with
    /// the tangent up to ~15° off.
    /// </summary>
    private static void SteerTangents(Godot.Collections.Array a)
    {
        if (a[(int)Mesh.ArrayType.Tangent].VariantType != Variant.Type.PackedFloat32Array)
            return;
        Vector3[] normals = a[(int)Mesh.ArrayType.Normal].AsVector3Array();
        float[] tangents = a[(int)Mesh.ArrayType.Tangent].AsFloat32Array();
        bool changed = false;
        for (int i = 0; i < normals.Length; i++)
        {
            Vector3 n = normals[i].Normalized();
            Vector3 t = new Vector3(tangents[i * 4], tangents[i * 4 + 1], tangents[i * 4 + 2]).Normalized();
            if (!NearSingular(n, t))
                continue;
            Vector3 turned = t;
            for (int degrees = 1; degrees <= 45 && NearSingular(n, turned); degrees++)
            {
                float angle = Mathf.DegToRad(degrees);
                turned = (t * Mathf.Cos(angle) + n.Cross(t) * Mathf.Sin(angle)).Normalized();
            }
            tangents[i * 4] = turned.X;
            tangents[i * 4 + 1] = turned.Y;
            tangents[i * 4 + 2] = turned.Z;
            changed = true;
        }
        if (changed)
            a[(int)Mesh.ArrayType.Tangent] = tangents;
    }

    /// <summary>Whether Godot's encoding would take the basis for a singular one, with twice its
    /// tolerance, so the decoded vectors re-encode safely too (the export plugin does).</summary>
    private static bool NearSingular(Vector3 n, Vector3 t)
    {
        const float Tolerance = 0.02f;
        Vector3 b = n.Cross(t).Normalized();
        return Mathf.Abs(b.X - t.Y) < Tolerance && Mathf.Abs(n.X - t.Z) < Tolerance
            && Mathf.Abs(n.Y - b.Z) < Tolerance;
    }

    /// <summary>Whether every normal and tangent of `before` decodes within ~2.5° in `after`, and
    /// every tangent keeps its binormal sign. Real quantization error is far below that.</summary>
    private static bool SurvivesEncoding(Godot.Collections.Array before, Godot.Collections.Array after)
    {
        const float MinDot = 0.999f;
        Vector3[] n0 = before[(int)Mesh.ArrayType.Normal].AsVector3Array();
        Vector3[] n1 = after[(int)Mesh.ArrayType.Normal].AsVector3Array();
        for (int i = 0; i < n0.Length; i++)
        {
            if (n0[i].Dot(n1[i]) < MinDot * n0[i].Length())
                return false;
        }
        if (before[(int)Mesh.ArrayType.Tangent].VariantType != Variant.Type.PackedFloat32Array)
            return true;
        float[] t0 = before[(int)Mesh.ArrayType.Tangent].AsFloat32Array();
        float[] t1 = after[(int)Mesh.ArrayType.Tangent].AsFloat32Array();
        for (int i = 0; i + 3 < t0.Length; i += 4)
        {
            var a = new Vector3(t0[i], t0[i + 1], t0[i + 2]);
            var b = new Vector3(t1[i], t1[i + 1], t1[i + 2]);
            if (a.Dot(b) < MinDot * a.Length() || (t0[i + 3] < 0) != (t1[i + 3] < 0))
                return false;
        }
        return true;
    }

    /// <summary>`p` moved onto the lattice of multiples of `step` from the grid's corner, plus
    /// `nudge` on every axis.</summary>
    private static Vector3 Snap(Vector3 p, Vector3D grid, double step, double nudge) => new(
        (float)(grid.X + Math.Round((p.X - grid.X) / step) * step + nudge),
        (float)(grid.Y + Math.Round((p.Y - grid.Y) / step) * step + nudge),
        (float)(grid.Z + Math.Round((p.Z - grid.Z) / step) * step + nudge));

    private static Vector3[] Append(Vector3[] values, Vector3 a, Vector3 b)
    {
        var result = new Vector3[values.Length + 2];
        values.CopyTo(result, 0);
        result[values.Length] = a;
        result[values.Length + 1] = b;
        return result;
    }

    /// <summary>Two more entries in every per-vertex array but positions, copies of the first, for
    /// the padding vertices.</summary>
    private static void PadAttributes(Godot.Collections.Array a)
    {
        for (int t = 0; t < (int)Mesh.ArrayType.Max; t++)
        {
            if (t == (int)Mesh.ArrayType.Vertex || t == (int)Mesh.ArrayType.Index)
                continue;
            Variant v = a[t];
            switch (v.VariantType)
            {
                case Variant.Type.PackedVector3Array:
                {
                    Vector3[] x = v.AsVector3Array();
                    a[t] = Append(x, x[0], x[0]);
                    break;
                }
                case Variant.Type.PackedVector2Array:
                {
                    Vector2[] x = v.AsVector2Array();
                    var r = new Vector2[x.Length + 2];
                    x.CopyTo(r, 0);
                    r[x.Length] = x[0];
                    r[x.Length + 1] = x[0];
                    a[t] = r;
                    break;
                }
                case Variant.Type.PackedColorArray:
                {
                    Color[] x = v.AsColorArray();
                    var r = new Color[x.Length + 2];
                    x.CopyTo(r, 0);
                    r[x.Length] = x[0];
                    r[x.Length + 1] = x[0];
                    a[t] = r;
                    break;
                }
                case Variant.Type.PackedFloat32Array:
                {
                    // Tangents, or a float custom channel: four per vertex.
                    float[] x = v.AsFloat32Array();
                    var r = new float[x.Length + 8];
                    x.CopyTo(r, 0);
                    for (int k = 0; k < 8; k++)
                        r[x.Length + k] = x[k % 4];
                    a[t] = r;
                    break;
                }
                case Variant.Type.PackedByteArray:
                {
                    // An RGBA8 custom channel: four per vertex.
                    byte[] x = v.AsByteArray();
                    var r = new byte[x.Length + 8];
                    x.CopyTo(r, 0);
                    for (int k = 0; k < 8; k++)
                        r[x.Length + k] = x[k % 4];
                    a[t] = r;
                    break;
                }
            }
        }
    }
}
