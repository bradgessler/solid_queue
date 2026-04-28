# frozen_string_literal: true

require "test_helper"
require "socket"

# Reproduces the wedge problem from issue #943: a thread parked in a blocking
# TCP syscall against a server that never makes forward progress. Today
# `max_execution_time` is not enforced — Ruby has no way to kill a thread
# stuck in the kernel. The fix sets TCP_USER_TIMEOUT on the underlying socket
# so the Linux kernel itself drops the connection.
#
# These tests run on Linux only (TCP_USER_TIMEOUT is Linux-specific). On
# macOS dev they are skipped; CI / Docker validates the contract.
class TcpUserTimeoutTest < ActiveSupport::TestCase
  LINUX = RUBY_PLATFORM.include?("linux")

  setup do
    skip "TCP_USER_TIMEOUT is Linux-only" unless LINUX

    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @held = []
    @accept_thread = Thread.new do
      loop do
        @held << @server.accept
      rescue IOError, Errno::EBADF
        break
      end
    end
  end

  teardown do
    @accept_thread&.kill
    @held&.each { |s| s.close rescue nil }
    @server&.close rescue nil
    SolidQueue::TcpConnection.global_default_seconds = nil
    Thread.current[SolidQueue::TcpConnection::THREAD_KEY] = nil
  end

  test "max_execution_time aborts a wedged TCP write at the deadline" do
    klass = Class.new(ApplicationJob) do
      self.max_execution_time = 1.second

      def perform(host, port)
        sock = TCPSocket.open(host, port)
        # Pump bytes until the receive buffer fills and writes go unacked.
        # Without TCP_USER_TIMEOUT this thread would park indefinitely.
        buf = "x" * 64_000
        loop { sock.write(buf) }
      end
    end

    elapsed, err = measure { klass.perform_now("127.0.0.1", @port) }

    assert_operator elapsed, :<, 2.5,
      "expected job to die within ~1s, took #{elapsed.round(2)}s. Error: #{err.class}: #{err.message}"
    assert (Errno::ETIMEDOUT === err) || (IO::TimeoutError === err),
      "expected ETIMEDOUT or IO::TimeoutError, got #{err.class}: #{err.message}"
  end

  test "no max_execution_time means thread-local stays unset during perform" do
    # A job WITHOUT max_execution_time should not enter with_timeout, so the
    # thread-local stays nil and maybe_apply! short-circuits before setsockopt.
    observed = :unobserved
    klass = Class.new(ApplicationJob) do
      define_method(:perform) do
        observed = Thread.current[SolidQueue::TcpConnection::THREAD_KEY]
      end
    end

    klass.perform_now
    assert_nil observed
  end

  test "TcpConnection.with_timeout nests and restores thread-local on exception" do
    SolidQueue::TcpConnection.with_timeout(60) do
      assert_equal 60_000, Thread.current[SolidQueue::TcpConnection::THREAD_KEY]
      SolidQueue::TcpConnection.with_timeout(5) do
        assert_equal 5_000, Thread.current[SolidQueue::TcpConnection::THREAD_KEY]
      end
      assert_equal 60_000, Thread.current[SolidQueue::TcpConnection::THREAD_KEY]
    end
    assert_nil Thread.current[SolidQueue::TcpConnection::THREAD_KEY]

    # Restore on exception
    assert_raises(ExpectedTestError) do
      SolidQueue::TcpConnection.with_timeout(10) do
        raise ExpectedTestError
      end
    end
    assert_nil Thread.current[SolidQueue::TcpConnection::THREAD_KEY]
  end

  test "global default applies when no per-block timeout is in effect" do
    SolidQueue::TcpConnection.global_default_seconds = 1
    SolidQueue::TcpConnection.install!

    elapsed, err = measure do
      sock = TCPSocket.open("127.0.0.1", @port)
      buf = "x" * 64_000
      loop { sock.write(buf) }
    end

    assert_operator elapsed, :<, 2.5,
      "expected global default to fire ~1s, took #{elapsed.round(2)}s (#{err.class})"
  end

  test "in-block timeout tightens below the global default" do
    SolidQueue::TcpConnection.global_default_seconds = 60
    SolidQueue::TcpConnection.install!

    elapsed, err = measure do
      SolidQueue::TcpConnection.with_timeout(1) do
        sock = TCPSocket.open("127.0.0.1", @port)
        buf = "x" * 64_000
        loop { sock.write(buf) }
      end
    end

    assert_operator elapsed, :<, 2.5,
      "expected in-block timeout to tighten to ~1s, took #{elapsed.round(2)}s (#{err.class})"
  end

  test "thread-local does not leak across threads" do
    SolidQueue::TcpConnection.with_timeout(5) do
      assert_equal 5_000, Thread.current[SolidQueue::TcpConnection::THREAD_KEY]
      Thread.new do
        assert_nil Thread.current[SolidQueue::TcpConnection::THREAD_KEY]
      end.join
    end
  end

  test "MaxExecutionTime.headroom_seconds reserves headroom at production scales" do
    assert_in_delta 0.9,  ActiveJob::MaxExecutionTime.headroom_seconds(1.second),    0.001
    assert_in_delta 1.8,  ActiveJob::MaxExecutionTime.headroom_seconds(2.seconds),   0.001
    # At 10s and above, reserve a 5s headroom for the rescue handler
    assert_in_delta 5.0,  ActiveJob::MaxExecutionTime.headroom_seconds(10.seconds),  0.001
    assert_in_delta 25.0, ActiveJob::MaxExecutionTime.headroom_seconds(30.seconds),  0.001
    assert_in_delta 595,  ActiveJob::MaxExecutionTime.headroom_seconds(10.minutes),  0.001
  end

  private
    def measure
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      err = nil
      Timeout.timeout(10, RuntimeError, "wedge not enforced — ran longer than 10s") do
        err = assert_raises(StandardError) { yield }
      end
      [ Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, err ]
    end
end
