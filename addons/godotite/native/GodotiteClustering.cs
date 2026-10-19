using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Godot;

namespace Godotite;

/// <summary>
/// Leaf clustering: region growing against the multi-objective score, spatial bridging across
/// disconnected pieces, and folding of stranded pockets.
///
/// ORDERING IS THE WHOLE DIFFICULTY HERE. Every tie is broken by first-encountered, so the output
/// depends on iteration order — in the border set, in each grid cell, and in the orphan-merge
/// counts. A plain HashSet anywhere in this file makes the clusters depend on hash layout, and
/// because every later stage consumes them, the whole DAG would change from a difference no test of
/// membership could see.
/// </summary>
public sealed class GodotiteClustering
{
    /// <summary>A leaf group smaller than this fraction of the target is treated as a stranded
    /// pocket and folded into a neighbour rather than becoming its own cluster.</summary>
    public const float OrphanGroupFraction = 0.25f;

    /// <summary>Rings of grid cells searched for the nearest free triangle before giving up.
    /// Generous on purpose: on sparse input the next piece can be many empty cells away, and
    /// stopping early would silently fragment the cluster instead of failing visibly.</summary>
    public const int MaxJumpRings = 64;

    public int MinClusterTriangles = 4096;
    // Doubles, because these are multiplied into scores that are then compared with a strict
    // greater-than, and rounding one of them to float32 flips tie decisions: the same mistake in the
    // DAG's grouping changed 47 of 300 groups.
    public double MaterialSplitPenalty = 0.05;
    public double BoundaryEdgeWeight = 0.05;
    public bool BridgeDisconnected = true;
    public double BridgeJumpRadius = 1.0;

    /// <summary>Which connected piece of the source mesh each triangle belongs to.</summary>
    public int[] TriangleComponent = Array.Empty<int>();
    public int ComponentCount;

    /// <summary>The grown groups, each a list of triangle indices in the order they were taken.</summary>
    public List<List<int>> Groups = new();

    /// <summary>
    /// Largest region leaf clustering will grow on one thread, in clusters. Regions are fixed by the
    /// geometry and this number — never by the core count — so every machine builds the same DAG.
    ///
    /// A trade between cluster quality and parallelism on MEDIUM meshes. Clusters cannot cross a
    /// region border, and bridging cannot jump across one, so every border costs a little quality;
    /// fragmented meshes feel it most. Measured, as compactness median / p95 on Sponza and leaf
    /// clustering time on the 980k-triangle terrain:
    ///
    ///     no regions   Sponza 0.59 / 2.40   terrain 8.9 s
    ///     16           Sponza 0.75 / 2.67   terrain 2.2 s
    ///     64           Sponza 0.64 / 2.21   terrain 3.9 s
    ///
    /// 64 keeps Sponza close to its old quality, and a 10M-triangle mesh still splits into ~38
    /// regions — far more than there are cores — so the target scale gives nothing up.
    /// </summary>
    public const int RegionClusters = 64;

    private readonly GodotiteMesh _mesh;
    private float _cellSize = 1.0f;
    // Whole-mesh tables, filled before regions are grown and read-only while they are.
    private Vector3[] _centroid = Array.Empty<Vector3>();
    private int[] _regionOf = Array.Empty<int>();
    private int[] _localIndex = Array.Empty<int>();
    private int _materialCount = 1;

    public GodotiteClustering(GodotiteMesh mesh) => _mesh = mesh;

    /// <summary>
    /// An insertion-ordered set of ints: O(1) add, remove and contains, iterated in the order
    /// entries were first added, and re-adding an existing entry does not move it.
    ///
    /// .NET has no built-in equivalent.
    /// Removal leaves a tombstone, compacted once they outnumber live entries, so iteration stays
    /// proportional to what is actually in the set.
    /// </summary>
    public sealed class OrderedIntSet
    {
        private readonly List<int> _order = new();
        private readonly HashSet<int> _present = new();
        private int _tombstones;

