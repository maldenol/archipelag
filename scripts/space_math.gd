extends Object

const TAU = PI * 2.0

static func wrap_tau(angle: float) -> float:
	angle = fmod(angle, TAU)
	if angle < 0.0:
		angle += TAU
	return angle

static func finalize_orbit(orbit: Dictionary, star_gm: float) -> void:
	var axis: float = maxf(orbit.semi_major, 1.0)
	orbit.semi_major = axis
	orbit.eccentricity = clampf(orbit.eccentricity, 0.0, 0.85)
	orbit.mean_motion = sqrt(star_gm / (axis * axis * axis))

static func orbit_position(orbit: Dictionary, time: float) -> Vector3:
	var mean = wrap_tau(orbit.mean_anomaly + orbit.mean_motion * time)
	var ecc: float = orbit.eccentricity
	var eccentric = mean if ecc < 0.8 else PI
	for _i in 12:
		var sine = sin(eccentric)
		var cosine = cos(eccentric)
		var residual = eccentric - ecc * sine - mean
		var derivative = 1.0 - ecc * cosine
		eccentric -= residual / derivative
	var cos_e = cos(eccentric)
	var sin_e = sin(eccentric)
	var beta = sqrt(maxf(0.0, 1.0 - ecc * ecc))
	var true_anomaly = atan2(beta * sin_e, cos_e - ecc)
	var radius = orbit.semi_major * (1.0 - ecc * cos_e)
	var angle: float = orbit.argument + true_anomaly
	var cos_a = cos(angle)
	var sin_a = sin(angle)
	var cos_o = cos(orbit.node)
	var sin_o = sin(orbit.node)
	var cos_i = cos(orbit.inclination)
	var sin_i = sin(orbit.inclination)
	return Vector3(
		radius * (cos_o * cos_a - sin_o * sin_a * cos_i),
		radius * (sin_a * sin_i),
		radius * (sin_o * cos_a + cos_o * sin_a * cos_i)
	)

static func orbit_normal(orbit: Dictionary) -> Vector3:
	var sin_i = sin(orbit.inclination)
	var cos_i = cos(orbit.inclination)
	var sin_o = sin(orbit.node)
	var cos_o = cos(orbit.node)
	return Vector3(sin_o * sin_i, cos_i, -cos_o * sin_i).normalized()

static func orbit_rotation(orbit: Dictionary, time: float) -> Basis:
	var normal = orbit_normal(orbit)
	var align = Basis(Quaternion(Vector3.UP, normal))
	var spin = Basis(Vector3.UP, wrap_tau(orbit.spin_rate * time))
	return align * spin

static func acceleration(bodies: Array, position: Vector3) -> Vector3:
	var accel = Vector3.ZERO
	for body in bodies:
		var toward: Vector3 = body.position - position
		var distance = toward.length()
		if distance < 0.01 or body.gm <= 0.0:
			continue
		if distance < body.radius:
			var radius_cubed: float = body.radius * body.radius * body.radius
			accel += toward * (body.gm / radius_cubed)
		else:
			var distance_cubed: float = distance * distance * distance
			accel += toward * (body.gm / distance_cubed)
	return accel

static func integrate(bodies: Array, position: Vector3, velocity: Vector3, thrust: Vector3, dt: float, bounce: float = 0.05) -> Dictionary:
	var accel = acceleration(bodies, position) + thrust
	velocity += accel * dt
	var end = position + velocity * dt
	var closest = 2.0
	var hit_body = null
	for body in bodies:
		var t = -1.0
		if body.get("planet") != null:
			t = body.planet.segment_surface(position, end, body.position, body.basis)
		else:
			t = _segment_sphere(position, end, body.position, body.radius)
		if t >= 0.0 and t < closest:
			closest = t
			hit_body = body
	if hit_body != null:
		var contact: Vector3 = position.lerp(end, closest)
		var normal: Vector3 = (contact - hit_body.position).normalized()
		if hit_body.get("planet") != null:
			normal = hit_body.planet.surface_normal(contact, hit_body.position, hit_body.basis)
		position = contact + normal * 0.05
		var into: float = velocity.dot(normal)
		if into < 0.0:
			velocity -= (1.0 + bounce) * into * normal
		return {
			"position": position,
			"velocity": velocity,
			"hit": true,
			"normal": normal,
			"name": hit_body.name,
		}
	return {
		"position": end,
		"velocity": velocity,
		"hit": false,
		"normal": Vector3.UP,
		"name": "",
	}

