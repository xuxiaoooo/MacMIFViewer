// Copy into the pinned openslide-pure-rs checkout under examples/.
use openslide_pure_rs::OpenSlide;
use std::io::{self, BufRead, Write};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let slide = OpenSlide::open(std::env::args_os().nth(1).ok_or("slide required")?)?;
    let mut output = io::stdout().lock();
    for line in io::stdin().lock().lines() {
        let values = line?
            .split_whitespace()
            .map(str::parse::<i64>)
            .collect::<Result<Vec<_>, _>>()?;
        let [x, y, w, h] = values.as_slice() else {
            return Err("expected x y w h".into());
        };
        if *x < 0 || *y < 0 || !(1..=512).contains(w) || !(1..=512).contains(h) {
            return Err("invalid ROI".into());
        }
        for channel in 0..slide.channel_count() {
            let plane = slide.read_region(channel, *x, *y, 0, *w as u32, *h as u32)?;
            output.write_all(&plane.data)?;
        }
    }
    Ok(())
}