        public int Count => _present.Count;
        public bool IsEmpty => _present.Count == 0;

        public void Add(int value)
        {
            if (!_present.Add(value))
                return;
            _order.Add(value);
        }

        public void Remove(int value)
        {
            if (!_present.Remove(value))
                return;
            _tombstones++;
            if (_tombstones > _present.Count && _tombstones > 16)
                Compact();
        }

        public bool Contains(int value) => _present.Contains(value);

        private void Compact()
        {
            var live = new List<int>(_present.Count);
            foreach (int value in _order)
            {
                if (_present.Contains(value))
                    live.Add(value);
            }
            _order.Clear();
            _order.AddRange(live);
            _tombstones = 0;
        }

        public IEnumerable<int> InOrder()
        {
            foreach (int value in _order)
            {
                if (_present.Contains(value))
                    yield return value;
            }
        }
    }

    /// <summary>
    /// Labels every triangle with the connected piece it belongs to. One flood fill over the
    /// existing adjacency; the label is what tells bridging apart from ordinary region growing,
    /// since crossing INTO another piece is the thing connectivity cannot do.
    /// </summary>
    public void LabelComponents()
    {
        TriangleComponent = new int[_mesh.Triangles.Length];
        for (int i = 0; i < TriangleComponent.Length; i++)
            TriangleComponent[i] = -1;
        int label = 0;
        var stack = new Stack<int>();

        foreach (GodotiteMesh.Triangle tri in _mesh.Triangles)
        {
            if (TriangleComponent[tri.Index] >= 0)
                continue;
            stack.Clear();
            stack.Push(tri.Index);
            while (stack.Count > 0)
            {
                int index = stack.Pop();
                if (TriangleComponent[index] >= 0)
                    continue;
                TriangleComponent[index] = label;
                for (int k = _mesh.AdjacencyStart[index]; k < _mesh.AdjacencyStart[index + 1]; k++)
                {
                    int neighbour = _mesh.AdjacencyItems[k];
                    if (TriangleComponent[neighbour] < 0)
                        stack.Push(neighbour);
                }
            }
            label++;
        }
        ComponentCount = label;
    }

    /// <summary>Whether spatial bridging should run at all. Categorical rather than tuned: a mesh
    /// that is one connected piece never needs it.</summary>
    public bool BridgingActive => BridgeDisconnected && ComponentCount > 1;

    /// <summary>Where to report progress, if anywhere. Read from another thread.</summary>
    public BuildProgress? Progress;

    /// <summary>Mean triangle extent, which is the cell size of every region's bridging grid.
    /// Computed over the whole mesh before partitioning, so all regions share one set of cells.</summary>
    private void ComputeCellSize()
    {
        if (_mesh.Triangles.Length == 0)
            return;
        double extent = 0.0;
        foreach (GodotiteMesh.Triangle tri in _mesh.Triangles)
        {
            Vector3 a = _mesh.Positions[tri.I0];
            Vector3 b = _mesh.Positions[tri.I1];
            Vector3 c = _mesh.Positions[tri.I2];
            extent += (a.Max(b).Max(c) - a.Min(b).Min(c)).Length();
        }
        _cellSize = Math.Max((float)(extent / _mesh.Triangles.Length), 0.0001f);
    }

    private Vector3I CellOf(Vector3 point)
        => new(Mathf.FloorToInt(point.X / _cellSize), Mathf.FloorToInt(point.Y / _cellSize),
            Mathf.FloorToInt(point.Z / _cellSize));

    private Vector3 Centroid(GodotiteMesh.Triangle tri)
        => (_mesh.Positions[tri.I0] + _mesh.Positions[tri.I1] + _mesh.Positions[tri.I2]) / 3.0f;

