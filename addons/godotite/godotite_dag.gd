@tool
@icon("res://addons/godotite/icons/godotite_dag.svg")
class_name GodotiteDAG
extends Resource

## A built Godotite LOD hierarchy: every cluster's mesh, and what choosing among them needs.
##
## Made by a [GodotiteBuilder] or the importer and drawn by a [GodotiteLOD]. Saved as its own
## [code].res[/code] file, so the scene holding the GodotiteLOD stays small. [br][br]
##
## The hierarchy is a DAG (directed acyclic graph) of clusters. The leaves, level 0, are the source
## mesh at full detail, cut into pieces. Each level above merges groups of neighbouring clusters,
## simplifies them to about half the triangles, and splits them again, up to a single root. Each
## cluster records its simplification error and a bound, from which a GodotiteLOD works out how
## wrong it would look from the camera. [br][br]
##
## The arrays are index-aligned, one entry per cluster. Clusters are ordered leaves first
## (ascending level), so a parent always has a higher index than its children;
## [method children_of] gives a cluster's children. Most games never read them: they are here for
## tools and for debugging.

# Flat and index-addressed rather than a graph of objects. Godot serialises arrays of primitives
# cleanly; a web of cross-linked RefCounted instances does not round-trip through a scene save at
# all, which is why the DAG used to vanish on every scene reload.
#
# Children use a CSR layout: child_offsets[i] and child_counts[i] index a run inside child_indices.
# Clusters are ordered leaves first (ascending level), so a parent always has a higher index than
# its children.
#
# Geometry IS stored here, in `meshes`, and this resource is saved to its own external `.res`.
#
# It used to live on the MeshInstance3D nodes instead, to keep clusters visible and selectable in
# the Scene dock. That cost 95.5% of the saved scene — 4.28 MB of embedded ArrayMesh text against
# 136 KB for the 497 nodes themselves. Since the nodes are nearly free and the meshes are not, the
# meshes moved out and the nodes stayed: GodotiteLOD reassigns `node.mesh` from here on load and
# strips it again before each save, so the Scene dock is unchanged and the scene stays small.

## The format the builder writes DAGs in. Raised whenever the stored data changes meaning.
const FORMAT_VERSION := 1
## The oldest format this version of Godotite can draw. Raised only when a change leaves older DAGs
## unusable; until then they are drawn as they are.
const OLDEST_FORMAT_VERSION := 0

## The format this DAG was built in: [constant FORMAT_VERSION] at the time it was built, or 0 for
## a DAG built before formats were numbered.
@export var format_version: int = 0

## How many clusters the hierarchy holds.
@export var cluster_count: int = 0
## The index of the root, the coarsest cluster.
@export var root_index: int = -1

# One ArrayMesh per cluster, index-aligned with every other array here. The authoritative copy —
# a cluster node's `mesh` is a display handle refreshed from this, never the other way round.
## One ArrayMesh per cluster.
@export var meshes: Array[ArrayMesh] = []

## Each cluster's level: 0 for the leaves (the source's full detail), counting up towards the root.
@export var levels := PackedInt32Array()

# Triangles per cluster. Stored so runtime stats never have to call Mesh.get_faces(), which
# allocates the entire face array just to count it.
## Triangles per cluster.
@export var triangle_counts := PackedInt32Array()

# Error and bounding sphere of the simplification that PRODUCED each cluster. Every cluster that
# came out of the same group carries identical values here — that sharing is what makes a group
# reach one LOD decision without its members having to communicate.
## Each cluster's simplification error, in the mesh's units: how far it may sit from full detail.
## The clusters made from one group share their error and bounds, so they always switch together.
@export var errors := PackedFloat32Array()
## Centre of the bounding sphere that goes with each cluster's error (see errors).
@export var lod_centers := PackedVector3Array()
## Radius of the bounding sphere that goes with each cluster's error (see errors).
@export var lod_radii := PackedFloat32Array()

# Inner radius of each cluster's SHELL bound. The geometry lies between this and `lod_radii` of
# `lod_centers`, so a viewer inside a hollow surface — a planet from its centre, a cave, a room —
# gets a real distance instead of the zero every ball-shaped bound reports. 0 means the bound
# degenerates to a plain ball, which is correct for any patch that wraps around nothing.
#
# Empty on DAGs built before this existed; the runtime treats that as all-zero.
## Inner radius of each cluster's bound: its geometry lies between this and lod_radii, so a
## camera inside a hollow mesh (a room, a cave, a hollow planet) gets its true distance. 0 for a
## plain sphere; empty means all 0.
@export var lod_inner_radii := PackedFloat32Array()

# The coarser alternative that would replace each cluster, i.e. the group it was later folded into.
# The root has no parent and stores INF, so it always counts as "parent too coarse".
## The error of the coarser clusters that replace each cluster; INF for the root, which has none.
@export var parent_errors := PackedFloat32Array()
## Centre of the parent's bound, as lod_centers is for the cluster.
@export var parent_centers := PackedVector3Array()
## Radius of the parent's bound, as lod_radii is for the cluster.
@export var parent_radii := PackedFloat32Array()
## Inner radius of the parent's shell bound, as lod_inner_radii is for the cluster.
@export var parent_inner_radii := PackedFloat32Array()

