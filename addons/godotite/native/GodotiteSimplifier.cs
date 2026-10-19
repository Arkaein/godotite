using System;
using System.Collections.Generic;
using Godot;

namespace Godotite;

/// <summary>
/// Quadric edge-collapse simplification of one group's triangles, with the group's boundary locked.
/// The single most expensive stage of a build — 52% of it — and the most intricate.
///
/// Triangles are structs, 28 bytes each and no object per triangle, since every level of the DAG
/// holds its triangles in them. Within Simplify a triangle is addressed by its SLOT, its index in the
/// input list, which never changes: the vertex-to-triangle map holds slots, and removal only marks a
/// slot dead. The live order, which decides the output order and so the whole DAG downstream, is
/// kept separately and swap-removed exactly as the list itself once was.
/// </summary>
public sealed class GodotiteSimplifier
{

    /// <summary>Why a candidate collapse was refused. Counted rather than logged, because the
    /// distribution is what says whether a rule is doing anything.</summary>
    public enum Reject
    {
        Seam, BothBorder, DeadVertex, Link, Fold, Needle, Stretch, Applied, Count,
    }

    /// <summary>Collapse rejection thresholds. Aspect is shortest-altitude over longest-edge, ~0.87
    /// for an equilateral triangle; 0.05 is roughly a 3 degree needle.</summary>
    public const float CollapseMinNormalDot = 0.7f;
    public const float CollapseMinAspect = 0.05f;

    public struct Triangle
    {
        public int I0, I1, I2;
        public int C0, C1, C2;
        public int Material;

        public Triangle(int i0, int i1, int i2)
        {
            I0 = i0;
            I1 = i1;
            I2 = i2;
            C0 = C1 = C2 = 0;
            Material = 0;
        }

        public bool IsDegenerate => I0 == I1 || I1 == I2 || I2 == I0;

        public void ReplaceVertex(int removeIdx, int keepIdx, int keepCorner)
        {
            if (I0 == removeIdx) { I0 = keepIdx; C0 = keepCorner; }
            if (I1 == removeIdx) { I1 = keepIdx; C1 = keepCorner; }
            if (I2 == removeIdx) { I2 = keepIdx; C2 = keepCorner; }
        }
    }

    public struct Edge
    {
        public int I0, I1;
        public long Key;
        public double Error;
    }

    public sealed class Result
    {
        public List<Triangle> Triangles = new();
        public double MaxError;
        public int[] Rejects = new int[(int)Reject.Count];
    }

    public bool CoarsenSeamCurves = true;
    public bool CoarsenMeshBoundaries;

    /// <summary>
    /// Largest factor a collapse may change a triangle's texel density — UV area over world area —
    /// by. 0 disables the test.
    ///
    /// Attribute error scores how far a UV VALUE moves, which is not the artifact: a collapse can
    /// leave every vertex UV untouched and still wreck the mapping, because it scales the triangle
    /// differently in world space and UV space. Measures the CHANGE rather than deviation from the
    /// source, so already-uneven mapping is not frozen in place.
    /// </summary>
    public double UvDensityLimit = 4.0;

    private readonly GodotiteMesh _mesh;
    private readonly List<int> _linkNeighbours = new(16);
    private readonly List<int> _linkCounted = new(16);
    private readonly List<int> _degenerate = new(8);

    public GodotiteSimplifier(GodotiteMesh mesh) => _mesh = mesh;