    private Aabb TriangleAabb(GodotiteMesh.Triangle tri)
    {
        Vector3 v0 = _mesh.Positions[tri.I0];
        Vector3 v1 = _mesh.Positions[tri.I1];
        Vector3 v2 = _mesh.Positions[tri.I2];
        Vector3 min = v0.Min(v1).Min(v2);
        Vector3 max = v0.Max(v1).Max(v2);
        return new Aabb(min, max - min);
    }

    /// <summary>
    /// Grows contiguous, compact leaf groups. Groups are raw triangle-index lists; Cluster objects
    /// are built afterwards by the caller, so nothing is constructed for a group that orphan folding
    /// is about to empty.
    ///
    /// Region growing is greedy — each cluster claims triangles the next could have taken — so it
    /// cannot run in parallel as one pass. Instead the mesh is split into spatial regions, each grown
    /// independently on its own thread, and the results are concatenated in region order. Orphan
    /// folding then runs once over everything, which is what absorbs the partial clusters left along
    /// region borders into a neighbouring region's cluster.
    ///
    /// Deterministic by construction: regions depend only on the geometry and RegionClusters, a
    /// region reads nothing another region writes, and results are merged in a fixed order. A mesh
    /// small enough to be one region builds exactly as it did before regions existed.
    /// </summary>
    public void CreateLeafGroups()
    {
        int triangleCount = _mesh.Triangles.Length;
        LabelComponents();
        ComputeCellSize();

        _centroid = new Vector3[triangleCount];
        _materialCount = 1;
        for (int t = 0; t < triangleCount; t++)
        {
            _centroid[t] = Centroid(_mesh.Triangles[t]);
            _materialCount = Math.Max(_materialCount, _mesh.Triangles[t].Material + 1);
        }

        List<int[]> regions = PartitionIntoRegions();
        _regionOf = new int[triangleCount];
        _localIndex = new int[triangleCount];
        for (int r = 0; r < regions.Count; r++)
        {
            int[] members = regions[r];
            for (int l = 0; l < members.Length; l++)
            {
                _regionOf[members[l]] = r;
                _localIndex[members[l]] = l;
            }
        }

        var grown = new List<List<int>>[regions.Count];
        Progress?.BeginStep("leaf clustering, regions grown", regions.Count);
        Parallel.For(0, regions.Count, r =>
        {
            grown[r] = new RegionGrower(this, r, regions[r]).Grow();
            Progress?.Advance();
        });
        Progress?.EndStep();

        Groups = new List<List<int>>();
        var triToGroup = new int[triangleCount];
        Array.Fill(triToGroup, -1);
        foreach (List<List<int>> regionGroups in grown)
        {
            foreach (List<int> group in regionGroups)
            {
                int groupIndex = Groups.Count;
                foreach (int t in group)
                    triToGroup[t] = groupIndex;
                Groups.Add(group);
            }
        }

        MergeOrphanGroups(triToGroup);
    }

    /// <summary>
    /// Splits the mesh into regions of at most RegionClusters clusters' worth of triangles.
    ///
    /// Each split is a plane through the middle of the region's centroid bounds, across its longest
    /// axis: linear time per level with no sorting, which matters at ten million triangles. Splitting
    /// by walking triangles in index order keeps every region's list in ascending index order, which
    /// is the seed order region growing relies on. Regions come out in depth-first order.
    /// </summary>
    private List<int[]> PartitionIntoRegions()
    {
        // In long, clamped: the product overflows an int long before it could matter, and an
        // overflowed negative target would split all the way down to single-triangle regions.
        int target = (int)Math.Min((long)Math.Max(MinClusterTriangles, 1) * RegionClusters, int.MaxValue);
        var all = new int[_mesh.Triangles.Length];
        for (int t = 0; t < all.Length; t++)
            all[t] = t;
        var regions = new List<int[]>();
        SplitRegion(all, target, regions);
        return regions;
    }

