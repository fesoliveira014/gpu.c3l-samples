module sample_camera;

import std::math;

// Column-major 4x4, matching GLSL mat4 consumption of four vec4 columns.
alias Mat4 = float[16];

struct OrbitCamera {
    float yaw;
    float pitch;
    float radius;
    float[<3>] target;
}

fn float[<3>] OrbitCamera.position(&self) {
    float cp = math::cos(self.pitch);
    return self.target + (float[<3>]){
        cp * math::sin(self.yaw),
        math::sin(self.pitch),
        cp * math::cos(self.yaw),
    } * self.radius;
}

fn Mat4 OrbitCamera.view(&self) {
    return look_at(self.position(), self.target, { 0.0f, 1.0f, 0.0f });
}

fn Mat4 look_at(float[<3>] eye, float[<3>] center, float[<3>] up) {
    float[<3>] f = normalize(center - eye);
    float[<3>] s = normalize(cross(f, up));
    float[<3>] u = cross(s, f);
    return {
        s[0], u[0], -f[0], 0.0f,
        s[1], u[1], -f[1], 0.0f,
        s[2], u[2], -f[2], 0.0f,
        -dot(s, eye), -dot(u, eye), dot(f, eye), 1.0f,
    };
}

<* Vulkan-convention perspective: depth 0..1, Y flipped so world +Y is up. *>
fn Mat4 perspective(float fov_y_radians, float aspect, float near, float far) {
    float focal = 1.0f / math::tan(fov_y_radians * 0.5f);
    return {
        focal / aspect, 0.0f, 0.0f, 0.0f,
        0.0f, -focal, 0.0f, 0.0f,
        0.0f, 0.0f, far / (near - far), -1.0f,
        0.0f, 0.0f, (near * far) / (near - far), 0.0f,
    };
}

fn Mat4 mul(Mat4 a, Mat4 b) {
    Mat4 out;
    for (uint col = 0; col < 4; col++) {
        for (uint row = 0; row < 4; row++) {
            float sum = 0.0f;
            for (uint k = 0; k < 4; k++) sum += a[k * 4 + row] * b[col * 4 + k];
            out[col * 4 + row] = sum;
        }
    }
    return out;
}

fn float[<3>] normalize(float[<3>] v) {
    float len = math::sqrt(dot(v, v));
    return v / len;
}

fn float dot(float[<3>] a, float[<3>] b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

fn float[<3>] cross(float[<3>] a, float[<3>] b) {
    return {
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

<* Symmetric orthographic projection, Vulkan depth 0..1, Y flipped. *>
fn Mat4 ortho(float half_extent, float near, float far) {
    float inv_depth = 1.0f / (near - far);
    return {
        1.0f / half_extent, 0, 0, 0,
        0, -1.0f / half_extent, 0, 0,
        0, 0, inv_depth, 0,
        0, 0, near * inv_depth, 1.0f,
    };
}