    /// <summary>
    /// Collapses edges cheapest-first until the target count is reached or nothing is left that may
    /// legally collapse.
    /// </summary>
    public Result Simplify(List<Triangle> triangles, List<Edge> lockedEdges, int targetCount)
    {
        var result = new Result();
        double maxError = 0.0;
        var rejects = new int[(int)Reject.Count];

        // Lookup sets built once, replacing what were linear scans over lockedEdges per candidate.
        var lockedKeys = new HashSet<long>(GodotiteMesh.EdgeKeyComparer.Instance);
        var borderVertices = new HashSet<int>();
        // Vertices pinned by a CLUSTER INTERFACE — a locked edge that is not a mesh boundary, so
        // another cluster holds the other side. These can never move or the two crack apart.
        // Vertices on a genuine mesh boundary are not in here and may slide along that boundary.
        var interfaceVertices = new HashSet<int>();
        foreach (Edge locked in lockedEdges)
        {
            lockedKeys.Add(locked.Key);
            borderVertices.Add(locked.I0);
            borderVertices.Add(locked.I1);
            if (!_mesh.MeshBoundaryEdges.Contains(locked.Key))
            {
                interfaceVertices.Add(locked.I0);
                interfaceVertices.Add(locked.I1);
            }
        }
        // Positions a neighbouring cell of a chunked build shares (GodotiteMesh.Pinned): fixed exactly
        // as a cluster interface is, though no locked edge need run through them.
        if (_mesh.Pinned.Length > 0)
        {
            foreach (Triangle tri in triangles)
            {
                Pin(tri.I0);
                Pin(tri.I1);
                Pin(tri.I2);
            }

            void Pin(int v)
            {
                if (_mesh.Pinned[v])
                {
                    borderVertices.Add(v);
                    interfaceVertices.Add(v);
                }
            }
        }

        // Locked edges that may nonetheless collapse, because they bound the mesh rather than a
        // neighbouring cluster. Off by default — measured, this is the largest single source of
        // visible error in the system, because it pulls outlines inward for free.
        var coarsenableKeys = new HashSet<long>(GodotiteMesh.EdgeKeyComparer.Instance);
        // Who each outline vertex continues to ALONG the outline. Pricing a boundary collapse needs
        // the neighbour the outline carries on to, not just the edge being collapsed.
        var boundaryNeighbours = new Dictionary<int, List<int>>();
        if (CoarsenMeshBoundaries)
        {
            foreach (Edge locked in lockedEdges)
            {
                if (!_mesh.MeshBoundaryEdges.Contains(locked.Key))
                    continue;
                if (!interfaceVertices.Contains(locked.I0) && !interfaceVertices.Contains(locked.I1))
                    coarsenableKeys.Add(locked.Key);
                AddNeighbour(boundaryNeighbours, locked.I0, locked.I1);
                AddNeighbour(boundaryNeighbours, locked.I1, locked.I0);
            }
        }

        // Triangles by slot, edited in place. `order` is the live triangles in output order, and
        // `positionOf` each slot's place in it, -1 once removed; see the class summary.
        Span<Triangle> slots = System.Runtime.InteropServices.CollectionsMarshal.AsSpan(triangles);
        var order = new List<int>(slots.Length);
        var positionOf = new int[slots.Length];
        for (int t = 0; t < slots.Length; t++)
        {
            order.Add(t);
            positionOf[t] = t;
        }

        var vertexToTris = new Dictionary<int, List<int>>();
        for (int t = 0; t < slots.Length; t++)
        {
            AddVertexTri(vertexToTris, slots[t].I0, t);
            AddVertexTri(vertexToTris, slots[t].I1, t);
            AddVertexTri(vertexToTris, slots[t].I2, t);
        }

        // Seam curves: who each seam vertex continues to along a seam, for pricing a collapse along
        // one by how far the curve moves (SeamDeviationSquared).
        var seamNeighbours = SeamCurves(slots);

        var candidates = new List<Edge>(triangles.Count * 3);
        // Each interior edge is reached from both of its triangles. Its cost is identical either way
        // — every term is a commutative sum, a symmetric distance, or a minimum over both directions
        // — so the second visit reuses the first result instead of evaluating both endpoints' position
        // and UV quadrics again. Costing candidates was half the simplifier's time before this.
        //
        // Both visits still become candidates: they traverse the edge in opposite directions, and
        // the endpoint tie-breaks read that order, so dropping one could change which collapses
        // happen.
        var costs = new Dictionary<long, double>(triangles.Count * 2, GodotiteMesh.EdgeKeyComparer.Instance);
        foreach (Triangle tri in slots)
        {
            AddCandidate(candidates, costs, tri.I0, tri.I1, lockedKeys, coarsenableKeys, boundaryNeighbours, seamNeighbours);
            AddCandidate(candidates, costs, tri.I1, tri.I2, lockedKeys, coarsenableKeys, boundaryNeighbours, seamNeighbours);
            AddCandidate(candidates, costs, tri.I2, tri.I0, lockedKeys, coarsenableKeys, boundaryNeighbours, seamNeighbours);
        }

        // Total order: error, then edge key. Sorting on error alone leaves equal-cost edges — and a
        // flat region yields them by the thousand at cost 0 — to whatever the sort implementation
        // happens to do, which differs between Godot's introsort and .NET's. Collapse order decides
        // the whole DAG, so the tie has to be broken by geometry.
        candidates.Sort(static (a, b) =>
        {
            int byError = a.Error.CompareTo(b.Error);
            return byError != 0 ? byError : a.Key.CompareTo(b.Key);
        });

        foreach (Edge candidate in candidates)
        {
            if (order.Count <= targetCount)
                break;
            if (IsEqualApprox(_mesh.Positions[candidate.I0], _mesh.Positions[candidate.I1]))
                continue;

            bool borderI0 = borderVertices.Contains(candidate.I0);
            bool borderI1 = borderVertices.Contains(candidate.I1);
            bool seamI0 = _mesh.IsSeam[candidate.I0];
            bool seamI1 = _mesh.IsSeam[candidate.I1];

            int removeIndex;
            int keepIndex;
            // The line this edge runs along, if any: an outline it may coarsen, or a seam's curve.
            Dictionary<int, List<int>>? line = LineOf(candidate, coarsenableKeys, boundaryNeighbours, seamNeighbours);

            if (borderI0 && borderI1)
            {
                // Refusing outright is right for a cluster interface and wrong for a mesh boundary:
                // along an outline there is no other side to tear away from.
                if (!coarsenableKeys.Contains(candidate.Key))
                {
                    rejects[(int)Reject.BothBorder]++;
                    continue;
                }
                ChooseCheaperEnd(candidate, line, out keepIndex, out removeIndex);
            }
            else if (borderI0)
            {
                keepIndex = candidate.I0;
                removeIndex = candidate.I1;
            }
            else if (borderI1)
            {
                keepIndex = candidate.I1;
                removeIndex = candidate.I0;
            }
            else if (seamI0 != seamI1)
            {
                // Exactly one endpoint carries a discontinuity: keep that one. Only REMOVING a seam
                // vertex onto a non-seam one destroys anything; collapsing onto a seam is harmless,
                // and seam onto seam merely coarsens the curve.
                keepIndex = seamI0 ? candidate.I0 : candidate.I1;
                removeIndex = seamI0 ? candidate.I1 : candidate.I0;
            }
            else
            {
                ChooseCheaperEnd(candidate, line, out keepIndex, out removeIndex);
            }

            // The genuinely destructive case: erasing a discontinuity onto a position that has none.
            if (_mesh.IsSeam[removeIndex] && !_mesh.IsSeam[keepIndex])
            {
                rejects[(int)Reject.Seam]++;
                continue;
            }
            if (!CoarsenSeamCurves && seamI0 && seamI1)
            {
                rejects[(int)Reject.Seam]++;
                continue;
            }

            // The kept vertex must still be part of the live surface: the candidate list is built
            // once, so it can hold an edge whose endpoint an earlier collapse already removed.
            // Without this the vertex is resurrected and drags triangles onto a position no longer
            // in their neighbourhood — a direct source of long stretched and folded triangles.
            if (!vertexToTris.TryGetValue(keepIndex, out List<int>? keepTris)
                || keepTris.Count == 0)
            {
                rejects[(int)Reject.DeadVertex]++;
                continue;
            }
            if (!vertexToTris.TryGetValue(removeIndex, out List<int>? affected))
                continue;

            // Topological fold: a normal-flip test cannot see this case.
            if (!IsLinkConditionMet(keepIndex, removeIndex, vertexToTris, slots))
            {
                rejects[(int)Reject.Link]++;
                continue;
            }

            Reject reason = Reject.Fold;
            if (!IsCollapseValid(affected, slots, removeIndex, keepIndex, ref reason))
            {
                rejects[(int)reason]++;
                continue;
            }

            rejects[(int)Reject.Applied]++;
            maxError = Math.Max(maxError, Math.Sqrt(Math.Max(candidate.Error, 0.0)));

            foreach (int t in affected)
                slots[t].ReplaceVertex(removeIndex, keepIndex, PickCorner(keepIndex, slots[t], removeIndex));
            foreach (int t in affected)
            {
                if (!keepTris.Contains(t))
                    keepTris.Add(t);
            }
            vertexToTris.Remove(removeIndex);

            // Remove degenerate triangles from the live order by swap, as the list itself once was.
            _degenerate.Clear();
            foreach (int t in affected)
            {
                if (slots[t].IsDegenerate)
                    _degenerate.Add(t);
            }
            foreach (int t in _degenerate)
            {
                int idx = positionOf[t];
                if (idx == -1)
                    continue; // listed twice under a vertex, and already removed
                int lastIdx = order.Count - 1;
                if (idx != lastIdx)
                {
                    int swapped = order[lastIdx];
                    order[idx] = swapped;
                    positionOf[swapped] = idx;
                }
                order.RemoveAt(lastIdx);
                positionOf[t] = -1;

                RemoveFromVertex(vertexToTris, slots[t].I0, t);
                RemoveFromVertex(vertexToTris, slots[t].I1, t);
                RemoveFromVertex(vertexToTris, slots[t].I2, t);
            }
        }

        var survivors = new List<Triangle>(order.Count);
        foreach (int t in order)
            survivors.Add(slots[t]);
        result.Triangles = survivors;
        result.MaxError = maxError;
        result.Rejects = rejects;
        return result;
    }