# The custom channel, 0–3, the cluster meshes carry their debug data in (material tag, cluster hue,
# level, error), or -1 for none: the source used all four, or export stripped it. The debug shaders
# read it from here through GodotiteLOD. It used to be vertex colour, so a DAG built before has -1
# and needs a rebuild for its debug views.
## The custom channel, 0–3, the cluster meshes carry their debug data in (material tag, cluster
## hue, level, error), or -1 for none: the source used all four, or the export stripped it. The
## debug views need it.
@export var debug_channel: int = -1

# Source material index for each mesh surface of each cluster, CSR-packed the same way as children.
# A cluster carries one surface per material it contains, so this is what binds the right material
# to the right surface at runtime.
## Where each cluster's surfaces start in surface_materials. A cluster has one surface per
## material it contains.
@export var surface_material_offsets := PackedInt32Array()
## How many surfaces (materials) each cluster has: its draw calls.
@export var surface_material_counts := PackedInt32Array()
## The source material index of every cluster surface, in runs given by surface_material_offsets
## and surface_material_counts.
@export var surface_materials := PackedInt32Array()

## Where each cluster's children start in child_indices (a CSR layout; see [method children_of]).
@export var child_offsets := PackedInt32Array()
## How many children each cluster has: 0 for a leaf.
@export var child_counts := PackedInt32Array()
## Every cluster's children, in runs given by child_offsets and child_counts.
@export var child_indices := PackedInt32Array()


## Whether this holds a usable hierarchy: a format this version can draw, clusters, a root, and
## arrays of matching sizes.
func is_valid() -> bool:
	return (format_problem().is_empty()
			and cluster_count > 0
			and root_index >= 0
			and root_index < cluster_count
			and levels.size() == cluster_count
			and errors.size() == cluster_count
			and child_offsets.size() == cluster_count)


## Fills this DAG from the builder's packed arrays and meshes, in the current format. Used by
## GodotiteBuilder.
func fill(data: Dictionary) -> void:
	# Done here, by this script's own assignments, because setting a resource's properties from
	# another script goes through Object.set(), which in the editor marks it edited; the editor then
	# saves every edited resource again, compressed, whenever a scene is saved: a whole DAG rewritten
	# each time, and written back to an old path if the file had been moved. Field by field rather
	# than by reflection, so a rename breaks the build here rather than leaving an array empty.
	format_version = FORMAT_VERSION
	cluster_count = data["cluster_count"]
	root_index = data["root_index"]
	levels = data["levels"]
	triangle_counts = data["triangle_counts"]
	errors = data["errors"]
	lod_centers = data["lod_centers"]
	lod_radii = data["lod_radii"]
	lod_inner_radii = data["lod_inner_radii"]
	parent_errors = data["parent_errors"]
	parent_centers = data["parent_centers"]
	parent_radii = data["parent_radii"]
	parent_inner_radii = data["parent_inner_radii"]
	child_offsets = data["child_offsets"]
	child_counts = data["child_counts"]
	child_indices = data["child_indices"]
	surface_material_offsets = data["surface_material_offsets"]
	surface_material_counts = data["surface_material_counts"]
	surface_materials = data["surface_materials"]
	debug_channel = data.get("debug_channel", -1)
	var source_meshes: Array = data["meshes"]
	meshes.resize(source_meshes.size())
	for i in range(source_meshes.size()):
		meshes[i] = source_meshes[i]


## Why this version of Godotite cannot draw this DAG's format, or "" if it can.
func format_problem() -> String:
	if format_version > FORMAT_VERSION:
		return ("Built by a newer version of Godotite (DAG format %d; this version reads up to %d). "
				+ "Update Godotite, or rebuild it with this version.") % [ format_version, FORMAT_VERSION ]
	if format_version < OLDEST_FORMAT_VERSION:
		return ("Built by an older version of Godotite (DAG format %d; this version reads %d and "
				+ "later). Rebuild it: press Regenerate on its GodotiteBuilder, or reimport its "
				+ "scene.") % [ format_version, OLDEST_FORMAT_VERSION ]
	return ""


## Whether a cluster is a leaf: full detail, with no children.
func is_leaf(index: int) -> bool:
	return child_counts[index] == 0


## A cluster's children, the finer clusters it replaces.
func children_of(index: int) -> PackedInt32Array:
	var from: int = child_offsets[index]
	return child_indices.slice(from, from + child_counts[index])


# A cluster's surface materials, as source material indices; empty for a DAG built before they
# were recorded.
## A cluster's surface materials, as source material indices.
func surface_materials_of(index: int) -> PackedInt32Array:
	if surface_material_offsets.size() != cluster_count:
		return PackedInt32Array()
	var from: int = surface_material_offsets[index]
	return surface_materials.slice(from, from + surface_material_counts[index])
