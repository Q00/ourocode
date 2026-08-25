//! PID-generation-bound macOS desktop peer verification.
//!
//! The accepted Unix socket is the only source of peer UID, PID, and audit
//! token. Production mutation authority additionally requires a reviewed
//! designated requirement and team identifier. Caller JSON, executable paths,
//! and bundle identifiers do not participate in admission.

use crate::authority_registry::{AuthorityConnectionId, VerifiedDesktopPeer};
#[cfg(target_os = "macos")]
use sha2::{Digest, Sha256};
use std::fmt;
use std::num::NonZeroU64;
use std::os::fd::BorrowedFd;

pub const MAX_DESIGNATED_REQUIREMENT_BYTES: usize = 2_048;
pub const MAX_TEAM_IDENTIFIER_BYTES: usize = 128;

#[cfg(target_os = "macos")]
const AUDIT_DIGEST_DOMAIN: &[u8] = b"ourocode.desktop.audit-identity.v1\0";
#[cfg(target_os = "macos")]
const INCARNATION_DOMAIN: &[u8] = b"ourocode.desktop.incarnation.v1\0";

/// Installation-owned code identity policy. It must never be populated from a
/// desktop request frame.
#[derive(Clone, Eq, PartialEq)]
pub struct DesktopCodePolicy {
    designated_requirement: Box<str>,
    team_identifier: Box<str>,
}

impl DesktopCodePolicy {
    pub fn new(
        designated_requirement: impl Into<String>,
        team_identifier: impl Into<String>,
    ) -> Result<Self, DesktopPeerVerificationError> {
        let designated_requirement = designated_requirement.into();
        let team_identifier = team_identifier.into();
        validate_policy_string(
            &designated_requirement,
            MAX_DESIGNATED_REQUIREMENT_BYTES,
            PolicyField::DesignatedRequirement,
        )?;
        validate_policy_string(
            &team_identifier,
            MAX_TEAM_IDENTIFIER_BYTES,
            PolicyField::TeamIdentifier,
        )?;
        if !team_identifier
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
        {
            return Err(DesktopPeerVerificationError::InvalidPolicy(
                PolicyField::TeamIdentifier,
            ));
        }
        Ok(Self {
            designated_requirement: designated_requirement.into_boxed_str(),
            team_identifier: team_identifier.into_boxed_str(),
        })
    }
}