    private void ChooseCheaperEnd(Edge candidate, Dictionary<int, List<int>>? line, out int keepIndex,
        out int removeIndex)
    {
        // Weighed by the SAME rule that ordered the queue, the line's deviation included, or an edge
        // is queued at one cost and collapsed at another. Leaving the deviation out here was exactly
        // that: an outline edge was queued at the cheap direction, removing a vertex in a straight
        // run, and collapsed the other way, removing the corner at its end, a direction never
        // priced. On Sponza the courtyard floor, two triangles, lost one, half the floor, at an
        // error of 0.05; at 10 px a hole showed the ground below (GODOTITE.md step 22).
        if (DirectionCost(candidate, candidate.I0, line) <= DirectionCost(candidate, candidate.I1, line))
        {
            keepIndex = candidate.I0;
            removeIndex = candidate.I1;
        }
        else
        {
            keepIndex = candidate.I1;
            removeIndex = candidate.I0;
        }
    }

    /// <summary>What collapsing `candidate` onto `keep` costs: the collapse itself, and, along a line
    /// (an outline or a seam's curve), how far the line moves.</summary>
    private double DirectionCost(Edge candidate, int keep, Dictionary<int, List<int>>? line)
    {
        double cost = _mesh.CollapseCostOnto(candidate.I0, candidate.I1, keep);
        if (line != null)
        {
            double deviation = OutlineDeviation(keep == candidate.I0 ? candidate.I1 : candidate.I0, keep, line);
            cost += deviation * deviation;
        }
        return cost;
    }

