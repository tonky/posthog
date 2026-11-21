//! A PgBouncer container between the persons pools and the fault proxy, configured like the
//! production persons poolers (`psql.persons` in PostHog/charts `apps/feature-flags`).

use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use testcontainers::core::{ExecCommand, Host, IntoContainerPort, WaitFor};
use testcontainers::runners::AsyncRunner;
use testcontainers::{ContainerAsync, GenericImage, ImageExt};
use url::Url;

/// A public build of the PgBouncer release that production runs.
const IMAGE: (&str, &str) = ("edoburu/pgbouncer", "v1.25.2-p0");
const LISTEN_PORT: u16 = 6543;
/// How the container reaches the fault proxy, which listens on the host.
const HOST_ALIAS: &str = "host.docker.internal";

pub const READ_DATABASE: &str = "persons_read";
pub const WRITE_DATABASE: &str = "persons_write";

pub struct PoolerSettings {
    pub read_pool_size: u32,
    pub write_pool_size: u32,
    pub read_statement_timeout_ms: u64,
    pub write_statement_timeout_ms: u64,
}

enum Backend {
    Local {
        dir: PathBuf,
        ini_path: PathBuf,
        port: u16,
        child: Mutex<Option<Child>>,
    },
    Container(ContainerAsync<GenericImage>),
}

pub struct PgBouncer {
    backend: Backend,
    url: Url,
}

impl Drop for PgBouncer {
    fn drop(&mut self) {
        if let Backend::Local { dir, child, .. } = &self.backend {
            if let Ok(mut guard) = child.lock() {
                if let Some(mut proc) = guard.take() {
                    drop(proc.kill());
                    drop(proc.wait());
                }
            }
            drop(std::fs::remove_dir_all(dir));
        }
    }
}

fn spawn_local_pgbouncer(ini_path: &PathBuf, port: u16) -> Child {
    let mut child = Command::new("pgbouncer")
        .arg(ini_path)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn local pgbouncer");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if TcpStream::connect(("127.0.0.1", port)).is_ok() {
            return child;
        }
        if let Ok(Some(status)) = child.try_wait() {
            panic!("local pgbouncer exited early: {status}");
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    drop(child.kill());
    drop(child.wait());
    panic!("local pgbouncer did not listen on 127.0.0.1:{port} within 5s");
}

