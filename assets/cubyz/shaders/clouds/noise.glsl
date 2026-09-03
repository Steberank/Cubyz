// 3D simplex noise for cloud density. Original Cubyz implementation of the
// standard simplex lattice (not taken from Simple Clouds).

float cloudHash(vec3 p) {
	p = fract(p*vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y)*p.z);
}

vec3 cloudGrad(vec3 cell) {
	float h = cloudHash(cell);
	float h2 = cloudHash(cell + vec3(19.19, 7.07, 13.13));
	float ang = h*6.2831853;
	float z = h2*2.0 - 1.0;
	float r = sqrt(max(1.0 - z*z, 0.0));
	return vec3(cos(ang)*r, sin(ang)*r, z);
}

float cloudSimplex(vec3 p) {
	const float f3 = 1.0/3.0;
	const float g3 = 1.0/6.0;
	vec3 i = floor(p + (p.x + p.y + p.z)*f3);
	vec3 x0 = p - i + (i.x + i.y + i.z)*g3;

	vec3 e = step(x0.yzx, x0.xyz);
	vec3 i1 = min(e, 1.0 - e.zxy);
	vec3 i2 = max(e, 1.0 - e.zxy);

	vec3 x1 = x0 - i1 + g3;
	vec3 x2 = x0 - i2 + 2.0*g3;
	vec3 x3 = x0 - 1.0 + 3.0*g3;

	vec4 w = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
	w *= w;
	w *= w;
	float n = w.x*dot(cloudGrad(i), x0)
		+ w.y*dot(cloudGrad(i + i1), x1)
		+ w.z*dot(cloudGrad(i + i2), x2)
		+ w.w*dot(cloudGrad(i + vec3(1.0)), x3);
	return 32.0*n;
}