    private void SplitRegion(int[] triangles, int target, List<int[]> regions)
    {
        if (triangles.Length <= target)
        {
            regions.Add(triangles);
            return;
        }
        Vector3 min = _centroid[triangles[0]];
        Vector3 max = min;
        foreach (int t in triangles)
        {
            min = min.Min(_centroid[t]);
            max = max.Max(_centroid[t]);
        }
        Vector3 size = max - min;
        int axis = size.X >= size.Y && size.X >= size.Z ? 0 : (size.Y >= size.Z ? 1 : 2);
        float middle = (min[axis] + max[axis]) * 0.5f;

        var below = new List<int>(triangles.Length / 2);
        var above = new List<int>(triangles.Length / 2);
        foreach (int t in triangles)
        {
            if (_centroid[t][axis] < middle)
                below.Add(t);
            else
                above.Add(t);
        }
        // Every centroid on one side means they coincide along the longest axis, so no plane can
        // separate them. Halving by index still terminates and is still deterministic.
        if (below.Count == 0 || above.Count == 0)
        {
            int half = triangles.Length / 2;
            below = new List<int>(triangles[..half]);
            above = new List<int>(triangles[half..]);
        }
        SplitRegion(below.ToArray(), target, regions);
        SplitRegion(above.ToArray(), target, regions);
    }

    /// <summary>
    /// Region growing over one region, in isolation: everything it writes is its own, and a
    /// neighbouring triangle in another region is treated as unavailable before any of that
    /// region's state is looked at.
    ///
    /// Everything is indexed region-locally and allocated once per region, because the candidate
    /// scan is almost the whole cost of leaf clustering — 20.7 s of 21.4 s on the 980k-triangle
    /// terrain before this was restructured, over 61 million candidate evaluations. Each evaluation
    /// is a handful of array reads: the candidate's bounds and material copied into region-local
    /// arrays, its shared-edge count, and whether it is still on the border. None of that changes
    /// which triangle wins — the cost arithmetic is as it was, and the border is walked in
    /// first-added order with departed entries skipped, because the only entries that ever leave are
    /// triangles joining the cluster, and those are never added again.
    /// </summary>
    private sealed class RegionGrower
    {
        private readonly GodotiteClustering _owner;
        private readonly GodotiteMesh _mesh;
        private readonly int _region;
        // Global triangle indices, ascending. Everything else here is indexed by position in this.
        private readonly int[] _triangles;
        private readonly Aabb[] _bounds;
        private readonly int[] _material;
        private readonly bool[] _assigned;
        // How many of each border triangle's edges are already inside the cluster, maintained
        // incrementally so the boundary term costs nothing per candidate.
        private readonly int[] _sharedEdges;
        private readonly bool[] _inBorder;
        // Border in first-added order; departed entries stay until compaction and are skipped.
        private readonly List<int> _border = new();
        private int _borderLive;
        private int _borderDeparted;
        private readonly bool[] _materialPresent;
        private readonly List<int> _materials = new();
        // Bridging grid over this region's unassigned triangles only.
        private readonly Dictionary<Vector3I, OrderedIntSet> _grid = new();
        private readonly Vector3I[] _cell;
        // Cell bounds of this region. No cell outside them can hold one of its triangles, so the
        // bridging search never needs to look beyond them.
        private Vector3I _cellMin;
        private Vector3I _cellMax;

        public RegionGrower(GodotiteClustering owner, int region, int[] triangles)
        {
            _owner = owner;
            _mesh = owner._mesh;
            _region = region;
            _triangles = triangles;
            int count = triangles.Length;
            _bounds = new Aabb[count];
            _material = new int[count];
            _assigned = new bool[count];
            _sharedEdges = new int[count];
            _inBorder = new bool[count];
            _materialPresent = new bool[owner._materialCount];
            _cell = new Vector3I[count];
            _cellMin = new Vector3I(int.MaxValue, int.MaxValue, int.MaxValue);
            _cellMax = new Vector3I(int.MinValue, int.MinValue, int.MinValue);
            for (int l = 0; l < count; l++)
            {
                GodotiteMesh.Triangle tri = _mesh.Triangles[triangles[l]];
                _bounds[l] = owner.TriangleAabb(tri);
                _material[l] = tri.Material;
                Vector3I cell = owner.CellOf(owner._centroid[triangles[l]]);
                _cell[l] = cell;
                _cellMin = _cellMin.Min(cell);
                _cellMax = _cellMax.Max(cell);
                if (!_grid.TryGetValue(cell, out OrderedIntSet? bucket))
                {
                    bucket = new OrderedIntSet();
                    _grid[cell] = bucket;
                }
                bucket.Add(l);
            }
        }