    /// <summary>The line an edge runs along, whose neighbours price its collapse: an outline it may
    /// coarsen, a seam's curve, or none.</summary>
    private static Dictionary<int, List<int>>? LineOf(Edge edge, HashSet<long> coarsenableKeys,
        Dictionary<int, List<int>> boundaryNeighbours, Dictionary<int, List<int>> seamNeighbours)
    {
        if (coarsenableKeys.Contains(edge.Key))
            return boundaryNeighbours;
        return seamNeighbours.TryGetValue(edge.I0, out List<int>? along) && along.Contains(edge.I1)
            ? seamNeighbours : null;
    }

    private void AddCandidate(List<Edge> candidates, Dictionary<long, double> costs, int i0, int i1,
        HashSet<long> lockedKeys, HashSet<long> coarsenableKeys,
        Dictionary<int, List<int>> boundaryNeighbours, Dictionary<int, List<int>> seamNeighbours)
    {
        long key = GodotiteMesh.EdgeKey(i0, i1);
        if (lockedKeys.Contains(key) && !coarsenableKeys.Contains(key))
            return;
        if (!costs.TryGetValue(key, out double error))
        {
            var edge = new Edge { I0 = i0, I1 = i1, Key = key };
            Dictionary<int, List<int>>? line = LineOf(edge, coarsenableKeys, boundaryNeighbours, seamNeighbours);
            // Each direction whole, then the cheaper: the cheaper collapse plus the cheaper
            // deviation, taken apart, may belong to opposite directions (ChooseCheaperEnd).
            error = line == null ? _mesh.CollapseCost(i0, i1)
                : Math.Min(DirectionCost(edge, i0, line), DirectionCost(edge, i1, line));
            costs[key] = error;
        }
        candidates.Add(new Edge { I0 = i0, I1 = i1, Key = key, Error = error });
    }