static func _segment_sphere(start: Vector3, end: Vector3, center: Vector3, radius: float) -> float:
	var delta = end - start
	var offset = start - center
	var a = delta.length_squared()
	if a < 0.0001:
		return -1.0
	var b = 2.0 * offset.dot(delta)
	var c = offset.length_squared() - radius * radius
	var discriminant = b * b - 4.0 * a * c
	if discriminant < 0.0:
		return -1.0
	var root = sqrt(discriminant)
	var inv = 0.5 / a
	var t0 = (-b - root) * inv
	var t1 = (-b + root) * inv
	if t0 >= 0.0 and t0 <= 1.0:
		return t0
	if t1 >= 0.0 and t1 <= 1.0:
		return t1
	return -1.0

static var _detail: ImageTexture

static func detail_texture() -> ImageTexture:
	if _detail != null:
		return _detail
	var noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.frequency = 0.08
	noise.seed = 19
	var size = 128
	var bytes = PackedByteArray()
	bytes.resize(size * size * 4)
	for y in size:
		for x in size:
			var n = noise.get_noise_2d(float(x), float(y))
			var crack = noise.get_noise_2d(float(x) * 3.0 + 20.0, float(y) * 3.0)
			var shade = clampf(0.72 + n * 0.28 - maxf(0.0, crack) * 0.35, 0.2, 1.0)
			var value = int(shade * 255.0)
			var i = (y * size + x) * 4
			bytes[i] = value
			bytes[i + 1] = value
			bytes[i + 2] = value
			bytes[i + 3] = 255
	var image = Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, bytes)
	image.generate_mipmaps()
	_detail = ImageTexture.create_from_image(image)
	return _detail

static func terrain_layers(seed: int, tint: Color) -> Dictionary:
	var soil_dark = tint.darkened(0.55)
	var soil_light = tint.lightened(0.35)
	var stone_dark = Color(0.22, 0.2, 0.18).lerp(tint.darkened(0.4), 0.35)
	var stone_light = Color(0.72, 0.68, 0.6).lerp(tint.lightened(0.2), 0.25)
	return {
		"macro": _layer_texture(seed + 3, soil_dark, soil_light, 0.007, 0.85),
		"rock": _layer_texture(seed + 19, stone_dark, stone_light, 0.028, 1.0),
		"grit": _layer_texture(seed + 41, Color(0.16, 0.14, 0.12), Color(0.9, 0.86, 0.78), 0.09, 1.0),
	}

static func _layer_texture(seed: int, dark: Color, light: Color, frequency: float, contrast: float) -> ImageTexture:
	var noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 5
	noise.frequency = frequency
	noise.seed = seed * 17 + 5
	var size = 256
	var bytes = PackedByteArray()
	bytes.resize(size * size * 4)
	for y in size:
		for x in size:
			var n = noise.get_noise_2d(float(x), float(y))
			var crack = noise.get_noise_2d(float(x) * 3.1 + 40.0, float(y) * 3.1)
			var blend = clampf(n * 0.5 * contrast + 0.5, 0.0, 1.0)
			var color = dark.lerp(light, blend)
			color = color.lerp(dark.darkened(0.45), clampf(crack, 0.0, 1.0) * 0.55)
			var i = (y * size + x) * 4
			bytes[i] = int(clampf(color.r, 0.0, 1.0) * 255.0)
			bytes[i + 1] = int(clampf(color.g, 0.0, 1.0) * 255.0)
			bytes[i + 2] = int(clampf(color.b, 0.0, 1.0) * 255.0)
			bytes[i + 3] = 255
	var image = Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, bytes)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