        public List<List<int>> Grow()
        {
            var groups = new List<List<int>>();
            for (int seed = 0; seed < _triangles.Length; seed++)
            {
                if (_assigned[seed])
                    continue;

                var groupTris = new List<int> { _triangles[seed] };
                Claim(seed);
                // Which connected pieces this cluster already holds. A jump is only worth making into
                // a piece it has not reached, which keeps bridging off connected geometry entirely.
                var clusterComponents = new HashSet<int> { _owner.TriangleComponent[_triangles[seed]] };
                Aabb currentAabb = _bounds[seed];

                BeginCluster();
                AddNeighbours(seed);
                AddMaterial(_material[seed]);

                while (groupTris.Count < _owner.MinClusterTriangles)
                {
                    if (_borderLive == 0)
                    {
                        if (!_owner.BridgingActive)
                            break;
                        double reach = _owner.BridgeJumpRadius
                            * Math.Max(currentAabb.Size.Length(), _owner._cellSize * 4.0);
                        int jump = NearestUnassigned(currentAabb.GetCenter(), reach, clusterComponents);
                        if (jump < 0)
                            break;
                        clusterComponents.Add(_owner.TriangleComponent[_triangles[jump]]);
                        // Its edges are shared with nothing in this cluster, so it contributes only
                        // spatial locality — which is the point.
                        AddMaterial(_material[jump]);
                        groupTris.Add(_triangles[jump]);
                        Claim(jump);
                        currentAabb = currentAabb.Merge(_bounds[jump]);
                        AddNeighbours(jump);
                        continue;
                    }

                    int best = -1;
                    double bestCost = double.PositiveInfinity;
                    float currentDiag = currentAabb.Size.Length();
                    // Both penalties are expressed in units of the CURRENT diagonal, constant across
                    // candidates this iteration, so each is a flat handicap rather than something that
                    // grows with the candidate — which is what lets them dominate the sub-triangle
                    // spatial term.
                    double penalty = _owner.MaterialSplitPenalty * currentDiag;
                    double boundaryScale = _owner.BoundaryEdgeWeight * currentDiag;

                    for (int b = 0; b < _border.Count; b++)
                    {
                        int candidate = _border[b];
                        if (!_inBorder[candidate])
                            continue;
                        Aabb newAabb = currentAabb.Merge(_bounds[candidate]);
                        double cost = newAabb.Size.Length() - currentDiag;
                        // Each edge already inside the group stops being boundary; each one that is
                        // not becomes boundary. Capped because a non-manifold edge can list a
                        // neighbour twice.
                        int shared = Math.Min(_sharedEdges[candidate], 3);
                        cost += (3 - 2 * shared) * boundaryScale;
                        if (!_materialPresent[_material[candidate]])
                            cost += penalty;
                        // Strictly less-than, so ties go to the first candidate in border order.
                        // This is why the border has to be walked in insertion order.
                        if (cost < bestCost)
                        {
                            bestCost = cost;
                            best = candidate;
                        }
                    }
                    if (best == -1)
                        break;

                    AddMaterial(_material[best]);
                    groupTris.Add(_triangles[best]);
                    Claim(best);
                    currentAabb = currentAabb.Merge(_bounds[best]);
                    LeaveBorder(best);
                    AddNeighbours(best);
                }

                groups.Add(groupTris);
            }
            return groups;
        }

