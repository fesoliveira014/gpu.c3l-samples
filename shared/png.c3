module sample_png;

import std::io::file;

const uint CRC_POLYNOMIAL = 0xEDB88320;
const uint ADLER_MODULUS  = 65521;
const usz  STORED_BLOCK_MAX = 65535;

<* Encode RGBA8 pixels (row-major, tightly packed) as an uncompressed PNG
   (stored-deflate zlib stream). Dependency-free; sized for screenshots. *>
fn void? write_png_rgba8(String path, char[] rgba, uint width, uint height) {
    DString png;
    png.init(mem);
    defer png.free();
    png.append("\x89PNG\r\n\x1a\n");

    DString ihdr;
    ihdr.init(mem);
    defer ihdr.free();
    append_u32be(&ihdr, width);
    append_u32be(&ihdr, height);
    ihdr.append_char(8);
    ihdr.append_char(6);
    ihdr.append_char(0);
    ihdr.append_char(0);
    ihdr.append_char(0);
    append_chunk(&png, "IHDR", ihdr.str_view());

    // Each row is prefixed with filter byte 0 (no filtering).
    usz stride = (usz)width * 4;
    DString raw;
    raw.init(mem);
    defer raw.free();
    for (uint y = 0; y < height; y++) {
        raw.append_char(0);
        raw.append((String)rgba[y * stride:stride]);
    }
    String raw_view = raw.str_view();
    usz raw_len = (usz)raw_view.len;

    DString idat;
    idat.init(mem);
    defer idat.free();
    idat.append_char(0x78);
    idat.append_char(0x01);
    usz pos = 0;
    while (pos < raw_len) {
        usz block = raw_len - pos > STORED_BLOCK_MAX ? STORED_BLOCK_MAX : raw_len - pos;
        bool last = pos + block == raw_len;
        idat.append_char(last ? (char)1 : (char)0);
        idat.append_char((char)(block & 0xFF));
        idat.append_char((char)(block >> 8));
        idat.append_char((char)(~block & 0xFF));
        idat.append_char((char)((~block >> 8) & 0xFF));
        idat.append((String)raw_view[pos:block]);
        pos += block;
    }
    append_u32be(&idat, adler32(raw_view));
    append_chunk(&png, "IDAT", idat.str_view());
    append_chunk(&png, "IEND", "");

    file::save(path, png.str_view())!;
}

fn void append_chunk(DString* out, String kind, char[] data) {
    append_u32be(out, (uint)data.len);
    usz start = (usz)out.len();
    out.append(kind);
    out.append((String)data);
    uint crc = crc32(out.str_view()[start..(usz)out.len() - 1]);
    append_u32be(out, crc);
}

fn void append_u32be(DString* out, uint v) {
    out.append_char((char)(v >> 24));
    out.append_char((char)(v >> 16));
    out.append_char((char)(v >> 8));
    out.append_char((char)v);
}

fn uint crc32(char[] data) {
    uint c = 0xFFFFFFFF;
    foreach (b : data) {
        c ^= b;
        for (int k = 0; k < 8; k++) {
            c = (c & 1) != 0 ? CRC_POLYNOMIAL ^ (c >> 1) : c >> 1;
        }
    }
    return c ^ 0xFFFFFFFF;
}

fn uint adler32(char[] data) {
    uint s1 = 1;
    uint s2 = 0;
    foreach (b : data) {
        s1 = (s1 + b) % ADLER_MODULUS;
        s2 = (s2 + s1) % ADLER_MODULUS;
    }
    return (s2 << 16) | s1;
}