    private static void AddNeighbour(Dictionary<int, List<int>> map, int vertex, int neighbour)
    {
        if (!map.TryGetValue(vertex, out List<int>? list))
        {
            list = new List<int>(2);
            map[vertex] = list;
        }
        list.Add(neighbour);
    }

    /// <summary>
    /// The group's seam curves: for each vertex on one, its neighbours along it. An edge is on a
    /// seam when the triangles sharing it disagree, at either end, on the attributes there (a UV
    /// seam, a crease, a material border such as a shoreline): crossing it, the surface's
    /// attributes jump.
    ///
    /// A collapse along a seam keeps the seam (GodotiteMesh.LostSeamError) but moves its curve
    /// across the surface, and a quadric, measuring distance to planes, barely sees that: sliding a
    /// shoreline along the flat water costs nothing. So it is priced as an outline is
    /// (DirectionCost), by how far the curve moves. Without it the curves, once free to
    /// coarsen, coarsened at no cost, and a coastline, the most contrasting line in its view,
    /// changed more than anything round it.
    /// </summary>
    private Dictionary<int, List<int>> SeamCurves(Span<Triangle> slots)
    {
        var neighbours = new Dictionary<int, List<int>>();
        // Per edge: the corners at its two ends in the first triangle seen, and whether another
        // triangle disagreed. Keyed in the order first seen, so the result does not depend on hashing.
        var first = new Dictionary<long, (int Low, int High, int A, int B)>(GodotiteMesh.EdgeKeyComparer.Instance);
        var seamKeys = new List<long>();
        var marked = new HashSet<long>(GodotiteMesh.EdgeKeyComparer.Instance);
        foreach (Triangle tri in slots)
        {
            Visit(tri.I0, tri.C0, tri.I1, tri.C1);
            Visit(tri.I1, tri.C1, tri.I2, tri.C2);
            Visit(tri.I2, tri.C2, tri.I0, tri.C0);
        }
        foreach (long key in seamKeys)
        {
            (int low, int high, _, _) = first[key];
            AddNeighbour(neighbours, low, high);
            AddNeighbour(neighbours, high, low);
        }
        return neighbours;

        void Visit(int a, int ca, int b, int cb)
        {
            if (!_mesh.IsSeam[a] || !_mesh.IsSeam[b])
                return;
            // Corners in the order of their positions, so both triangles compare like with like.
            if (a > b)
            {
                (a, b) = (b, a);
                (ca, cb) = (cb, ca);
            }
            long key = GodotiteMesh.EdgeKey(a, b);
            if (!first.TryGetValue(key, out var seen))
            {
                first[key] = (a, b, ca, cb);
                return;
            }
            if (marked.Contains(key))
                return;
            if (_mesh.CornerGap(seen.A, ca) > SeamCornerGap || _mesh.CornerGap(seen.B, cb) > SeamCornerGap)
            {
                marked.Add(key);
                seamKeys.Add(key);
            }
        }
    }

    /// <summary>Attribute difference above which two corners count as different sides of a seam,
    /// as GodotiteMesh classifies seam positions.</summary>
    private const double SeamCornerGap = 1e-4;

