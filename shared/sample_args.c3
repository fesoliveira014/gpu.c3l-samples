module sample_args;

struct Options {
    long   frames;
    bool   vsync;
    String screenshot_path;
}

<* Common sample flags: --frames N (bounded run, -1 = unbounded), --no-vsync,
   --screenshot <path> (capture on the final bounded frame). *>
fn Options parse_options(String[] args) {
    Options options = { .frames = -1, .vsync = true };
    foreach (i, arg : args) {
        if (arg == "--no-vsync") options.vsync = false;
        if (arg == "--frames" && i + 1 < args.len) {
            if (try value = args[i + 1].to_long()) options.frames = value;
        }
        if (arg == "--screenshot" && i + 1 < args.len) {
            options.screenshot_path = args[i + 1];
        }
    }
    return options;
}

fn bool Options.wants_screenshot(&self) => self.screenshot_path.len > 0;

<* True on the frame a --screenshot capture should happen: the final frame of
   a bounded run, or the first frame when the run is unbounded. *>
fn bool Options.capture_frame(&self, long frame) {
    if (!self.wants_screenshot()) return false;
    return self.frames > 0 ? frame == self.frames - 1 : frame == 0;
}