impl PgBouncer {
    /// Pools the database of `upstream_url` through `upstream_port` on the host. [`Self::url`]
    /// reaches each pool.
    pub async fn start(upstream_url: &str, upstream_port: u16, settings: &PoolerSettings) -> Self {
        let mut url = Url::parse(upstream_url).expect("valid database URL");
        let database = url.path().trim_start_matches('/').to_string();
        let userlist = format!(
            "\"{}\" \"{}\"\n",
            url.username(),
            url.password().unwrap_or("")
        );
        // A fixed host port survives the restart in `Fault::PoolerRestart`.
        let host_port = free_port();
        if Command::new("pgbouncer")
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
        {
            let dir = std::env::temp_dir().join(format!(
                "pgbouncer-stall-{}-{host_port}",
                std::process::id()
            ));
            drop(std::fs::remove_dir_all(&dir));
            std::fs::create_dir_all(&dir).expect("create pgbouncer temp dir");
            let userlist_path = dir.join("userlist.txt");
            let ini_path = dir.join("pgbouncer.ini");
            std::fs::write(&userlist_path, &userlist).expect("write userlist.txt");
            let pool = |pool_size: u32, statement_timeout_ms: u64| {
                format!(
                    "host=127.0.0.1 port={upstream_port} dbname={database} \
                     pool_size={pool_size} min_pool_size={pool_size} \
                     connect_query='SET statement_timeout = {statement_timeout_ms}'"
                )
            };
            let ini = format!(
                "[databases]\n\
                 {READ_DATABASE} = {read}\n\
                 {WRITE_DATABASE} = {write}\n\
                 \n\
                 [pgbouncer]\n\
                 listen_addr = 127.0.0.1\n\
                 listen_port = {host_port}\n\
                 unix_socket_dir =\n\
                 auth_type = md5\n\
                 auth_file = {auth_file}\n\
                 pool_mode = transaction\n\
                 max_client_conn = 1000\n\
                 query_wait_timeout = 10\n\
                 server_connect_timeout = 5\n\
                 server_login_retry = 1\n\
                 ignore_startup_parameters = extra_float_digits\n",
                read = pool(settings.read_pool_size, settings.read_statement_timeout_ms),
                write = pool(
                    settings.write_pool_size,
                    settings.write_statement_timeout_ms
                ),
                auth_file = userlist_path.display(),
            );
            std::fs::write(&ini_path, ini).expect("write pgbouncer.ini");
            let child = spawn_local_pgbouncer(&ini_path, host_port);
            url.set_host(Some("127.0.0.1")).unwrap();
            url.set_port(Some(host_port)).unwrap();
            return Self {
                backend: Backend::Local {
                    dir,
                    ini_path,
                    port: host_port,
                    child: Mutex::new(Some(child)),
                },
                url,
            };
        }

        let pool = |pool_size: u32, statement_timeout_ms: u64| {
            format!(
                "host={HOST_ALIAS} port={upstream_port} dbname={database} \
                 pool_size={pool_size} min_pool_size={pool_size} \
                 connect_query='SET statement_timeout = {statement_timeout_ms}'"
            )
        };
        // Production also sets server_tls_sslmode = require, which the test Postgres does not
        // serve, and max_db_connections = 0 and client_login_timeout = 60, which are defaults.
        let ini = format!(
            "[databases]\n\
             {READ_DATABASE} = {read}\n\
             {WRITE_DATABASE} = {write}\n\
             \n\
             [pgbouncer]\n\
             listen_addr = 0.0.0.0\n\
             listen_port = {LISTEN_PORT}\n\
             unix_socket_dir =\n\
             auth_type = md5\n\
             auth_file = /etc/pgbouncer/userlist.txt\n\
             pool_mode = transaction\n\
             max_client_conn = 1000\n\
             query_wait_timeout = 10\n\
             server_connect_timeout = 5\n\
             server_login_retry = 1\n\
             ignore_startup_parameters = extra_float_digits\n",
            read = pool(settings.read_pool_size, settings.read_statement_timeout_ms),
            write = pool(
                settings.write_pool_size,
                settings.write_statement_timeout_ms
            ),
        );

        let container = GenericImage::new(IMAGE.0, IMAGE.1)
            .with_wait_for(WaitFor::message_on_either_std("process up"))
            .with_copy_to("/etc/pgbouncer/pgbouncer.ini", ini.into_bytes())
            .with_copy_to("/etc/pgbouncer/userlist.txt", userlist.into_bytes())
            .with_host(HOST_ALIAS, Host::HostGateway)
            .with_mapped_port(host_port, LISTEN_PORT.tcp())
            .start()
            .await
            .expect("PgBouncer starts; the PgBouncer topology needs Docker");

        url.set_host(Some("127.0.0.1")).unwrap();
        url.set_port(Some(host_port)).unwrap();
        Self {
            backend: Backend::Container(container),
            url,
        }
    }

    pub fn url(&self, database: &str) -> String {
        let mut url = self.url.clone();
        url.set_path(database);
        url.to_string()
    }

    /// Stops PgBouncer with SIGINT, as the production stop hook does: it waits for transactions
    /// in flight, then closes every client and server connection.
    pub async fn stop(&self) {
        match &self.backend {
            Backend::Local { child, .. } => {
                let mut proc = child.lock().unwrap().take().expect("pgbouncer running");
                drop(
                    Command::new("kill")
                        .args(["-INT", &proc.id().to_string()])
                        .status(),
                );
                drop(proc.wait());
            }
            Backend::Container(container) => {
                container
                    .exec(ExecCommand::new(["kill", "-INT", "1"]))
                    .await
                    .unwrap();
                while container.is_running().await.unwrap() {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            }
        }
    }

    /// Starts PgBouncer again with no server connection, as a replaced pooler pod does.
    pub async fn start_again(&self) {
        match &self.backend {
            Backend::Local {
                ini_path,
                port,
                child,
                ..
            } => {
                let proc = spawn_local_pgbouncer(ini_path, *port);
                *child.lock().unwrap() = Some(proc);
            }
            Backend::Container(container) => {
                container.start().await.unwrap();
            }
        }
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}
