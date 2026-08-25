//! Fail-closed process-boundary contract for future authenticated messaging.
//!
//! This module only validates and takes stable, close-on-exec copies of two
//! inherited private transports. It deliberately does not construct an
//! installation authority, authenticate an Ouroboros service, start a
//! session-message gateway, or advertise a messaging capability.

use std::ffi::OsString;
use std::io;
use std::mem::{size_of, zeroed};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::PathBuf;

pub const SESSION_MESSAGE_UPSTREAM_FD_FLAG: &str = "--session-message-upstream-fd";
pub const PRINCIPAL_REGISTRATION_FD_FLAG: &str = "--principal-registration-fd";
pub const GHOSTTY_BROKER_USAGE: &str = concat!(
    "usage: ouro-broker-v4-ghostty <broker-v4-ghostty.sock> ",
    "[--session-message-upstream-fd <fd> ",
    "--principal-registration-fd <fd>]"
);

/// Parsed production arguments. `gateway_fds == None` is the normal terminal-
/// only launch and must remain supported.
pub struct GhosttyBrokerRuntimeArgs {
    pub broker_socket_path: PathBuf,
    pub gateway_fds: Option<InheritedGatewayFds>,
}

/// An inherited transport is only a launch boundary. It is not evidence of
/// an installation authority, a reciprocal Ouroboros peer, or a durable ACK.
/// Keeping this state explicit prevents a future caller from treating
/// `gateway_fds.is_some()` as permission to advertise session mutation.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionMessageRuntimeReadiness {
    TerminalOnly,
    PrivateTransportsValidatedButUnauthenticated,
}

impl GhosttyBrokerRuntimeArgs {
    pub fn session_message_readiness(&self) -> SessionMessageRuntimeReadiness {
        if self.gateway_fds.is_some() {
            SessionMessageRuntimeReadiness::PrivateTransportsValidatedButUnauthenticated
        } else {
            SessionMessageRuntimeReadiness::TerminalOnly
        }
    }

    pub fn may_advertise_authenticated_session_messaging(&self) -> bool {
        // No production installer/service capability is constructible in this
        // binary yet. This method is deliberately total and fail-closed so a
        // hello capability cannot be inferred from descriptors alone.
        false
    }
}

/// Stable broker-owned copies of the two distinct private socket endpoints.
///
/// Keeping this type authority-free is intentional. Possession of either FD
/// cannot be promoted into a verified installation or service principal.
pub struct InheritedGatewayFds {
    session_message_upstream: OwnedFd,
    principal_registration: OwnedFd,
}

impl InheritedGatewayFds {
    pub fn session_message_upstream(&self) -> &OwnedFd {
        &self.session_message_upstream
    }

    pub fn principal_registration(&self) -> &OwnedFd {
        &self.principal_registration
    }

    pub fn into_parts(self) -> (OwnedFd, OwnedFd) {
        (self.session_message_upstream, self.principal_registration)
    }
}

impl GhosttyBrokerRuntimeArgs {
    pub fn parse<I, T>(args: I) -> io::Result<Self>
    where
        I: IntoIterator<Item = T>,
        T: Into<OsString>,
    {
        let mut args = args.into_iter().map(Into::into);
        let broker_socket_path = args
            .next()
            .map(PathBuf::from)
            .ok_or_else(|| invalid("missing terminal broker socket path"))?;

        let mut upstream = None;
        let mut registration = None;
        while let Some(flag) = args.next() {
            if flag == SESSION_MESSAGE_UPSTREAM_FD_FLAG {
                parse_flag_value(&mut args, &mut upstream, SESSION_MESSAGE_UPSTREAM_FD_FLAG)?;
            } else if flag == PRINCIPAL_REGISTRATION_FD_FLAG {
                parse_flag_value(&mut args, &mut registration, PRINCIPAL_REGISTRATION_FD_FLAG)?;
            } else {
                return Err(invalid("unknown ouro-broker-v4-ghostty argument"));
            }
        }

        let gateway_fds = match (upstream, registration) {
            (None, None) => None,
            (Some(_), None) | (None, Some(_)) => {
                return Err(invalid(
                    "private gateway descriptors must be configured as a complete pair",
                ));
            }
            (Some(upstream), Some(registration)) => {
                if upstream == registration {
                    return Err(invalid("private gateway descriptors must be distinct"));
                }
                Some(InheritedGatewayFds::duplicate_and_validate(
                    upstream,
                    registration,
                )?)
            }
        };

        Ok(Self {
            broker_socket_path,
            gateway_fds,
        })
    }
}