        /// <summary>Marks a triangle as taken and removes it from the bridging grid.</summary>
        private void Claim(int local)
        {
            _assigned[local] = true;
            if (_grid.TryGetValue(_cell[local], out OrderedIntSet? bucket))
            {
                bucket.Remove(local);
                if (bucket.IsEmpty)
                    _grid.Remove(_cell[local]);
            }
        }

        /// <summary>Clears what the previous cluster left, touching only the entries it used.</summary>
        private void BeginCluster()
        {
            foreach (int l in _border)
            {
                _sharedEdges[l] = 0;
                _inBorder[l] = false;
            }
            _border.Clear();
            _borderLive = 0;
            _borderDeparted = 0;
            foreach (int m in _materials)
                _materialPresent[m] = false;
            _materials.Clear();
        }

        private void AddNeighbours(int local)
        {
            int triangle = _triangles[local];
            for (int k = _mesh.AdjacencyStart[triangle]; k < _mesh.AdjacencyStart[triangle + 1]; k++)
            {
                int neighbour = _mesh.AdjacencyItems[k];
                // Another region's triangle is off limits, and must be recognised as such before
                // anything of that region's is read.
                if (_owner._regionOf[neighbour] != _region)
                    continue;
                int n = _owner._localIndex[neighbour];
                if (_assigned[n])
                    continue;
                if (!_inBorder[n])
                {
                    _inBorder[n] = true;
                    _border.Add(n);
                    _borderLive++;
                }
                _sharedEdges[n]++;
            }
        }

        private void LeaveBorder(int local)
        {
            _inBorder[local] = false;
            _sharedEdges[local] = 0;
            _borderLive--;
            _borderDeparted++;
            // Compaction keeps the relative order of what remains, so it cannot change the walk.
            if (_borderDeparted > _borderLive && _borderDeparted > 16)
            {
                _border.RemoveAll(l => !_inBorder[l]);
                _borderDeparted = 0;
            }
        }

        private void AddMaterial(int material)
        {
            if (_materialPresent[material])
                return;
            _materialPresent[material] = true;
            _materials.Add(material);
        }

        /// <summary>
        /// Nearest unassigned triangle in this region to `point`, searching outward a ring of cells at
        /// a time and stopping once the best distance found beats the nearest possible point in the
        /// next ring — which makes the answer exact rather than approximate. Returns a local index.
        ///
        /// Only the cells ON each ring are visited, clipped to the region's own cell bounds, in the
        /// same x-then-y-then-z order as a full scan would reach them — so ties still break the same
        /// way. Scanning each ring's whole cube and skipping its interior, as this used to, costs on
        /// the order of R^4 lookups for a search reaching R rings. That was affordable when a nearby
        /// free triangle usually ended the search early, and not once regions were introduced: the
        /// nearest free triangle is then often across the region border and off limits, so searches
        /// run to their full reach, and Sponza's leaf clustering doubled from 3.9 s to 8.1 s.
        /// </summary>
        private int NearestUnassigned(Vector3 point, double maxDistance, HashSet<int> excludeComponents)
        {
            if (_grid.Count == 0)
                return -1;
            Vector3I center = _owner.CellOf(point);
            float cellSize = _owner._cellSize;
            int best = -1;
            double bestDistance = double.IsInfinity(maxDistance)
                ? double.PositiveInfinity
                : maxDistance * maxDistance;
            // Past this ring every cell is outside the region's bounds.
            int lastRing = Math.Max(
                Math.Max(Math.Max(center.X - _cellMin.X, _cellMax.X - center.X),
                    Math.Max(center.Y - _cellMin.Y, _cellMax.Y - center.Y)),
                Math.Max(center.Z - _cellMin.Z, _cellMax.Z - center.Z));

            for (int ring = 0; ring < MaxJumpRings && ring <= lastRing; ring++)
            {
                double ringReach = Math.Pow((ring - 1) * (double)cellSize, 2.0);
                if (ring > 1 && ringReach > bestDistance)
                    break;
                int x0 = Math.Max(center.X - ring, _cellMin.X), x1 = Math.Min(center.X + ring, _cellMax.X);
                int y0 = Math.Max(center.Y - ring, _cellMin.Y), y1 = Math.Min(center.Y + ring, _cellMax.Y);
                int z0 = Math.Max(center.Z - ring, _cellMin.Z), z1 = Math.Min(center.Z + ring, _cellMax.Z);
                for (int x = x0; x <= x1; x++)
                {
                    bool xOnRing = Math.Abs(x - center.X) == ring;
                    for (int y = y0; y <= y1; y++)
                    {
                        if (xOnRing || Math.Abs(y - center.Y) == ring)
                        {
                            // A whole row of this ring: every z.
                            for (int z = z0; z <= z1; z++)
                                ScanCell(new Vector3I(x, y, z), point, excludeComponents, ref best, ref bestDistance);
                        }
                        else
                        {
                            // Only the two faces, near then far, which is ascending z.
                            int zNear = center.Z - ring;
                            int zFar = center.Z + ring;
                            if (zNear >= z0 && zNear <= z1)
                                ScanCell(new Vector3I(x, y, zNear), point, excludeComponents, ref best, ref bestDistance);
                            if (ring > 0 && zFar >= z0 && zFar <= z1)
                                ScanCell(new Vector3I(x, y, zFar), point, excludeComponents, ref best, ref bestDistance);
                        }
                    }
                }
            }
            return best;
        }