    /// <summary>
    /// What collapsing along an outline costs, squared so it adds to the quadric term (DirectionCost);
    /// seam curves are priced the same way (SeamCurves).
    ///
    /// A quadric measures distance to planes, so sliding a vertex WITHIN the surface it already lies
    /// on costs nothing. In the interior that is right — neighbouring triangles close the hole. On an
    /// open outline there is no other side, so the outline is pulled inward and real surface is
    /// deleted for free: measured, that made boundary coarsening the largest single source of visible
    /// error in the system, 18x the error on Sponza for 1.4% fewer triangles.
    ///
    /// What it costs is how far the outline MOVES. Collapsing `a - b - n` to `a - n` leaves the
    /// surface short by the deviation of b from segment a-n — the polyline-simplification measure,
    /// and already a distance, so it belongs in the same units as everything else here.
    ///
    /// Each direction is priced whole, collapse and deviation together, and the queue and the
    /// collapse both take the cheaper direction by that total (ChooseCheaperEnd): an edge must be
    /// queued at the cost it will actually be collapsed at.
    ///
    /// This: how far the line moves if `remove` collapses onto `keep`.
    /// </summary>
    private double OutlineDeviation(int remove, int keep,
        Dictionary<int, List<int>> boundaryNeighbours)
    {
        Vector3 position = _mesh.Positions[remove];
        Vector3 target = _mesh.Positions[keep];
        double worst = -1.0;
        if (boundaryNeighbours.TryGetValue(remove, out List<int>? neighbours))
        {
            foreach (int neighbour in neighbours)
            {
                if (neighbour == keep)
                    continue;
                worst = Math.Max(worst,
                    PointSegmentDistance(position, target, _mesh.Positions[neighbour]));
            }
        }
        // An outline that does not continue — a lone edge, or an end — loses the whole span.
        return worst < 0.0 ? position.DistanceTo(target) : worst;
    }

    private static double PointSegmentDistance(Vector3 point, Vector3 a, Vector3 b)
    {
        Vector3 span = b - a;
        float lengthSquared = span.LengthSquared();
        if (lengthSquared <= 0.0f)
            return point.DistanceTo(a);
        float t = Math.Clamp((point - a).Dot(span) / lengthSquared, 0.0f, 1.0f);
        return point.DistanceTo(a + span * t);
    }

    private static void AddVertexTri(Dictionary<int, List<int>> map, int vertex, int tri)
    {
        if (!map.TryGetValue(vertex, out List<int>? list))
        {
            list = new List<int>(6);
            map[vertex] = list;
        }
        list.Add(tri);
    }

    private static void RemoveFromVertex(Dictionary<int, List<int>> map, int vertex, int tri)
    {
        if (!map.TryGetValue(vertex, out List<int>? list))
            return;
        // Swap-remove every occurrence, in case a triangle is listed under a vertex more than once.
        int pos;
        while ((pos = list.IndexOf(tri)) != -1)
        {
            int last = list.Count - 1;
            if (pos != last)
                list[pos] = list[last];
            list.RemoveAt(last);
        }
    }

    /// <summary>
    /// The classic link condition. Two endpoints of a collapsible edge should share exactly as many
    /// neighbouring vertices as they share triangles — two for an interior edge, one on a boundary.
    /// Any extra common neighbour means the collapse would weld two parts of the surface that touch
    /// only at that vertex, producing an overlapping fan. Geometry tests cannot see this.
    /// </summary>
    private bool IsLinkConditionMet(int i0, int i1, Dictionary<int, List<int>> vertexToTris,
        Span<Triangle> slots)
    {
        // Reused lists rather than two new hash sets per call: this runs for every candidate that
        // gets this far, and a vertex's neighbourhood is 6 to 12 entries, where a linear scan beats
        // hashing and allocates nothing. Same membership, so the same counts.
        List<int> neighbours = _linkNeighbours;
        neighbours.Clear();
        foreach (int t in vertexToTris[i0])
        {
            Triangle tri = slots[t];
            if (tri.I0 != i0 && !neighbours.Contains(tri.I0)) neighbours.Add(tri.I0);
            if (tri.I1 != i0 && !neighbours.Contains(tri.I1)) neighbours.Add(tri.I1);
            if (tri.I2 != i0 && !neighbours.Contains(tri.I2)) neighbours.Add(tri.I2);
        }

        int sharedTris = 0;
        int common = 0;
        List<int> counted = _linkCounted;
        counted.Clear();
        foreach (int t in vertexToTris[i1])
        {
            Triangle tri = slots[t];
            if (tri.I0 == i0 || tri.I1 == i0 || tri.I2 == i0)
                sharedTris++;
            CountCommon(tri.I0, i1, neighbours, counted, ref common);
            CountCommon(tri.I1, i1, neighbours, counted, ref common);
            CountCommon(tri.I2, i1, neighbours, counted, ref common);
        }
        return common <= sharedTris;
    }

