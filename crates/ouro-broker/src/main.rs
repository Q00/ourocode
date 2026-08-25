use ouro_broker::{Broker, BrokerConfig};
use std::path::PathBuf;

fn main() {
    let mut args = std::env::args_os().skip(1);
    let Some(socket_path) = args.next().map(PathBuf::from) else {
        eprintln!("usage: ouro-broker <unix-socket-path>");
        std::process::exit(64);
    };
    if args.next().is_some() {
        eprintln!("usage: ouro-broker <unix-socket-path>");
        std::process::exit(64);
    }
    let config = BrokerConfig::new(socket_path);
    match Broker::bind(config).and_then(Broker::run) {
        Ok(()) => {}
        Err(error) => {
            eprintln!("ouro-broker: {error}");
            std::process::exit(1);
        }
    }
}
