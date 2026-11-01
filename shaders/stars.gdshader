shader_type sky;

uniform samplerCube skybox : source_color, filter_linear, hint_default_black;

void sky() {
	COLOR = texture(skybox, EYEDIR).rgb;
}
