// herdr-pick — the prefix+w picker (herdr), Rust port of connect-herdr.sh and
// herdr-picker.mjs. Every command, string, size and colour lives in
// herdr-pick.json beside this crate.

mod ansi;
mod app;
mod config;
mod data;
mod fuzzy;
mod links;
mod model;
mod proc;
mod style;
mod ui;

use config::Config;
use model::Model;
use std::process::exit;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (cfg, cfg_path) = match Config::load() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            exit(1);
        }
    };
    match args.first().map(|s| s.as_str()) {
        None => {
            app::install_signals();
            if let Err(e) = data::ensure_herdr(&cfg) {
                eprintln!("{e}");
                exit(1);
            }
            exit(app::run(cfg));
        }
        Some("help") => {
            let st = style::Style::new(&cfg);
            print!("{}", data::help_text(&cfg, &st));
        }
        Some("config-check") => {
            println!("{cfg_path}");
        }
        Some("list") if args.get(1).map(|s| s.as_str()) == Some("--json") => {
            exit(links::print_list_json(&cfg));
        }
        Some("go-id") => {
            if let Err(e) = links::go_id(&cfg, args.get(1).map(|s| s.as_str()).unwrap_or("")) {
                eprintln!("{e}");
                exit(1);
            }
        }
        Some("go-ks") => {
            // kitchen-sink presents a place (`app` = its last view); started
            // when it is not running (prefix+L, last.sh).
            match links::go_ks(&cfg, args.get(1).map(|s| s.as_str()).unwrap_or("app")) {
                Ok(()) => {}
                Err(links::LinkErr::Offline) => links::launch_ks(&cfg),
                Err(links::LinkErr::Unavailable(e)) => {
                    eprintln!("{e}");
                    exit(1);
                }
            }
        }
        Some("list") => {
            ensure(&cfg);
            let st = style::Style::new(&cfg);
            let mode = args.get(1).cloned().unwrap_or_else(|| "all".to_string());
            match data::list_items(&cfg, &st, &mode, "recent") {
                Ok((items, _)) => {
                    for it in items {
                        println!("{}", it.line);
                    }
                }
                Err(e) => {
                    eprintln!("{e}");
                    exit(1);
                }
            }
        }
        Some("state") => {
            ensure(&cfg);
            match data::fetch_state(&cfg) {
                Ok(v) => println!("{v}"),
                Err(e) => {
                    eprintln!("{e}");
                    exit(1);
                }
            }
        }
        Some("preview") => {
            ensure(&cfg);
            let st = style::Style::new(&cfg);
            let model = model_of(&cfg);
            let item = data::item_from_line(args.get(1).map(|s| s.as_str()).unwrap_or(""));
            print!("{}", data::preview_for(&cfg, &st, &model, &item));
        }
        Some("label") => {
            ensure(&cfg);
            let st = style::Style::new(&cfg);
            let model = model_of(&cfg);
            let item = data::item_from_line(args.get(1).map(|s| s.as_str()).unwrap_or(""));
            print!("{}", data::label_for(&cfg, &st, &model, &item));
        }
        Some("kill") => {
            ensure(&cfg);
            let item = data::item_from_line(args.get(1).map(|s| s.as_str()).unwrap_or(""));
            let _ = data::kill_item(&cfg, &item);
        }
        Some("go") => {
            ensure(&cfg);
            let _ = data::act(&cfg, args.get(1).map(|s| s.as_str()).unwrap_or(""));
        }
        Some("browser") => {
            ensure(&cfg);
            let st = style::Style::new(&cfg);
            let _ = data::browser(&cfg, &st);
        }
        Some(_) => {
            eprintln!("{}", cfg.text("usage"));
            exit(2);
        }
    }
}

fn ensure(cfg: &Config) {
    if let Err(e) = data::ensure_herdr(cfg) {
        eprintln!("{e}");
        exit(1);
    }
}

fn model_of(cfg: &Config) -> Model {
    data::fetch_state(cfg)
        .map(|v| Model::build(&v))
        .unwrap_or_default()
}