impl fmt::Debug for DesktopCodePolicy {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DesktopCodePolicy")
            .field("designated_requirement", &"<redacted>")
            .field("team_identifier", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ExpectedDesktopPeer {
    uid: u32,
    pid: Option<u32>,
}

impl ExpectedDesktopPeer {
    pub fn new(uid: u32, pid: Option<u32>) -> Result<Self, DesktopPeerVerificationError> {
        if pid == Some(0) {
            return Err(DesktopPeerVerificationError::InvalidExpectedPid);
        }
        Ok(Self { uid, pid })
    }

    /// Default same-user policy. A launchd/XPC integration should additionally
    /// pin the expected PID when it has one.
    pub fn current_effective_user(pid: Option<u32>) -> Result<Self, DesktopPeerVerificationError> {
        Self::new(unsafe { libc::geteuid() }, pid)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ReadOnlyDesktopPeer {
    uid: u32,
    pid: u32,
}

impl ReadOnlyDesktopPeer {
    pub fn uid(self) -> u32 {
        self.uid
    }

    pub fn pid(self) -> u32 {
        self.pid
    }
}

/// Verification never silently upgrades an ad-hoc or unsigned development
/// client. Such a peer can only be bound through the registry's read-only lane.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DesktopPeerAdmission {
    ReadOnly(ReadOnlyDesktopPeer),
    Mutation(VerifiedDesktopPeer),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PolicyField {
    DesignatedRequirement,
    TeamIdentifier,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DesktopPeerVerificationError {
    InvalidPolicy(PolicyField),
    InvalidExpectedPid,
    KernelCredentialsUnavailable,
    KernelCredentialSizeMismatch,
    EffectiveUidMismatch,
    ExpectedUidMismatch,
    ExpectedPidMismatch,
    AuditUidMismatch,
    AuditPidMismatch,
    PeerIdentityChanged,
    InvalidDesignatedRequirement,
    CodeIdentityUnavailable,
    CodeIdentityRejected,
    CodeIdentityDataInvalid,
    UnsupportedPlatform,
}

impl fmt::Display for DesktopPeerVerificationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidPolicy(PolicyField::DesignatedRequirement) => {
                "invalid designated requirement policy"
            }
            Self::InvalidPolicy(PolicyField::TeamIdentifier) => "invalid team identifier policy",
            Self::InvalidExpectedPid => "invalid expected desktop PID",
            Self::KernelCredentialsUnavailable => "kernel peer credentials unavailable",
            Self::KernelCredentialSizeMismatch => "kernel peer credential size mismatch",
            Self::EffectiveUidMismatch => "desktop peer UID did not match the broker user",
            Self::ExpectedUidMismatch => "desktop peer UID did not match launch policy",
            Self::ExpectedPidMismatch => "desktop peer PID did not match launch policy",
            Self::AuditUidMismatch => "desktop audit token UID did not match socket credentials",
            Self::AuditPidMismatch => "desktop audit token PID did not match socket credentials",
            Self::PeerIdentityChanged => "desktop peer identity changed during verification",
            Self::InvalidDesignatedRequirement => "designated requirement could not be compiled",
            Self::CodeIdentityUnavailable => "desktop code identity unavailable",
            Self::CodeIdentityRejected => "desktop code identity rejected",
            Self::CodeIdentityDataInvalid => "desktop code identity data was invalid",
            Self::UnsupportedPlatform => {
                "signed desktop verification is unsupported on this platform"
            }
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for DesktopPeerVerificationError {}

/// Verify an already accepted socket without opening a listener or consulting
/// any caller-supplied path/identity assertion.
pub fn verify_accepted_desktop_peer(
    socket: BorrowedFd<'_>,
    connection_id: AuthorityConnectionId,
    broker_generation: NonZeroU64,
    expected: ExpectedDesktopPeer,
    policy: &DesktopCodePolicy,
) -> Result<DesktopPeerAdmission, DesktopPeerVerificationError> {
    platform::verify(socket, connection_id, broker_generation, expected, policy)
}

fn validate_policy_string(
    value: &str,
    max_bytes: usize,
    field: PolicyField,
) -> Result<(), DesktopPeerVerificationError> {
    if value.is_empty()
        || value.len() > max_bytes
        || value.trim() != value
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_graphic() || byte == b' ')
    {
        return Err(DesktopPeerVerificationError::InvalidPolicy(field));
    }
    Ok(())
}

/// Sealed handoff into `authority_registry`: callers outside this module can
/// consume but cannot manufacture it.
#[cfg(target_os = "macos")]
pub(crate) struct VerifiedDesktopEvidence {
    connection_id: AuthorityConnectionId,
    uid: u32,
    audit_identity_digest: [u8; 32],
    desktop_incarnation: [u8; 24],
    broker_generation: NonZeroU64,
}

#[cfg(target_os = "macos")]
impl VerifiedDesktopEvidence {
    pub(crate) fn into_parts(self) -> (AuthorityConnectionId, u32, [u8; 32], [u8; 24], NonZeroU64) {
        (
            self.connection_id,
            self.uid,
            self.audit_identity_digest,
            self.desktop_incarnation,
            self.broker_generation,
        )
    }
}

#[cfg(target_os = "macos")]
fn mutation_capability(
    connection_id: AuthorityConnectionId,
    uid: u32,
    audit_token: &[u8; 32],
    code_identity: &[u8],
    team_identifier: &str,
    broker_generation: NonZeroU64,
) -> VerifiedDesktopPeer {
    let mut audit_hasher = Sha256::new();
    audit_hasher.update(AUDIT_DIGEST_DOMAIN);
    audit_hasher.update(audit_token);
    audit_hasher.update((code_identity.len() as u16).to_be_bytes());
    audit_hasher.update(code_identity);
    audit_hasher.update((team_identifier.len() as u16).to_be_bytes());
    audit_hasher.update(team_identifier.as_bytes());
    let audit_identity_digest: [u8; 32] = audit_hasher.finalize().into();

    let mut incarnation_hasher = Sha256::new();
    incarnation_hasher.update(INCARNATION_DOMAIN);
    incarnation_hasher.update(audit_token);
    incarnation_hasher.update(broker_generation.get().to_be_bytes());
    let incarnation_digest: [u8; 32] = incarnation_hasher.finalize().into();
    let mut desktop_incarnation = [0_u8; 24];
    desktop_incarnation.copy_from_slice(&incarnation_digest[..24]);

    VerifiedDesktopPeer::from_code_identity_evidence(VerifiedDesktopEvidence {
        connection_id,
        uid,
        audit_identity_digest,
        desktop_incarnation,
        broker_generation,
    })
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;
    use std::ffi::c_void;
    use std::os::fd::AsRawFd;
    use std::ptr;

    const SIGNING_INFORMATION: u32 = 1 << 1;
    const MAX_CODE_IDENTITY_BYTES: usize = 64;

    type OsStatus = i32;
    type SecCsFlags = u32;
    type SecCodeRef = *const c_void;
    type SecRequirementRef = *const c_void;

    #[repr(C)]
    #[derive(Clone, Copy, Eq, PartialEq)]
    struct AuditToken {
        values: [u32; 8],
    }

    impl AuditToken {
        fn bytes(&self) -> [u8; 32] {
            let mut bytes = [0_u8; 32];
            // Security.framework consumes the kernel ABI byte representation,
            // not a serialized caller-controlled token.
            for (destination, value) in bytes.chunks_exact_mut(4).zip(self.values) {
                destination.copy_from_slice(&value.to_ne_bytes());
            }
            bytes
        }
    }

    struct OwnedSecurityObject(*const c_void);

    impl OwnedSecurityObject {
        fn as_ptr(&self) -> *const c_void {
            self.0
        }
    }

    impl Drop for OwnedSecurityObject {
        fn drop(&mut self) {
            unsafe { core_foundation::base::CFRelease(self.0) }
        }
    }

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecGuestAttributeAudit: core_foundation::string::CFStringRef;
        static kSecCodeInfoTeamIdentifier: core_foundation::string::CFStringRef;
        static kSecCodeInfoUnique: core_foundation::string::CFStringRef;

        fn SecCodeCopyGuestWithAttributes(
            host: SecCodeRef,
            attributes: core_foundation::dictionary::CFDictionaryRef,
            flags: SecCsFlags,
            guest: *mut SecCodeRef,
        ) -> OsStatus;
        fn SecRequirementCreateWithString(
            text: core_foundation::string::CFStringRef,
            flags: SecCsFlags,
            requirement: *mut SecRequirementRef,
        ) -> OsStatus;
        fn SecCodeCheckValidity(
            code: SecCodeRef,
            flags: SecCsFlags,
            requirement: SecRequirementRef,
        ) -> OsStatus;
        fn SecCodeCopySigningInformation(
            code: SecCodeRef,
            flags: SecCsFlags,
            information: *mut core_foundation::dictionary::CFDictionaryRef,
        ) -> OsStatus;
    }

    #[link(name = "bsm")]
    unsafe extern "C" {
        fn audit_token_to_euid(token: AuditToken) -> libc::uid_t;
        fn audit_token_to_pid(token: AuditToken) -> libc::pid_t;
    }

    #[derive(Clone)]
    struct SigningIdentity {
        team_identifier: Option<String>,
        unique_code_identity: Vec<u8>,
    }

    trait CodeIdentityVerifier {
        fn verify(
            &self,
            audit_token: &AuditToken,
            policy: &DesktopCodePolicy,
        ) -> Result<SigningIdentity, DesktopPeerVerificationError>;
    }

    struct SecurityFrameworkVerifier;

    impl CodeIdentityVerifier for SecurityFrameworkVerifier {
        fn verify(
            &self,
            audit_token: &AuditToken,
            policy: &DesktopCodePolicy,
        ) -> Result<SigningIdentity, DesktopPeerVerificationError> {
            let requirement_text = CFString::new(&policy.designated_requirement);
            let mut requirement_ref: SecRequirementRef = ptr::null();
            let requirement_status = unsafe {
                SecRequirementCreateWithString(
                    requirement_text.as_concrete_TypeRef(),
                    0,
                    &mut requirement_ref,
                )
            };
            if requirement_status != 0 || requirement_ref.is_null() {
                return Err(DesktopPeerVerificationError::InvalidDesignatedRequirement);
            }
            let requirement = OwnedSecurityObject(requirement_ref);

            let audit_data = CFData::from_buffer(&audit_token.bytes());
            let audit_key = unsafe { CFString::wrap_under_get_rule(kSecGuestAttributeAudit) };
            let attributes =
                CFDictionary::from_CFType_pairs(&[(audit_key.as_CFType(), audit_data.as_CFType())]);
            let mut code_ref: SecCodeRef = ptr::null();
            let guest_status = unsafe {
                SecCodeCopyGuestWithAttributes(
                    ptr::null(),
                    attributes.as_concrete_TypeRef(),
                    0,
                    &mut code_ref,
                )
            };
            if guest_status != 0 || code_ref.is_null() {
                return Err(DesktopPeerVerificationError::CodeIdentityUnavailable);
            }
            let code = OwnedSecurityObject(code_ref);

            let signing_identity = copy_signing_identity(code.as_ptr())?;
            // Missing team identifier means unsigned/ad-hoc development code.
            // It never yields an opaque mutation capability.
            let Some(team_identifier) = signing_identity.team_identifier.as_deref() else {
                return Ok(signing_identity);
            };
            if team_identifier.as_bytes() != policy.team_identifier.as_bytes() {
                return Err(DesktopPeerVerificationError::CodeIdentityRejected);
            }
            let validity_status =
                unsafe { SecCodeCheckValidity(code.as_ptr(), 0, requirement.as_ptr()) };
            if validity_status != 0 {
                return Err(DesktopPeerVerificationError::CodeIdentityRejected);
            }
            Ok(signing_identity)
        }
    }

    fn copy_signing_identity(
        code: SecCodeRef,
    ) -> Result<SigningIdentity, DesktopPeerVerificationError> {
        let mut information_ref: core_foundation::dictionary::CFDictionaryRef = ptr::null();
        let status = unsafe {
            SecCodeCopySigningInformation(code, SIGNING_INFORMATION, &mut information_ref)
        };
        if status != 0 || information_ref.is_null() {
            return Err(DesktopPeerVerificationError::CodeIdentityUnavailable);
        }
        let information: CFDictionary<CFString, CFType> =
            unsafe { TCFType::wrap_under_create_rule(information_ref) };

        let team_key = unsafe { CFString::wrap_under_get_rule(kSecCodeInfoTeamIdentifier) };
        let team_identifier = match information.find(&team_key) {
            Some(value) => {
                let value = value
                    .downcast::<CFString>()
                    .ok_or(DesktopPeerVerificationError::CodeIdentityDataInvalid)?;
                if value.char_len() > MAX_TEAM_IDENTIFIER_BYTES as isize {
                    return Err(DesktopPeerVerificationError::CodeIdentityDataInvalid);
                }
                let value = value.to_string();
                validate_policy_string(
                    &value,
                    MAX_TEAM_IDENTIFIER_BYTES,
                    PolicyField::TeamIdentifier,
                )
                .map_err(|_| DesktopPeerVerificationError::CodeIdentityDataInvalid)?;
                Some(value)
            }
            None => None,
        };

        let unique_key = unsafe { CFString::wrap_under_get_rule(kSecCodeInfoUnique) };
        let unique_code_identity = match information.find(&unique_key) {
            Some(value) => {
                let value = value
                    .downcast::<CFData>()
                    .ok_or(DesktopPeerVerificationError::CodeIdentityDataInvalid)?;
                if value.is_empty() || value.len() > MAX_CODE_IDENTITY_BYTES as isize {
                    return Err(DesktopPeerVerificationError::CodeIdentityDataInvalid);
                }
                value.bytes().to_vec()
            }
            None if team_identifier.is_none() => Vec::new(),
            None => return Err(DesktopPeerVerificationError::CodeIdentityDataInvalid),
        };
        Ok(SigningIdentity {
            team_identifier,
            unique_code_identity,
        })
    }

    #[derive(Clone, Copy, Eq, PartialEq)]
    struct KernelPeerIdentity {
        uid: u32,
        pid: u32,
        audit_token: AuditToken,
    }

    fn kernel_peer_identity(
        socket: BorrowedFd<'_>,
    ) -> Result<KernelPeerIdentity, DesktopPeerVerificationError> {
        let fd = socket.as_raw_fd();
        let mut uid: libc::uid_t = 0;
        let mut gid: libc::gid_t = 0;
        if unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } != 0 {
            return Err(DesktopPeerVerificationError::KernelCredentialsUnavailable);
        }

        let mut pid: libc::pid_t = 0;
        let mut pid_size = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
        if unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_LOCAL,
                libc::LOCAL_PEERPID,
                ptr::from_mut(&mut pid).cast(),
                &mut pid_size,
            )
        } != 0
        {
            return Err(DesktopPeerVerificationError::KernelCredentialsUnavailable);
        }
        if pid_size as usize != std::mem::size_of::<libc::pid_t>() {
            return Err(DesktopPeerVerificationError::KernelCredentialSizeMismatch);
        }
        let pid = u32::try_from(pid)
            .ok()
            .filter(|pid| *pid != 0)
            .ok_or(DesktopPeerVerificationError::KernelCredentialsUnavailable)?;

        let mut audit_token = AuditToken { values: [0; 8] };
        let mut audit_size = std::mem::size_of::<AuditToken>() as libc::socklen_t;
        if unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_LOCAL,
                libc::LOCAL_PEERTOKEN,
                ptr::from_mut(&mut audit_token).cast(),
                &mut audit_size,
            )
        } != 0
        {
            return Err(DesktopPeerVerificationError::KernelCredentialsUnavailable);
        }
        if audit_size as usize != std::mem::size_of::<AuditToken>() {
            return Err(DesktopPeerVerificationError::KernelCredentialSizeMismatch);
        }
        let audit_uid = unsafe { audit_token_to_euid(audit_token) };
        let audit_pid = unsafe { audit_token_to_pid(audit_token) };
        if audit_uid != uid {
            return Err(DesktopPeerVerificationError::AuditUidMismatch);
        }
        if audit_pid <= 0 || audit_pid as u32 != pid {
            return Err(DesktopPeerVerificationError::AuditPidMismatch);
        }
        Ok(KernelPeerIdentity {
            uid,
            pid,
            audit_token,
        })
    }

    pub(super) fn verify(
        socket: BorrowedFd<'_>,
        connection_id: AuthorityConnectionId,
        broker_generation: NonZeroU64,
        expected: ExpectedDesktopPeer,
        policy: &DesktopCodePolicy,
    ) -> Result<DesktopPeerAdmission, DesktopPeerVerificationError> {
        verify_with(
            socket,
            connection_id,
            broker_generation,
            expected,
            policy,
            &SecurityFrameworkVerifier,
        )
    }

    fn verify_with(
        socket: BorrowedFd<'_>,
        connection_id: AuthorityConnectionId,
        broker_generation: NonZeroU64,
        expected: ExpectedDesktopPeer,
        policy: &DesktopCodePolicy,
        verifier: &dyn CodeIdentityVerifier,
    ) -> Result<DesktopPeerAdmission, DesktopPeerVerificationError> {
        let before = kernel_peer_identity(socket)?;
        if before.uid != unsafe { libc::geteuid() } {
            return Err(DesktopPeerVerificationError::EffectiveUidMismatch);
        }
        if before.uid != expected.uid {
            return Err(DesktopPeerVerificationError::ExpectedUidMismatch);
        }
        if expected
            .pid
            .is_some_and(|expected_pid| before.pid != expected_pid)
        {
            return Err(DesktopPeerVerificationError::ExpectedPidMismatch);
        }

        let signing_identity = verifier.verify(&before.audit_token, policy)?;
        // Re-read all three kernel credentials after Security.framework work.
        // Exact audit-token equality includes the PID version, closing the PID
        // reuse window that a numeric LOCAL_PEERPID check leaves open.
        let after = kernel_peer_identity(socket)?;
        if before != after {
            return Err(DesktopPeerVerificationError::PeerIdentityChanged);
        }
        let Some(team_identifier) = signing_identity.team_identifier.as_deref() else {
            return Ok(DesktopPeerAdmission::ReadOnly(ReadOnlyDesktopPeer {
                uid: before.uid,
                pid: before.pid,
            }));
        };
        if team_identifier != policy.team_identifier.as_ref()
            || signing_identity.unique_code_identity.is_empty()
        {
            return Err(DesktopPeerVerificationError::CodeIdentityRejected);
        }
        let audit_token = before.audit_token.bytes();
        Ok(DesktopPeerAdmission::Mutation(mutation_capability(
            connection_id,
            before.uid,
            &audit_token,
            &signing_identity.unique_code_identity,
            team_identifier,
            broker_generation,
        )))
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::num::NonZeroU64;
        use std::os::fd::AsFd;
        use std::os::unix::net::UnixStream;

        const GENERATION: NonZeroU64 = NonZeroU64::new(7).unwrap();

        fn connection() -> AuthorityConnectionId {
            AuthorityConnectionId::new(NonZeroU64::new(9).unwrap())
        }

        fn policy() -> DesktopCodePolicy {
            DesktopCodePolicy::new(
                "identifier \"com.ourocode.desktop.tests\" and anchor apple generic",
                "OUROCODETEST",
            )
            .unwrap()
        }

        #[test]
        fn current_ad_hoc_test_process_is_explicitly_read_only() {
            let (server, _client) = UnixStream::pair().unwrap();
            let expected =
                ExpectedDesktopPeer::current_effective_user(Some(std::process::id())).unwrap();
            assert!(matches!(
                verify(
                    server.as_fd(),
                    connection(),
                    GENERATION,
                    expected,
                    &policy()
                ),
                Ok(DesktopPeerAdmission::ReadOnly(_))
            ));
        }

        #[test]
        fn expected_uid_and_pid_mismatches_fail_before_code_admission() {
            let (server, _client) = UnixStream::pair().unwrap();
            let wrong_uid = unsafe { libc::geteuid() }.wrapping_add(1);
            assert_eq!(
                verify(
                    server.as_fd(),
                    connection(),
                    GENERATION,
                    ExpectedDesktopPeer::new(wrong_uid, Some(std::process::id())).unwrap(),
                    &policy()
                ),
                Err(DesktopPeerVerificationError::ExpectedUidMismatch)
            );
            assert_eq!(
                verify(
                    server.as_fd(),
                    connection(),
                    GENERATION,
                    ExpectedDesktopPeer::current_effective_user(Some(
                        std::process::id().wrapping_add(1)
                    ))
                    .unwrap(),
                    &policy()
                ),
                Err(DesktopPeerVerificationError::ExpectedPidMismatch)
            );
        }

        #[test]
        fn malformed_designated_requirement_is_rejected() {
            let (server, _client) = UnixStream::pair().unwrap();
            let malformed =
                DesktopCodePolicy::new("not a requirement !!!", "OUROCODETEST").unwrap();
            assert_eq!(
                verify(
                    server.as_fd(),
                    connection(),
                    GENERATION,
                    ExpectedDesktopPeer::current_effective_user(Some(std::process::id())).unwrap(),
                    &malformed
                ),
                Err(DesktopPeerVerificationError::InvalidDesignatedRequirement)
            );
        }

        struct TestSignedVerifier;

        impl CodeIdentityVerifier for TestSignedVerifier {
            fn verify(
                &self,
                _audit_token: &AuditToken,
                policy: &DesktopCodePolicy,
            ) -> Result<SigningIdentity, DesktopPeerVerificationError> {
                Ok(SigningIdentity {
                    team_identifier: Some(policy.team_identifier.to_string()),
                    unique_code_identity: vec![0x5a; 32],
                })
            }
        }

        #[test]
        fn test_only_signed_verifier_yields_an_opaque_private_capability() {
            let (server, _client) = UnixStream::pair().unwrap();
            let admission = verify_with(
                server.as_fd(),
                connection(),
                GENERATION,
                ExpectedDesktopPeer::current_effective_user(Some(std::process::id())).unwrap(),
                &policy(),
                &TestSignedVerifier,
            )
            .unwrap();
            let DesktopPeerAdmission::Mutation(peer) = admission else {
                panic!("test-only signed verifier did not produce mutation capability");
            };
            let debug = format!("{peer:?}");
            assert_eq!(
                debug,
                "VerifiedDesktopPeer { connection_id: AuthorityConnectionId(9), identity: \"<redacted>\", .. }"
            );
            assert!(!debug.contains("OUROCODETEST"));
            assert!(!debug.contains("5a5a5a"));
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::*;

    pub(super) fn verify(
        _socket: BorrowedFd<'_>,
        _connection_id: AuthorityConnectionId,
        _broker_generation: NonZeroU64,
        _expected: ExpectedDesktopPeer,
        _policy: &DesktopCodePolicy,
    ) -> Result<DesktopPeerAdmission, DesktopPeerVerificationError> {
        Err(DesktopPeerVerificationError::UnsupportedPlatform)
    }
}

#[cfg(test)]
mod policy_tests {
    use super::*;

    #[test]
    fn policy_inputs_are_bounded_and_debug_is_redacted() {
        assert!(matches!(
            DesktopCodePolicy::new("x".repeat(MAX_DESIGNATED_REQUIREMENT_BYTES + 1), "TEAM"),
            Err(DesktopPeerVerificationError::InvalidPolicy(
                PolicyField::DesignatedRequirement
            ))
        ));
        assert!(matches!(
            DesktopCodePolicy::new("identifier \"app\"", "TEAM/INVALID"),
            Err(DesktopPeerVerificationError::InvalidPolicy(
                PolicyField::TeamIdentifier
            ))
        ));
        let policy = DesktopCodePolicy::new("identifier \"private.app\"", "PRIVATE-TEAM").unwrap();
        let debug = format!("{policy:?}");
        assert!(!debug.contains("private.app"));
        assert!(!debug.contains("PRIVATE-TEAM"));
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn non_macos_verifier_fails_closed() {
        use std::os::fd::AsFd;
        use std::os::unix::net::UnixStream;

        let (server, _client) = UnixStream::pair().unwrap();
        let policy = DesktopCodePolicy::new("identifier \"app\"", "TEAM").unwrap();
        assert_eq!(
            verify_accepted_desktop_peer(
                server.as_fd(),
                AuthorityConnectionId::new(NonZeroU64::new(1).unwrap()),
                NonZeroU64::new(1).unwrap(),
                ExpectedDesktopPeer::current_effective_user(None).unwrap(),
                &policy,
            ),
            Err(DesktopPeerVerificationError::UnsupportedPlatform)
        );
    }
}
