shader_type spatial;

// Vertex custom data stores biome weights, not colors. Each sampler is one terrain
// layer. Alpha of those textures is roughness.

uniform sampler2D plains_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D desert_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ice_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D ocean_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D lake_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D mountain_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_normal : filter_linear_mipmap, repeat_enable;
uniform float uv_scale = 0.08;
uniform float normal_strength = 0.75;

varying vec4 biome_a;
varying vec2 biome_b;
varying vec3 local_pos;
varying vec3 obj_normal;

vec3 blend_weights(vec3 normal) {
	vec3 blend = pow(abs(normal), vec3(4.0));
	return blend / max(blend.x + blend.y + blend.z, 0.0001);
}

vec4 sample_triplanar(sampler2D tex, vec3 pos, vec3 weights) {
	vec4 x = texture(tex, pos.yz);
	vec4 y = texture(tex, pos.xz);
	vec4 z = texture(tex, pos.xy);
	return x * weights.x + y * weights.y + z * weights.z;
}

vec3 sample_normal(vec3 pos, vec3 weights) {
	vec3 x = texture(detail_normal, pos.yz).xyz * 2.0 - 1.0;
	vec3 y = texture(detail_normal, pos.xz).xyz * 2.0 - 1.0;
	vec3 z = texture(detail_normal, pos.xy).xyz * 2.0 - 1.0;
	x = vec3(x.z, x.x, x.y);
	y = vec3(y.x, y.z, y.y);
	z = vec3(z.xy, z.z);
	return normalize(x * weights.x + y * weights.y + z * weights.z);
}

void vertex() {
	// plains, desert, ice, ocean, then lake and mountain.
	biome_a = CUSTOM0;
	biome_b = CUSTOM1.xy;
	local_pos = VERTEX;
	obj_normal = NORMAL;
}

void fragment() {
	vec3 geom = normalize(obj_normal);
	vec3 weights = blend_weights(geom);
	vec3 pos = local_pos * uv_scale;
	float sum = max(biome_a.r + biome_a.g + biome_a.b + biome_a.a + biome_b.x + biome_b.y, 0.0001);
	float plains = biome_a.r / sum;
	float desert = biome_a.g / sum;
	float ice = biome_a.b / sum;
	float ocean = biome_a.a / sum;
	float lake = biome_b.x / sum;
	float mountain = biome_b.y / sum;
	vec4 color = sample_triplanar(plains_tex, pos, weights) * plains;
	color += sample_triplanar(desert_tex, pos * 0.85, weights) * desert;
	color += sample_triplanar(ice_tex, pos * 1.4, weights) * ice;
	color += sample_triplanar(ocean_tex, pos * 0.55, weights) * ocean;
	color += sample_triplanar(lake_tex, pos * 1.7, weights) * lake;
	color += sample_triplanar(mountain_tex, pos * 1.25, weights) * mountain;
	float slope = 1.0 - clamp(dot(geom, normalize(local_pos)), 0.0, 1.0);
	color.rgb = mix(color.rgb, color.rgb * vec3(0.62, 0.6, 0.58), smoothstep(0.12, 0.4, slope) * mountain);
	ALBEDO = color.rgb;
	float water = clamp(ocean + lake, 0.0, 1.0);
	ROUGHNESS = clamp(color.a, 0.045, 1.0);
	SPECULAR = mix(0.4, 0.82, water);
	float bump = normal_strength * (plains * 0.45 + desert * 0.65 + ice * 0.25 + ocean * 0.05 + lake * 0.1 + mountain * 1.0);
	vec3 mapped = sample_normal(pos * 1.3, weights);
	vec3 obj_n = normalize(mix(geom, mapped, clamp(bump, 0.0, 1.0)));
	vec3 world_n = normalize(mat3(MODEL_MATRIX) * obj_n);
	NORMAL = normalize(mat3(VIEW_MATRIX) * world_n);
}
