# frozen_string_literal: true

require "socket"

module SolidQueue
  # Sets TCP_USER_TIMEOUT on outbound TCP sockets so the Linux kernel drops
  # connections that have stopped making forward progress. Together with
  # ActiveJob::MaxExecutionTime, this turns a job's max_execution_time into
  # an enforced upper bound — the kernel kills wedged TCP reads/writes that
  # Ruby cannot interrupt with Thread#kill or Timeout.timeout.
  #
  # Linux only. macOS silently no-ops via Errno::ENOPROTOOPT (dev unaffected).
  #
  # See: https://man7.org/linux/man-pages/man7/tcp.7.html — TCP_USER_TIMEOUT
  module TcpConnection
    # TCP_USER_TIMEOUT optname from <linux/tcp.h>. Hardcoded because
    # Socket::TCP_USER_TIMEOUT isn't exposed across all Ruby versions.
    OPTNAME = 18

    THREAD_KEY = :solid_queue_tcp_user_timeout_ms

    class << self
      # Optional ceiling applied to every outbound TCP socket when no
      # per-job timeout is in effect. nil disables the global default.
      attr_accessor :global_default_seconds
    end

    # Run `block` with TCP_USER_TIMEOUT scoped to `seconds` for any socket
    # opened via Socket.tcp / TCPSocket.open inside the block.
    def self.with_timeout(seconds)
      ensure_hooks_installed!
      prev = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = (seconds.to_f * 1000).to_i
      yield
    ensure
      Thread.current[THREAD_KEY] = prev
    end

    # Apply the currently-scoped timeout (or the global default) to a socket.
    # Silently no-ops on platforms / sockets that don't support the option.
    def self.maybe_apply!(socket)
      ms = Thread.current[THREAD_KEY] || global_default_ms
      return unless ms && ms > 0
      socket.setsockopt(::Socket::SOL_TCP, OPTNAME, ms)
    rescue Errno::ENOPROTOOPT, Errno::EINVAL
      nil
    end

    # Idempotent — installs Socket / TCPSocket prepend hooks on first call.
    def self.install!
      return if @installed
      ::Socket.singleton_class.prepend(SocketHook)
      ::TCPSocket.singleton_class.prepend(TCPSocketHook)
      @installed = true
    end

    def self.installed?
      @installed == true
    end

    def self.global_default_ms
      seconds = global_default_seconds
      seconds && (seconds.to_f * 1000).to_i
    end

    def self.ensure_hooks_installed!
      install! unless installed?
    end

    module SocketHook
      def tcp(host, port, *args, **kwargs, &block)
        if block
          super(host, port, *args, **kwargs) do |sock|
            TcpConnection.maybe_apply!(sock)
            block.call(sock)
          end
        else
          sock = super(host, port, *args, **kwargs)
          TcpConnection.maybe_apply!(sock)
          sock
        end
      end
    end

    module TCPSocketHook
      def open(*args, **kwargs)
        sock = super
        TcpConnection.maybe_apply!(sock)
        sock
      end

      # TCPSocket.new is the constructor most code (including TCPSocket.open)
      # ultimately goes through. Hooking it covers paths that bypass `open`.
      def new(*args, **kwargs)
        sock = super
        TcpConnection.maybe_apply!(sock)
        sock
      end
    end
  end
end
