# `max_execution_time`: an enforced contract

## TL;DR

When a job declares `self.max_execution_time = N.seconds`, solid_queue sets
`TCP_USER_TIMEOUT` on every outbound TCP socket opened during `perform`.
The Linux kernel — not Ruby, not a watchdog — closes connections that go
past the deadline. Wedges resolve in seconds, not hours.

```ruby
class FetchUpstreamJob < ApplicationJob
  self.max_execution_time = 30.seconds

  def perform(url)
    Net::HTTP.get(URI(url))
  end
end
```

If the upstream stops making forward progress, the kernel closes the socket
~25s in (5s headroom) and `Net::HTTP.get` raises. The job either fails or
retries via `retry_on`, and the worker thread is freed immediately.

## The problem this fixes

A worker thread parked in a blocking syscall (`recv`, TLS handshake,
libpq's `poll`) cannot be interrupted by `Thread#kill` or
`Timeout.timeout`. Both work by setting a flag the thread checks when it
returns to user space. If the thread never returns from the kernel — say,
because the upstream server has stopped reading and the OS receive buffer
has filled — the flag is never read. The thread sits there for hours, the
worker pool drains, the queue backs up.

Watchdog-based recovery (release the claim from outside the wedged thread,
let a healthy thread re-pick the job) is partial: the wedged thread is
still alive. When it eventually unblocks, it can stomp on data the
re-running job has already produced.

## Why TCP_USER_TIMEOUT

[`tcp(7)`](https://man7.org/linux/man-pages/man7/tcp.7.html):

> `TCP_USER_TIMEOUT` ... specifies the maximum amount of time in
> milliseconds that transmitted data may remain unacknowledged before TCP
> will forcibly close the corresponding connection and return ETIMEDOUT
> to the application.

Per-socket option, set via `setsockopt`. Bounds the *whole connection* —
unlike `SO_RCVTIMEO` (per-recv, defeated by drip-feeding) and unlike
`Net::HTTP#read_timeout` (userspace check, only fires when the syscall
returns). The kernel itself drops the connection at the deadline; the
next read or write returns `ETIMEDOUT`. Ruby's IO layer surfaces it as
`Errno::ETIMEDOUT` or `IO::TimeoutError` depending on the call path
(`Net::HTTP` may further wrap as `Net::ReadTimeout`).

Linux only. macOS silently no-ops via `Errno::ENOPROTOOPT`, so dev work
is unaffected.

## How it works

Three pieces:

1. `SolidQueue::TcpConnection` (`lib/solid_queue/tcp_connection.rb`) — a
   thread-local block scope. `with_timeout(seconds) { ... }` sets the
   thread-local; `maybe_apply!(socket)` reads it and calls
   `setsockopt(SOL_TCP, 18, ms)`. Errors on unsupported platforms are
   silently rescued.

2. Prepend hooks on `Socket.tcp`, `TCPSocket.new`, and `TCPSocket.open`
   call `TcpConnection.maybe_apply!` on every newly created socket. This
   covers Net::HTTP, libpq (when it uses Ruby's socket layer), and most
   pure-Ruby HTTP clients. FFI-based clients (curb, anything wrapping
   libcurl) bypass this.

3. `ActiveJob::MaxExecutionTime` (`lib/active_job/max_execution_time.rb`)
   — a concern that adds the `class_attribute :max_execution_time` and
   an `around_perform` that wraps the job in
   `TcpConnection.with_timeout(headroom_seconds(max))`. The concern is
   included into `ActiveJob::Base` via solid_queue's engine, so every
   job class gets the API.

`headroom_seconds(max)` reserves 5 seconds for the rescue handler at
production scales (max ≥ 10s) and falls back to 90% of max below that
so short timeouts in tests still land below the kernel deadline:

| max     | TCP_USER_TIMEOUT |
|---------|------------------|
| 1s      | 0.9s             |
| 10s     | 5s               |
| 30s     | 25s              |
| 10min   | 9min 55s         |

## Failure modes worth knowing

- **Exception class translation.** `TCP_USER_TIMEOUT` raises ETIMEDOUT at
  the socket layer, but Ruby's IO and Net::HTTP wrap it. The test suite
  asserts `Errno::ETIMEDOUT || IO::TimeoutError`. Rescues in calling jobs
  should catch both, plus `Net::ReadTimeout` if going through Net::HTTP.

- **TLS-wrapped sockets.** OpenSSL on top of TCP — when the kernel kills
  the underlying socket mid-`SSL_read`, the SSL layer can surface either
  `Errno::ETIMEDOUT` or `OpenSSL::SSL::SSLError`. Production rescues
  should catch the SSLError class too.

- **Persistent connection pools.** Pooled connections retain the
  `TCP_USER_TIMEOUT` value from whichever job created them. Per-job
  tightening is best-effort for pooled connections; the global default
  (`SolidQueue::TcpConnection.global_default_seconds`) is the operative
  ceiling.

- **DNS not covered.** `TCP_USER_TIMEOUT` only applies after the TCP
  socket is established. `getaddrinfo` wedges need separate mitigation
  via `resolv.conf` (`options timeout:N attempts:M`).

- **Connect timeout vs read timeout.** `TCP_USER_TIMEOUT` covers
  post-connection wedges. The connect phase has its own timeout —
  `Net::HTTP#open_timeout`, libpq `connect_timeout`, etc.

## Verification

The load-bearing claim — that the Linux kernel actually closes a wedged
TCP connection at the configured `TCP_USER_TIMEOUT` — was validated in
Docker before any implementation was written:

```
server listening on 127.0.0.1:35067
got IO::TimeoutError: Blocking operation timed out! after 5.6s
```

Setting `TCP_USER_TIMEOUT = 5_000` and pumping bytes into a TCP server
that never reads: the kernel killed the connection at ~5.6s. Note Ruby
3.3 surfaces this as `IO::TimeoutError` rather than `Errno::ETIMEDOUT`
through `IO#write` — captured in the test rescues.

## Running the tests

The tests are Linux-only (skipped on macOS). To run them on a macOS dev
machine, use the included Docker test runner:

```sh
docker build -f Dockerfile.test -t solid-queue-test:linux .
docker volume create solid-queue-bundle
docker run --rm -v $PWD:/app -v solid-queue-bundle:/bundle -w /app \
  solid-queue-test:linux bundle install
docker run --rm -v $PWD:/app -v solid-queue-bundle:/bundle -w /app \
  -e TARGET_DB=sqlite solid-queue-test:linux \
  bash -c 'cd test/dummy && bundle exec rails db:reset && cd /app && \
           bundle exec bin/rails test test/unit/tcp_user_timeout_test.rb'
```

Expected: `7 runs, 21 assertions, 0 failures, 0 errors, 0 skips`.

## References

- [`tcp(7)`](https://man7.org/linux/man-pages/man7/tcp.7.html)
- [Cloudflare: When TCP sockets refuse to die](https://blog.cloudflare.com/when-tcp-sockets-refuse-to-die/)
- [Instacart: The Vanishing Thread and PostgreSQL TCP Connection Parameters](https://tech.instacart.com/the-vanishing-thread-and-postgresql-tcp-connection-parameters-93afc0e1208c)
- [gRPC proposal A18-tcp-user-timeout](https://github.com/grpc/proposal/blob/master/A18-tcp-user-timeout.md)
- [Ankane: The Ultimate Guide to Ruby Timeouts](https://github.com/ankane/the-ultimate-guide-to-ruby-timeouts)
