shader_type spatial;

// Cluster visualisation: normally lit surface tinted per cluster, flat-shaded to show facets.
//
// The tint comes from a VERTEX CHANNEL, not from an `instance uniform`. Instance shader variables
// are allocated out of one fixed-size buffer — 65536 bytes by default, roughly 4096 instances — so
// tinting a large DAG either failed outright or forced cluster size up to suit the debug view
// rather than the geometry, which is the wrong thing to be tuning against. A vertex channel has no
// such budget and costs nothing per frame.
//
// The channel is the highest custom one the source leaves free, recorded in the DAG as
// `debug_channel` and pushed here by GodotiteLOD. It used to be vertex colour, which overwrote the
// source's own colours. The builder bakes four values per corner, all of them known at build time:
//
//   R  material tag (material index / 15)
//   G  cluster hue, golden-angle stepped so neighbours land far apart on the wheel
//   B  level / 255
//   A  the cluster's error as a fraction of its own diameter
//
// So switching view costs a uniform assignment rather than a rebuild.
//
// Structure is shown by FLAT SHADING rather than a wireframe. The barycentric wireframe this used to
// draw derived corners from VERTEX_ID % 3, which only means anything on non-indexed geometry —
// cluster meshes have been indexed since Phase 13, so it would draw noise. Flat shading needs no
// particular mesh format: the face normal comes from screen-space derivatives of position.

// Matches GodotiteLOD.ColorMode exactly: 0 NONE, 1 CLUSTER, 2 LEVEL, 3 ERROR. The values are pushed
// straight from that enum, so the two must not drift.
uniform int color_mode : hint_range(0, 3) = 1;
// Which custom channel, CUSTOM0–3, holds the debug data. Set by GodotiteLOD from the DAG.
uniform int debug_channel : hint_range(0, 3) = 3;
// Highest level in the DAG, so LEVEL mode can span the full hue range whatever the depth.
uniform float max_level = 1.0;
// Largest error-over-diameter in the DAG, for the same reason. The baked fraction is bounded by the
// clamp at twice the radius, but real clusters sit far below it — measured on terrain the whole DAG
// spanned 0.000 to 0.200, so without rescaling the error view uses a fifth of the hue range and
// everything reads as uniformly accurate.
uniform float max_error_fraction = 1.0;
uniform float saturation : hint_range(0.0, 1.0) = 0.45;
uniform float value : hint_range(0.0, 1.0) = 1.0;

uniform float tint_strength : hint_range(0.0, 1.0) = 0.85;
uniform vec4 base_color : source_color = vec4(0.8, 0.8, 0.85, 1.0);
// Flat per-face normals instead of interpolated ones, so every triangle reads as a facet and the
// tessellation is visible without any wireframe.
uniform bool flat_shading = true;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.85;

varying vec4 cluster_data;

vec3 hsv_to_rgb(float h, float s, float v) {
	vec3 k = mod(vec3(5.0, 3.0, 1.0) + h * 6.0, 6.0);
	return v - v * s * max(vec3(0.0), min(min(k, 4.0 - k), vec3(1.0)));
}

// ALBEDO is linear, and an HSV wheel is sRGB. Without this the tint is written as though sRGB values
// were already linear, which displays about a gamma too bright and washes every hue out — the reason
// the level and error views lost their contrast when the tint moved off the instance uniform, since
// a `source_color` uniform had Godot doing this conversion on upload.
vec3 srgb_to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) / 1.055, vec3(2.4)), c / 12.92,
			lessThan(c, vec3(0.04045)));
}

void vertex() {
	// Per corner and constant across a cluster, so interpolation changes nothing.
	cluster_data = debug_channel == 0 ? CUSTOM0 : debug_channel == 1 ? CUSTOM1
			: debug_channel == 2 ? CUSTOM2 : CUSTOM3;
}

void fragment() {
	if (color_mode == 0) {
		// NONE: leave the material's own colour alone.
		ALBEDO = base_color.rgb;
	} else {
		vec3 tint;
		if (color_mode == 2) {
			// Stop short of a full turn so the coarsest level does not wrap onto level 0's hue.
			float level = cluster_data.b * 255.0;
			tint = hsv_to_rgb(0.75 * clamp(level / max(max_level, 1.0), 0.0, 1.0),
					saturation, value);
		} else if (color_mode == 3) {
			// Blue where the cluster is faithful for its size, red where it is not.
			float error = clamp(cluster_data.a / max(max_error_fraction, 0.0001), 0.0, 1.0);
			tint = hsv_to_rgb((1.0 - error) * 0.66, saturation, value);
		} else {
			tint = hsv_to_rgb(cluster_data.g, saturation, value);
		}
		ALBEDO = mix(base_color.rgb, srgb_to_linear(tint), tint_strength);
	}

	if (flat_shading) {
		// VERTEX is view-space position in fragment(), so its screen-space derivatives span the
		// triangle's plane and their cross product is the face normal. Oriented against the
		// interpolated normal rather than assuming a winding, so it is correct either way.
		vec3 face = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
		NORMAL = dot(face, NORMAL) < 0.0 ? -face : face;
	}

	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
}
