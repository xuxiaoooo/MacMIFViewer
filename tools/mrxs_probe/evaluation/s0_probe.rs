use openslide_pure_rs::OpenSlide;

fn main() {
    let path = std::env::args_os().nth(1).expect("slide required");
    let slide = OpenSlide::open(path).expect("open");
    let (w, h) = slide.level_dimensions(0).expect("level zero");
    println!("dimensions={w}x{h} levels={} channels={}", slide.level_count(), slide.channel_count());
    for c in 0..slide.channel_count() {
        let roi = slide.read_region(c, (w / 2) as i64, (h / 2) as i64, 0, 128, 128).expect("read");
        let pixels = &roi.data;
        let hash = pixels.iter().fold(0xcbf29ce484222325u64, |hash, &value| {
            (hash ^ u64::from(value)).wrapping_mul(0x100000001b3)
        });
        println!("channel={c} count={} min={:?} max={:?} nonzero={} fnv1a={hash:016x}",
            pixels.len(), pixels.iter().min(), pixels.iter().max(),
            pixels.iter().filter(|&&value| value != 0).count());
    }
}
