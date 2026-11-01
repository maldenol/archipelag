shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled, fog_disabled;

uniform vec3 day_color : source_color = vec3(0.95, 0.72, 0.48);
uniform vec3 night_color : source_color = vec3(0.16, 0.14, 0.32);
uniform vec3 sun_dir = vec3(1.0, 0.0, 0.0);
uniform float planet_radius = 900.0;
uniform float shell_radius = 1000.0;

varying vec3 world_pos;
varying vec3 center;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	center = MODEL_MATRIX[3].xyz;
}

void fragment() {
	vec3 outward = normalize(world_pos - center);
	vec3 to_sun = normalize(sun_dir);
	float dist = length(CAMERA_POSITION_WORLD - center);
	float thickness = max(shell_radius - planet_radius, 1.0);
	float depth = 1.0 - smoothstep(planet_radius, shell_radius + thickness * 0.35, dist);
	float inside = smoothstep(0.12, 0.82, depth);
	float lit = smoothstep(-0.4, 0.7, dot(outward, to_sun));
	vec3 view = normalize(world_pos - CAMERA_POSITION_WORLD);
	float toward_sun = pow(clamp(dot(view, to_sun), 0.0, 1.0), 2.2);
	vec3 sky = mix(night_color, day_color, lit);
	sky = mix(sky, day_color * 1.25, toward_sun * lit);
	sky *= mix(0.4, 1.05, lit);
	vec3 outer = mix(night_color, day_color, lit) * mix(0.28, 0.55, lit);
	float mu = abs(dot(outward, normalize(CAMERA_POSITION_WORLD - world_pos)));
	float limb = pow(1.0 - mu, 1.55);
	// The silhouette itself is transparent, so the halo eases out instead of ending on the shell.
	float edge = smoothstep(0.0, 0.34, mu);
	float outside_alpha = limb * edge * 0.22;
	float inside_alpha = mix(0.16, 0.72, limb);
	ALBEDO = mix(outer, sky, inside);
	ALPHA = clamp(mix(outside_alpha, inside_alpha, inside), 0.0, 0.86);
}