static func surface_textures(seed: int, tint: Color) -> Dictionary:
	var noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = 0.035
	noise.seed = 800 + seed * 13
	var size = 256
	var albedo = PackedByteArray()
	var normal = PackedByteArray()
	var rough = PackedByteArray()
	albedo.resize(size * size * 4)
	normal.resize(size * size * 4)
	rough.resize(size * size * 4)
	var dark = tint.darkened(0.45)
	var light = tint.lightened(0.22)
	for y in size:
		for x in size:
			var n = noise.get_noise_2d(float(x), float(y))
			var grit = noise.get_noise_2d(float(x) * 4.0 + 9.0, float(y) * 4.0)
			var blend = clampf(n * 0.5 + 0.5, 0.0, 1.0)
			var color = dark.lerp(light, blend).lerp(tint.darkened(0.6), clampf(grit, 0.0, 1.0) * 0.35)
			var i = (y * size + x) * 4
			albedo[i] = int(color.r * 255.0)
			albedo[i + 1] = int(color.g * 255.0)
			albedo[i + 2] = int(color.b * 255.0)
			albedo[i + 3] = 255
			var h_l = noise.get_noise_2d(float(x - 1), float(y))
			var h_r = noise.get_noise_2d(float(x + 1), float(y))
			var h_d = noise.get_noise_2d(float(x), float(y - 1))
			var h_u = noise.get_noise_2d(float(x), float(y + 1))
			var nx = (h_l - h_r) * 2.2
			var ny = (h_d - h_u) * 2.2
			var nrm = Vector3(nx, ny, 1.0).normalized()
			normal[i] = int((nrm.x * 0.5 + 0.5) * 255.0)
			normal[i + 1] = int((nrm.y * 0.5 + 0.5) * 255.0)
			normal[i + 2] = int((nrm.z * 0.5 + 0.5) * 255.0)
			normal[i + 3] = 255
			var rough_v = int(clampf(0.72 + grit * 0.22, 0.35, 1.0) * 255.0)
			rough[i] = rough_v
			rough[i + 1] = rough_v
			rough[i + 2] = rough_v
			rough[i + 3] = 255
	var albedo_image = Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, albedo)
	var normal_image = Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, normal)
	var rough_image = Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, rough)
	albedo_image.generate_mipmaps()
	normal_image.generate_mipmaps()
	rough_image.generate_mipmaps()
	return {
		"albedo": ImageTexture.create_from_image(albedo_image),
		"normal": ImageTexture.create_from_image(normal_image),
		"rough": ImageTexture.create_from_image(rough_image),
	}

static func biome_textures(seed: int, profile: Dictionary) -> Dictionary:
	var names = ["plains", "desert", "ice", "ocean", "lake", "mountain"]
	var rough = [0.9, 0.83, 0.32, 0.1, 0.16, 0.95]
	var textures = {}
	for i in names.size():
		var layer: String = names[i]
		var colors: Array = profile[layer]
		textures[layer] = _biome_texture(seed, i, colors[0], colors[1], colors[2], rough[i])
	textures["normal"] = _biome_normal(seed)
	return textures