impl InheritedGatewayFds {
    fn duplicate_and_validate(upstream: RawFd, registration: RawFd) -> io::Result<Self> {
        // The broker later spawns login shells. Mark the launchd-provided
        // originals as close-on-exec before retaining stable owned copies so
        // neither private authority transport can leak into a PTY child.
        set_cloexec(upstream).map_err(|error| {
            contextual(
                SESSION_MESSAGE_UPSTREAM_FD_FLAG,
                "could not protect inherited descriptor",
                error,
            )
        })?;
        set_cloexec(registration).map_err(|error| {
            contextual(
                PRINCIPAL_REGISTRATION_FD_FLAG,
                "could not protect inherited descriptor",
                error,
            )
        })?;
        let session_message_upstream = duplicate_cloexec(upstream).map_err(|error| {
            contextual(
                SESSION_MESSAGE_UPSTREAM_FD_FLAG,
                "could not duplicate inherited descriptor",
                error,
            )
        })?;
        let principal_registration = duplicate_cloexec(registration).map_err(|error| {
            contextual(
                PRINCIPAL_REGISTRATION_FD_FLAG,
                "could not duplicate inherited descriptor",
                error,
            )
        })?;

        let upstream_identity = validate_connected_unix_stream(
            session_message_upstream.as_raw_fd(),
            SESSION_MESSAGE_UPSTREAM_FD_FLAG,
        )?;
        let registration_identity = validate_connected_unix_stream(
            principal_registration.as_raw_fd(),
            PRINCIPAL_REGISTRATION_FD_FLAG,
        )?;
        if upstream_identity == registration_identity && upstream_identity.is_meaningful() {
            return Err(invalid(
                "private gateway descriptors alias the same socket endpoint",
            ));
        }

        Ok(Self {
            session_message_upstream,
            principal_registration,
        })
    }
}