    private static void CountCommon(int vi, int i1, List<int> neighbours, List<int> counted,
        ref int common)
    {
        if (vi != i1 && neighbours.Contains(vi) && !counted.Contains(vi))
        {
            counted.Add(vi);
            common++;
        }
    }

    /// <summary>
    /// Refuses a collapse that would fold or needle any triangle it touches. Shape is only rejected
    /// when the collapse makes that triangle WORSE — an absolute test deadlocks on triangles already
    /// thin from a previous level.
    /// </summary>
    private bool IsCollapseValid(List<int> affected, Span<Triangle> slots, int removeIndex,
        int keepIndex, ref Reject reason)
    {
        foreach (int t in affected)
        {
            Triangle tri = slots[t];
            int i0 = tri.I0 == removeIndex ? keepIndex : tri.I0;
            int i1 = tri.I1 == removeIndex ? keepIndex : tri.I1;
            int i2 = tri.I2 == removeIndex ? keepIndex : tri.I2;
            if (i0 == i1 || i1 == i2 || i2 == i0)
                continue; // collapses to nothing and gets removed; no constraint

            Vector3 before = _mesh.TriangleNormal(tri.I0, tri.I1, tri.I2);
            Vector3 after = _mesh.TriangleNormal(i0, i1, i2);
            // A zero-length normal means zero area, before or after. Never introduce that.
            if (after == Vector3.Zero)
            {
                reason = Reject.Needle;
                return false;
            }
            if (before != Vector3.Zero && before.Dot(after) < CollapseMinNormalDot)
            {
                reason = Reject.Fold;
                return false;
            }

            float afterAspect = TriangleAspect(i0, i1, i2);
            if (afterAspect < CollapseMinAspect
                && afterAspect < TriangleAspect(tri.I0, tri.I1, tri.I2))
            {
                reason = Reject.Needle;
                return false;
            }

            if (UvDensityLimit > 0.0 && _mesh.SourceHasUvs)
            {
                double densityBefore = TexelDensity(tri.I0, tri.I1, tri.I2, tri.C0, tri.C1, tri.C2);
                if (densityBefore > 0.0)
                {
                    // The surviving corner is whichever PickCorner will actually adopt, so this
                    // prices the collapse that is going to happen rather than an idealised one.
                    int corner = PickCorner(keepIndex, tri, removeIndex);
                    int c0 = tri.I0 == removeIndex ? corner : tri.C0;
                    int c1 = tri.I1 == removeIndex ? corner : tri.C1;
                    int c2 = tri.I2 == removeIndex ? corner : tri.C2;
                    double densityAfter = TexelDensity(i0, i1, i2, c0, c1, c2);
                    if (densityAfter <= 0.0 || densityAfter > densityBefore * UvDensityLimit
                        || densityAfter * UvDensityLimit < densityBefore)
                    {
                        reason = Reject.Stretch;
                        return false;
                    }
                }
            }
        }
        return true;
    }

    /// <summary>UV area over world area. Returns 0 for a triangle degenerate in either space, which
    /// the caller reads as "no opinion" — the needle test already covers zero area.</summary>
    private double TexelDensity(int i0, int i1, int i2, int c0, int c1, int c2)
    {
        Vector3 p0 = _mesh.Positions[i0];
        double worldArea = (_mesh.Positions[i1] - p0).Cross(_mesh.Positions[i2] - p0).Length() * 0.5;
        if (worldArea <= 0.0)
            return 0.0;
        Vector2 uv0 = _mesh.CornerUvs[c0];
        Vector2 uv1 = _mesh.CornerUvs[c1];
        Vector2 uv2 = _mesh.CornerUvs[c2];
        double uvArea = Math.Abs((uv1 - uv0).Cross(uv2 - uv0)) * 0.5;
        return uvArea / worldArea;
    }

