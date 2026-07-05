module shared_selftest;

import sample_args;
import sample_camera;
import sample_png;
import std::io;
import std::io::file;

faultdef SELFTEST_FAILED;

const char[*] REFERENCE_PNG = $embed("testdata/reference.png");

const char[16] REFERENCE_PIXELS = {
    255, 0, 0, 255,   0, 255, 0, 255,
    0, 0, 255, 255,   255, 255, 255, 255,
};

fn int main(String[] args) {
    if (catch err = run()) {
        io::printfn("shared_selftest: FAIL (%s)", err);
        return 1;
    }
    io::printn("shared_selftest: PASS");
    return 0;
}

fn void? run() {
    String out_path = "selftest_out.png";
    sample_png::write_png_rgba8(out_path, REFERENCE_PIXELS[..], 2, 2)!;
    char[] written = file::load(mem, out_path)!;
    defer free(written.ptr);
    if ((String)written != (String)REFERENCE_PNG[..]) {
        io::printn("encoded PNG differs from committed reference");
        return SELFTEST_FAILED~;
    }

    sample_args::Options options = sample_args::parse_options({ "--frames", "3", "--screenshot", "x.png" });
    if (options.frames != 3 || !options.capture_frame(2) || options.capture_frame(1)) {
        io::printn("argument parsing misbehaved");
        return SELFTEST_FAILED~;
    }

    sample_camera::OrbitCamera camera = { .yaw = 0.0f, .pitch = 0.0f, .radius = 5.0f, .target = { 0, 0, 0 } };
    float[<3>] pos = camera.position();
    if (pos[2] < 4.99f || pos[2] > 5.01f) {
        io::printn("orbit camera position off");
        return SELFTEST_FAILED~;
    }
}