        private void ScanCell(Vector3I cell, Vector3 point, HashSet<int> excludeComponents,
            ref int best, ref double bestDistance)
        {
            if (!_grid.TryGetValue(cell, out OrderedIntSet? bucket))
                return;
            foreach (int l in bucket.InOrder())
            {
                if (_assigned[l])
                    continue;
                if (excludeComponents.Contains(_owner.TriangleComponent[_triangles[l]]))
                    continue;
                double distance = point.DistanceSquaredTo(_owner._centroid[_triangles[l]]);
                if (distance < bestDistance)
                {
                    bestDistance = distance;
                    best = l;
                }
            }
        }
    }

    /// <summary>
    /// Region growing strands small pockets whose neighbours all went to earlier groups, and each
    /// pocket would otherwise become its own one- or two-triangle cluster, distorting DAG grouping.
    /// Folds anything below the threshold into whichever neighbouring group it shares the most
    /// adjacencies with. Folded groups are emptied in place.
    /// </summary>
    private void MergeOrphanGroups(int[] triToGroup)
    {
        int threshold = Math.Max(1, (int)(MinClusterTriangles * OrphanGroupFraction));
        for (int gi = 0; gi < Groups.Count; gi++)
        {
            List<int> group = Groups[gi];
            if (group.Count == 0 || group.Count >= threshold)
                continue;

            // Counted in first-seen order, because the winner is chosen with a strict greater-than
            // and therefore ties go to whichever neighbouring group was met first.
            var counts = new Dictionary<int, int>();
            var order = new List<int>();
            foreach (int tri in group)
            {
                for (int k = _mesh.AdjacencyStart[tri]; k < _mesh.AdjacencyStart[tri + 1]; k++)
                {
                    int other = triToGroup[_mesh.AdjacencyItems[k]];
                    if (other == gi || other < 0)
                        continue;
                    if (!counts.TryGetValue(other, out int count))
                        order.Add(other);
                    counts[other] = count + 1;
                }
            }

            int bestGroup = -1;
            int bestCount = 0;
            foreach (int other in order)
            {
                if (counts[other] > bestCount)
                {
                    bestCount = counts[other];
                    bestGroup = other;
                }
            }
            if (bestGroup == -1)
                continue; // fully isolated pocket, keep it as its own cluster

            foreach (int tri in group)
            {
                Groups[bestGroup].Add(tri);
                triToGroup[tri] = bestGroup;
            }
            Groups[gi] = new List<int>();
        }
    }
}
