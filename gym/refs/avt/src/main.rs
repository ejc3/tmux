//! avt: feed a byte stream to Alacritty's terminal (alacritty_terminal) and
//! print what it holds, in gvt's format.
//!
//!   avt COLS ROWS STREAM [EVENTS]
//!
//! EVENTS: "OFFSET resize COLS ROWS" or "OFFSET hidden K", as for gvt.

use alacritty_terminal::event::VoidListener;
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi::Processor;

struct Size {
    columns: usize,
    lines: usize,
}

impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.lines
    }
    fn screen_lines(&self) -> usize {
        self.lines
    }
    fn columns(&self) -> usize {
        self.columns
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: avt COLS ROWS STREAM [EVENTS]");
        std::process::exit(2);
    }
    let mut cols: usize = args[1].parse().unwrap();
    let mut rows: usize = args[2].parse().unwrap();
    let data = std::fs::read(&args[3]).unwrap();
    let events = if args.len() > 4 { std::fs::read_to_string(&args[4]).unwrap() } else { String::new() };

    let config = Config { scrolling_history: 1_000_000, ..Config::default() };
    let mut term = Term::new(config, &Size { columns: cols, lines: rows }, VoidListener);
    let mut parser: Processor = Processor::new();

    let mut at = 0usize;
    for line in events.lines() {
        let p: Vec<&str> = line.split_whitespace().collect();
        if p.len() < 2 {
            continue;
        }
        let off = p[0].parse::<usize>().unwrap().min(data.len());
        if off > at {
            parser.advance(&mut term, &data[at..off]);
            at = off;
        }
        match p[1] {
            "resize" => {
                cols = p[2].parse().unwrap();
                rows = p[3].parse().unwrap();
                term.resize(Size { columns: cols, lines: rows });
            }
            "hidden" => {
                let k: usize = p[2].parse().unwrap();
                term.resize(Size { columns: cols, lines: rows + k });
                term.resize(Size { columns: cols, lines: rows });
            }
            _ => {}
        }
    }
    if at < data.len() {
        parser.advance(&mut term, &data[at..]);
    }

    let grid = term.grid();
    let history = grid.history_size() as i32;
    let mut texts = Vec::new();
    let mut wraps = Vec::new();
    for l in -history..(rows as i32) {
        let row = &grid[Line(l)];
        let mut s = String::new();
        for c in 0..cols {
            let cell = &row[Column(c)];
            if cell.flags.intersects(Flags::WIDE_CHAR_SPACER | Flags::LEADING_WIDE_CHAR_SPACER) {
                continue;
            }
            s.push(cell.c);
            if let Some(z) = cell.zerowidth() {
                for ch in z {
                    s.push(*ch);
                }
            }
        }
        texts.push(s.trim_end().to_string());
        wraps.push(row[Column(cols - 1)].flags.contains(Flags::WRAPLINE));
    }
    println!("@@rows");
    for t in &texts {
        println!("{}", t);
    }
    println!("@@joined");
    let mut out = String::new();
    for (i, t) in texts.iter().enumerate() {
        if i > 0 && !wraps[i - 1] {
            out.push('\n');
        }
        out.push_str(t);
    }
    println!("{}", out);
    let cur = grid.cursor.point;
    let alt = term.mode().contains(alacritty_terminal::term::TermMode::ALT_SCREEN);
    println!("@@cursor {} {} 0 {}", cur.column.0, cur.line.0, if alt { 1 } else { 0 });
}
