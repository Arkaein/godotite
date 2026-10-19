shader_type spatial;

// Graybox checker, tinted by material index. Shows three things at once:
//
//   * UV distortion and seam tearing — in UV space the checker warps, smears or explodes exactly
//     where a collapsed seam forced a triangle to bridge the discontinuity. This is the only view
//     that makes `collapse_across_seams` damage directly visible rather than a number in a report.
//   * material boundaries — the tint comes from the material index the builder writes into the
//     debug channel (see cluster_debug.gdshader), per corner, so a cluster that MIXES materials
//     shows the mix rather than an average.
//   * surface structure — a regular checker reads scale and silhouette far better than flat grey.
//
// World space is the default because it always works; UV space needs the source mesh to have had
// UVs, and reads as one flat cell when it did not.

// 0 = world space (always valid), 1 = UV space (the seam-tearing diagnostic).
uniform int checker_space : hint_range(0, 1) = 0;
uniform float world_scale = 0.15;
uniform float uv_scale = 24.0;
uniform vec4 light_color : source_color = vec4(0.82, 0.82, 0.84, 1.0);
uniform vec4 dark_color : source_color = vec4(0.34, 0.34, 0.37, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.55;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.9;
/// Per-face normals, so tessellation reads as facets. Independent of mesh format, unlike a
/// barycentric wireframe, which is why it survives cluster meshes being indexed.
uniform bool flat_shading = false;
// Which custom channel, CUSTOM0–3, holds the debug data. Set by GodotiteLOD from the DAG.
uniform int debug_channel : hint_range(0, 3) = 3;

varying vec3 world_position;
varying vec3 world_normal;
varying vec4 vertex_color;

// Hue ramp without a full HSV conversion. Golden-ratio stepping is applied to the index before this,
// so neighbouring material indices land far apart on the wheel.
vec3 hue_to_rgb(float hue) {
	vec3 k = mod(vec3(5.0, 3.0, 1.0) + hue * 6.0, 6.0);
	return clamp(min(k, 4.0 - k), 0.0, 1.0);
}

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Taken here, in world space. NORMAL in fragment() is VIEW space, so using it to choose a
	// world-space projection axis makes the choice rotate with the camera and the pattern swim
	// across the surface as you look around.
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	vertex_color = debug_channel == 0 ? CUSTOM0 : debug_channel == 1 ? CUSTOM1
			: debug_channel == 2 ? CUSTOM2 : CUSTOM3;
}

float checker_at(vec2 cell) {
	return mod(floor(cell.x) + floor(cell.y), 2.0);
}

void fragment() {
	float checker;
	float density;
	if (checker_space == 1) {
		vec2 cell = UV * uv_scale;
		checker = checker_at(cell);
		density = fwidth(cell.x) + fwidth(cell.y);
	} else {
		// Blended triplanar rather than picking one axis. A hard pick snaps discontinuously wherever
		// the dominant axis flips, which on a displaced surface is everywhere; blending softens the
		// transition bands instead of tearing through them.
		vec3 weight = pow(abs(world_normal), vec3(4.0));
		weight /= (weight.x + weight.y + weight.z);
		vec2 cell_x = world_position.yz * world_scale;
		vec2 cell_y = world_position.xz * world_scale;
		vec2 cell_z = world_position.xy * world_scale;
		checker = checker_at(cell_x) * weight.x
				+ checker_at(cell_y) * weight.y
				+ checker_at(cell_z) * weight.z;
		density = (fwidth(cell_x.x) + fwidth(cell_x.y)) * weight.x
				+ (fwidth(cell_y.x) + fwidth(cell_y.y)) * weight.y
				+ (fwidth(cell_z.x) + fwidth(cell_z.y)) * weight.z;
	}

	vec3 albedo = mix(dark_color.rgb, light_color.rgb, checker);

	// Fade to flat grey once the cells are smaller than a pixel, so distant surfaces do not turn
	// into moire — which would otherwise read as LOD popping that is not really there.
	albedo = mix(albedo, mix(dark_color.rgb, light_color.rgb, 0.5),
			clamp(density - 0.5, 0.0, 1.0));

	// Material index is stored normalised over 16 slots in the red channel.
	float material_index = floor(vertex_color.r * 15.0 + 0.5);
	vec3 tint = hue_to_rgb(fract(material_index * 0.6180339887));
	ALBEDO = mix(albedo, albedo * tint, tint_strength);

	if (flat_shading) {
		vec3 face = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
		NORMAL = dot(face, NORMAL) < 0.0 ? -face : face;
	}

	ROUGHNESS = roughness_value;
	METALLIC = 0.0;
}
