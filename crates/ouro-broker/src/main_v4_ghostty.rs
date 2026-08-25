use ouro_broker::gateway_runtime_contract::{GhosttyBrokerRuntimeArgs, GHOSTTY_BROKER_USAGE};
use ouro_broker::ghostty_engine::GhosttyEngineFactory;
use ouro_broker::{Broker, BrokerConfig};
use ouro_terminal_ghostty::Config as GhosttyConfig;
use std::sync::Arc;

fn main() {
    let runtime =
        GhosttyBrokerRuntimeArgs::parse(std::env::args_os().skip(1)).unwrap_or_else(|error| {
            eprintln!("ouro-broker-v4-ghostty: {error}\n{GHOSTTY_BROKER_USAGE}");
            std::process::exit(64);
        });
    debug_assert!(!runtime.may_advertise_authenticated_session_messaging());
    let GhosttyBrokerRuntimeArgs {
        broker_socket_path,
        // Valid descriptors remain owned for the lifetime of the process, but
        // are deliberately not promoted into authority or advertised yet.
        gateway_fds: _gateway_fds,
    } = runtime;

    let mut config = BrokerConfig::new(broker_socket_path);
    config.max_snapshot_bytes = 16 * 1024 * 1024;
    config.max_live_checkpoint_bytes = 64 * 1024 * 1024;
    config.max_recovery_pinned_bytes = 32 * 1024 * 1024;
    let result = GhosttyEngineFactory::new(
        GhosttyConfig {
            snapshot_max_bytes: config.max_snapshot_bytes,
            scrollback_max_bytes: config.max_terminal_history_bytes,
            ..GhosttyConfig::default()
        },
        config.max_global_history_bytes,
    )
    .and_then(|engine| {
        engine
            .manifest(&config)
            .and_then(|manifest| Broker::bind_v4_engine(config, manifest, Arc::new(engine)))
    })
    .and_then(Broker::run);
    if let Err(error) = result {
        eprintln!("ouro-broker-v4-ghostty: {error}");
        std::process::exit(1);
    }
}