    /// <summary>Shortest altitude over longest edge: ~0.87 for an equilateral triangle, heading to
    /// 0 as it degenerates into a needle.</summary>
    private float TriangleAspect(int i0, int i1, int i2)
    {
        Vector3 v0 = _mesh.Positions[i0];
        Vector3 v1 = _mesh.Positions[i1];
        Vector3 v2 = _mesh.Positions[i2];
        float longest = Math.Max((v1 - v0).Length(),
            Math.Max((v2 - v1).Length(), (v0 - v2).Length()));
        if (longest <= 0.0f)
            return 0.0f;
        float area = (v1 - v0).Cross(v2 - v0).Length() * 0.5f;
        return (2.0f * area / longest) / longest;
    }

    /// <summary>
    /// Which corner at `keepPosition` a triangle should adopt when its corner at `removePosition`
    /// moves there. Unambiguous away from seams; on a seam the position carries one corner per side,
    /// and picking the wrong one tears the attribute across the seam. Chosen by matching against the
    /// triangle's own surviving corners, because those are on the side it belongs to. Only corners of
    /// the triangle's own material are candidates, while it has any there: a position can carry
    /// corners of several surfaces, each with that surface's attributes (a shoreline's land, sea
    /// floor and water), and a land triangle taking the water's corner drew black.
    /// </summary>
    private int PickCorner(int keepPosition, in Triangle tri, int removePosition)
    {
        int single = _mesh.PositionCorner[keepPosition];
        if (single >= 0)
            return single;

        Vector3 contextNormal = Vector3.Zero;
        Vector2 contextUv = Vector2.Zero;
        int counted = 0;
        AccumulateContext(tri.I0, tri.C0, removePosition, ref contextNormal, ref contextUv, ref counted);
        AccumulateContext(tri.I1, tri.C1, removePosition, ref contextNormal, ref contextUv, ref counted);
        AccumulateContext(tri.I2, tri.C2, removePosition, ref contextNormal, ref contextUv, ref counted);

        int start = _mesh.PositionCornerStart[keepPosition];
        int end = _mesh.PositionCornerStart[keepPosition + 1];
        if (counted == 0)
            return _mesh.PositionCorners[start];
        contextNormal /= counted;
        contextUv /= counted;

        int best = _mesh.PositionCorners[start];
        double bestScore = double.PositiveInfinity;
        Vector3 normalised = contextNormal.Normalized();
        bool ownMaterial = false;
        for (int k = start; k < end && !ownMaterial; k++)
            ownMaterial = _mesh.CornerMaterial[_mesh.PositionCorners[k]] == tri.Material;
        for (int k = start; k < end; k++)
        {
            int corner = _mesh.PositionCorners[k];
            if (ownMaterial && _mesh.CornerMaterial[corner] != tri.Material)
                continue;
            double score = 1.0 - _mesh.CornerNormals[corner].Dot(normalised)
                + _mesh.CornerUvs[corner].DistanceTo(contextUv);
            if (score < bestScore)
            {
                bestScore = score;
                best = corner;
            }
        }
        return best;
    }

    private void AccumulateContext(int position, int corner, int removePosition,
        ref Vector3 contextNormal, ref Vector2 contextUv, ref int counted)
    {
        if (position == removePosition)
            return;
        contextNormal += _mesh.CornerNormals[corner];
        contextUv += _mesh.CornerUvs[corner];
        counted++;
    }

    /// <summary>Godot core's is_equal_approx tolerance (CMP_EPSILON, 1e-5) rather than the ten times
    /// stricter C# default; see GodotiteMesh.IsEqualApprox.</summary>
    private static bool IsEqualApprox(Vector3 a, Vector3 b)
        => Approx(a.X, b.X) && Approx(a.Y, b.Y) && Approx(a.Z, b.Z);

    private static bool Approx(float a, float b)
    {
        if (a == b)
            return true;
        float tolerance = 1e-5f * Math.Abs(a);
        if (tolerance < 1e-5f)
            tolerance = 1e-5f;
        return Math.Abs(a - b) < tolerance;
    }
}