static func _biome_texture(seed: int, kind: int, dark: Color, light: Color, accent: Color, rough_base: float) -> ImageTexture:
	var noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.seed = 9000 + seed * 131 + kind * 17
	var freq = 0.018 + float(kind) * 0.006 + float(seed % 5) * 0.004
	if kind == 1:
		freq = 0.012 + float(seed % 4) * 0.003
	elif kind == 2:
		freq = 0.04 + float(seed % 3) * 0.01
	elif kind == 5:
		freq = 0.03 + float(seed % 4) * 0.008
	noise.frequency = freq
	var fine = FastNoiseLite.new()
	fine.noise_type = FastNoiseLite.TYPE_SIMPLEX
	fine.fractal_type = FastNoiseLite.FRACTAL_FBM
	fine.fractal_octaves = 2
	fine.seed = 12000 + seed * 19 + kind * 53
	fine.frequency = freq * (3.5 + float(seed % 3))
	var size = 256
	var bytes = PackedByteArray()
	bytes.resize(size * size * 4)
	var ang = float(seed) * 0.9 + float(kind) * 1.7
	var cs = cos(ang)
	var sn = sin(ang)
	var stretch = 2.4 + float(seed % 3) * 0.8
	var wave_scale = 0.18 if kind == 3 else 0.32
	for y in size:
		for x in size:
			var u = float(x) * cs - float(y) * sn
			var v = float(x) * sn + float(y) * cs
			if kind == 1:
				u *= 0.35
				v *= stretch
			var n = noise.get_noise_2d(u, v)
			var g = fine.get_noise_2d(u, v)
			var blend = clampf(n * 0.5 + 0.5, 0.0, 1.0)
			var color = dark.lerp(light, blend)
			var rough = rough_base
			if kind == 0:
				color = color.lerp(accent, clampf(g, 0.0, 1.0) * 0.45)
				if g > 0.35:
					color = color.lerp(dark, 0.25)
			elif kind == 1:
				var dune = clampf(sin(u * 0.11 + n * 5.0) * 0.5 + 0.5, 0.0, 1.0)
				color = dark.lerp(light, dune)
				color = color.lerp(accent, clampf(-g, 0.0, 1.0) * 0.35)
				rough = rough_base + (1.0 - dune) * 0.08
			elif kind == 2:
				var crack = clampf(1.0 - absf(g), 0.0, 1.0)
				color = light.lerp(dark, blend * 0.35)
				color = color.lerp(accent, smoothstep(0.62, 0.9, crack))
				rough = rough_base + crack * 0.12
			elif kind == 3 or kind == 4:
				var wave = clampf(sin(u * wave_scale + n * 4.0) * 0.5 + 0.5, 0.0, 1.0)
				color = dark.lerp(light, wave * 0.55 + blend * 0.35)
				color = color.lerp(accent, clampf(g, 0.0, 1.0) * 0.2)
				rough = rough_base + (1.0 - wave) * (0.08 if kind == 3 else 0.05)
			else:
				var ridge = clampf(1.0 - absf(n), 0.0, 1.0)
				color = dark.lerp(light, ridge)
				color = color.lerp(accent, smoothstep(0.15, 0.7, clampf(g, 0.0, 1.0)) * 0.55)
				rough = rough_base - ridge * 0.06
			var i = (y * size + x) * 4
			bytes[i] = int(clampf(color.r, 0.0, 1.0) * 255.0)
			bytes[i + 1] = int(clampf(color.g, 0.0, 1.0) * 255.0)
			bytes[i + 2] = int(clampf(color.b, 0.0, 1.0) * 255.0)
			bytes[i + 3] = int(clampf(rough, 0.04, 1.0) * 255.0)
	var image = Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, bytes)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

static func _biome_normal(seed: int) -> ImageTexture:
	var noise = FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.frequency = 0.045 + float(seed % 4) * 0.012
	noise.seed = 1500 + seed * 29
	var size = 256
	var bytes = PackedByteArray()
	bytes.resize(size * size * 4)
	for y in size:
		for x in size:
			var h_l = noise.get_noise_2d(float(x - 1), float(y))
			var h_r = noise.get_noise_2d(float(x + 1), float(y))
			var h_d = noise.get_noise_2d(float(x), float(y - 1))
			var h_u = noise.get_noise_2d(float(x), float(y + 1))
			var nrm = Vector3((h_l - h_r) * 2.4, (h_d - h_u) * 2.4, 1.0).normalized()
			var i = (y * size + x) * 4
			bytes[i] = int((nrm.x * 0.5 + 0.5) * 255.0)
			bytes[i + 1] = int((nrm.y * 0.5 + 0.5) * 255.0)
			bytes[i + 2] = int(clampf(nrm.z * 0.5 + 0.5, 0.0, 1.0) * 255.0)
			bytes[i + 3] = 255
	var image = Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, bytes)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

static func make_material(color: Color, emission: float = 0.0) -> StandardMaterial3D:
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	if emission > 0.0:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = emission
	else:
		material.albedo_texture = detail_texture()
		material.uv1_scale = Vector3(3.2, 3.2, 3.2)
	return material

static func basis_from_up_forward(up: Vector3, forward: Vector3) -> Basis:
	var flat = forward.slide(up).normalized()
	if flat.length_squared() < 0.0001:
		flat = up.cross(Vector3.FORWARD).normalized()
		if flat.length_squared() < 0.0001:
			flat = Vector3.RIGHT
	var right = flat.cross(up).normalized()
	flat = up.cross(right).normalized()
	return Basis(right, up, -flat).orthonormalized()
