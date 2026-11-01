shader_type spatial;

uniform float planet_radius = 1000.0;
uniform float planet_amp = 30.0;
uniform vec3 soil_hi = vec3(0.85, 0.35, 0.08);
uniform vec3 soil_lo = vec3(0.28, 0.06, 0.02);
uniform vec3 rock_hi = vec3(0.78, 0.78, 0.8);
uniform vec3 rock_lo = vec3(0.22, 0.22, 0.24);

varying vec3 obj_pos;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float value_noise(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(cell);
	float n100 = hash13(cell + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(cell + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(cell + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(cell + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(cell + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(cell + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(cell + vec3(1.0, 1.0, 1.0));
	float nx00 = mix(n000, n100, f.x);
	float nx10 = mix(n010, n110, f.x);
	float nx01 = mix(n001, n101, f.x);
	float nx11 = mix(n011, n111, f.x);
	return mix(mix(nx00, nx10, f.y), mix(nx01, nx11, f.y), f.z);
}

void vertex() {
	obj_pos = VERTEX;
	// Radial shade normal, so the date-line vertices cannot crease.
	NORMAL = normalize(VERTEX);
}

void fragment() {
	vec3 radial = normalize(obj_pos);
	float height = clamp((length(obj_pos) - planet_radius) / max(planet_amp, 0.001) * 0.5 + 0.5, 0.0, 1.0);
	// Large patches, then a different pattern on each material. No triplanar seam.
	float region = value_noise(radial * 5.5);
	float soil_pat = value_noise(obj_pos * 0.045);
	float dirt_pat = value_noise(obj_pos * 0.16);
	float rock_pat = value_noise(obj_pos * 0.07);
	float cracks = smoothstep(0.55, 0.75, value_noise(obj_pos * 0.22));
	float rock_w = smoothstep(0.62, 0.84, height);
	float dirt_w = smoothstep(0.38, 0.55, region) * (1.0 - rock_w);
	vec3 soil = mix(soil_lo, soil_hi, soil_pat);
	vec3 dirt = mix(rock_lo, rock_hi, dirt_pat);
	vec3 stone = mix(vec3(0.22, 0.22, 0.24), vec3(0.74, 0.75, 0.77), rock_pat);
	stone = mix(stone, vec3(0.12, 0.12, 0.13), cracks);
	vec3 albedo = mix(soil, dirt, dirt_w);
	albedo = mix(albedo, stone, rock_w);
	ALBEDO = albedo;
	ROUGHNESS = mix(0.94, 0.42, rock_w);
}