fn set_cloexec(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    if flags & libc::FD_CLOEXEC == 0
        && unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0
    {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn parse_flag_value<I>(
    args: &mut I,
    destination: &mut Option<RawFd>,
    flag: &'static str,
) -> io::Result<()>
where
    I: Iterator<Item = OsString>,
{
    if destination.is_some() {
        return Err(invalid(format!("duplicate {flag}")));
    }
    let value = args
        .next()
        .ok_or_else(|| invalid(format!("missing descriptor after {flag}")))?;
    let value = value
        .to_str()
        .ok_or_else(|| invalid(format!("{flag} must be an ASCII descriptor number")))?;
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(invalid(format!(
            "{flag} must be an ASCII descriptor number"
        )));
    }
    let fd = value
        .parse::<RawFd>()
        .map_err(|_| invalid(format!("{flag} descriptor is out of range")))?;
    if fd <= libc::STDERR_FILENO {
        return Err(invalid(format!(
            "{flag} must not use stdin, stdout, or stderr"
        )));
    }
    *destination = Some(fd);
    Ok(())
}

fn duplicate_cloexec(fd: RawFd) -> io::Result<OwnedFd> {
    let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
    if duplicate < 0 {
        Err(io::Error::last_os_error())
    } else {
        // SAFETY: F_DUPFD_CLOEXEC returned a new descriptor owned by the caller.
        Ok(unsafe { OwnedFd::from_raw_fd(duplicate) })
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
struct SocketIdentity {
    device: libc::dev_t,
    inode: libc::ino_t,
}

impl SocketIdentity {
    fn is_meaningful(self) -> bool {
        self.device != 0 || self.inode != 0
    }
}

fn validate_connected_unix_stream(fd: RawFd, flag: &'static str) -> io::Result<SocketIdentity> {
    let mut stat: libc::stat = unsafe { zeroed() };
    if unsafe { libc::fstat(fd, &mut stat) } < 0 {
        return Err(contextual(
            flag,
            "fstat rejected inherited descriptor",
            io::Error::last_os_error(),
        ));
    }
    if stat.st_mode & libc::S_IFMT != libc::S_IFSOCK {
        return Err(invalid(format!("{flag} must reference a socket")));
    }

    let mut socket_type: libc::c_int = 0;
    let mut socket_type_len = size_of::<libc::c_int>() as libc::socklen_t;
    if unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_TYPE,
            (&mut socket_type as *mut libc::c_int).cast(),
            &mut socket_type_len,
        )
    } < 0
    {
        return Err(contextual(
            flag,
            "could not read inherited socket type",
            io::Error::last_os_error(),
        ));
    }
    if socket_type != libc::SOCK_STREAM {
        return Err(invalid(format!(
            "{flag} must reference a SOCK_STREAM socket"
        )));
    }

    require_unix_family(fd, flag, false)?;
    require_unix_family(fd, flag, true)?;

    Ok(SocketIdentity {
        device: stat.st_dev,
        inode: stat.st_ino,
    })
}

fn require_unix_family(fd: RawFd, flag: &'static str, peer: bool) -> io::Result<()> {
    let mut address: libc::sockaddr_storage = unsafe { zeroed() };
    let mut address_len = size_of::<libc::sockaddr_storage>() as libc::socklen_t;
    let result = unsafe {
        if peer {
            libc::getpeername(
                fd,
                (&mut address as *mut libc::sockaddr_storage).cast(),
                &mut address_len,
            )
        } else {
            libc::getsockname(
                fd,
                (&mut address as *mut libc::sockaddr_storage).cast(),
                &mut address_len,
            )
        }
    };
    if result < 0 {
        let message = if peer {
            "socket is not connected"
        } else {
            "could not inspect inherited socket address"
        };
        return Err(contextual(flag, message, io::Error::last_os_error()));
    }
    if (address_len as usize) < size_of::<libc::sa_family_t>()
        || address.ss_family as libc::c_int != libc::AF_UNIX
    {
        return Err(invalid(format!(
            "{flag} must reference a connected AF_UNIX socket"
        )));
    }
    Ok(())
}

fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn contextual(flag: &'static str, message: &'static str, cause: io::Error) -> io::Error {
    io::Error::new(cause.kind(), format!("{flag}: {message}: {cause}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::File;
    use std::net::{TcpListener, TcpStream};
    use std::os::fd::AsRawFd;
    use std::os::unix::net::{UnixDatagram, UnixStream};

    fn args(upstream: RawFd, registration: RawFd) -> Vec<OsString> {
        vec![
            "/tmp/broker.sock".into(),
            SESSION_MESSAGE_UPSTREAM_FD_FLAG.into(),
            upstream.to_string().into(),
            PRINCIPAL_REGISTRATION_FD_FLAG.into(),
            registration.to_string().into(),
        ]
    }

    #[test]
    fn terminal_only_launch_needs_no_gateway_descriptors() {
        let parsed = GhosttyBrokerRuntimeArgs::parse(["/tmp/broker.sock"]).unwrap();
        assert_eq!(parsed.broker_socket_path, PathBuf::from("/tmp/broker.sock"));
        assert!(parsed.gateway_fds.is_none());
        assert_eq!(
            parsed.session_message_readiness(),
            SessionMessageRuntimeReadiness::TerminalOnly
        );
        assert!(!parsed.may_advertise_authenticated_session_messaging());
    }

    #[test]
    fn complete_pair_is_duplicated_validated_and_close_on_exec() {
        let (upstream, _upstream_peer) = UnixStream::pair().unwrap();
        let (registration, _registration_peer) = UnixStream::pair().unwrap();

        let parsed =
            GhosttyBrokerRuntimeArgs::parse(args(upstream.as_raw_fd(), registration.as_raw_fd()))
                .unwrap();
        assert_eq!(
            parsed.session_message_readiness(),
            SessionMessageRuntimeReadiness::PrivateTransportsValidatedButUnauthenticated
        );
        assert!(!parsed.may_advertise_authenticated_session_messaging());
        let descriptors = parsed.gateway_fds.unwrap();
        for inherited in [upstream.as_raw_fd(), registration.as_raw_fd()] {
            let flags = unsafe { libc::fcntl(inherited, libc::F_GETFD) };
            assert!(flags >= 0);
            assert_ne!(flags & libc::FD_CLOEXEC, 0);
        }
        for descriptor in [
            descriptors.session_message_upstream(),
            descriptors.principal_registration(),
        ] {
            assert!(descriptor.as_raw_fd() > libc::STDERR_FILENO);
            let flags = unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_GETFD) };
            assert!(flags >= 0);
            assert_ne!(flags & libc::FD_CLOEXEC, 0);
        }
    }

    #[test]
    fn incomplete_repeated_malformed_and_stdio_descriptors_fail_closed() {
        let (stream, _peer) = UnixStream::pair().unwrap();
        let fd = stream.as_raw_fd().to_string();
        let invalid_cases: Vec<Vec<OsString>> = vec![
            vec![
                "/tmp/broker.sock".into(),
                SESSION_MESSAGE_UPSTREAM_FD_FLAG.into(),
                fd.clone().into(),
            ],
            vec![
                "/tmp/broker.sock".into(),
                SESSION_MESSAGE_UPSTREAM_FD_FLAG.into(),
                fd.clone().into(),
                SESSION_MESSAGE_UPSTREAM_FD_FLAG.into(),
                fd.clone().into(),
            ],
            vec![
                "/tmp/broker.sock".into(),
                SESSION_MESSAGE_UPSTREAM_FD_FLAG.into(),
                "three".into(),
                PRINCIPAL_REGISTRATION_FD_FLAG.into(),
                fd.clone().into(),
            ],
            vec![
                "/tmp/broker.sock".into(),
                SESSION_MESSAGE_UPSTREAM_FD_FLAG.into(),
                "0".into(),
                PRINCIPAL_REGISTRATION_FD_FLAG.into(),
                fd.clone().into(),
            ],
            vec![
                "/tmp/broker.sock".into(),
                SESSION_MESSAGE_UPSTREAM_FD_FLAG.into(),
                "999999".into(),
                PRINCIPAL_REGISTRATION_FD_FLAG.into(),
                fd.clone().into(),
            ],
        ];
        for case in invalid_cases {
            assert!(GhosttyBrokerRuntimeArgs::parse(case).is_err());
        }
    }

    #[test]
    fn same_descriptor_and_aliased_descriptor_fail_closed() {
        let (stream, _peer) = UnixStream::pair().unwrap();
        assert!(
            GhosttyBrokerRuntimeArgs::parse(args(stream.as_raw_fd(), stream.as_raw_fd(),)).is_err()
        );

        let alias = duplicate_cloexec(stream.as_raw_fd()).unwrap();
        assert!(
            GhosttyBrokerRuntimeArgs::parse(args(stream.as_raw_fd(), alias.as_raw_fd(),)).is_err()
        );
    }

    #[test]
    fn regular_file_datagram_and_unconnected_stream_fail_closed() {
        let (valid, _valid_peer) = UnixStream::pair().unwrap();
        let file = File::open("/dev/null").unwrap();
        assert!(
            GhosttyBrokerRuntimeArgs::parse(args(file.as_raw_fd(), valid.as_raw_fd())).is_err()
        );

        let datagram = UnixDatagram::unbound().unwrap();
        assert!(
            GhosttyBrokerRuntimeArgs::parse(args(datagram.as_raw_fd(), valid.as_raw_fd(),))
                .is_err()
        );

        let tcp_listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let tcp_client = TcpStream::connect(tcp_listener.local_addr().unwrap()).unwrap();
        let (_tcp_peer, _) = tcp_listener.accept().unwrap();
        assert!(
            GhosttyBrokerRuntimeArgs::parse(args(tcp_client.as_raw_fd(), valid.as_raw_fd(),))
                .is_err()
        );

        let directory = tempfile::tempdir().unwrap();
        let listener_path = directory.path().join("unconnected.sock");
        let listener = std::os::unix::net::UnixListener::bind(listener_path).unwrap();
        assert!(
            GhosttyBrokerRuntimeArgs::parse(args(listener.as_raw_fd(), valid.as_raw_fd(),))
                .is_err()
        );
    }
}
