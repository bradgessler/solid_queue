# frozen_string_literal: true

require "test_helper"
require "socket"

# Reproduces the wedge problem from issue #943: a thread parked in a blocking
# TCP syscall against a server that never makes forward progress. Today
# `max_execution_time` is not a class attribute on ActiveJob, and even if it
# were, Ruby has no way to kill a thread stuck in the kernel — `Thread#kill`
# and `Timeout.timeout` only fire when the thread returns to user space.
#
# This test runs on Linux only (TCP_USER_TIMEOUT is Linux-specific). It is
# expected to FAIL until the fix lands: today the API doesn't exist and the
# kernel has no idea what to do.
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

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    err = nil
    Timeout.timeout(10, RuntimeError, "wedge not enforced — job ran longer than 10s") do
      err = assert_raises(StandardError) do
        klass.perform_now("127.0.0.1", @port)
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2.5,
      "expected job to die within ~1s, took #{elapsed.round(2)}s. Error: #{err.class}: #{err.message}"
    assert (Errno::ETIMEDOUT === err) || (IO::TimeoutError === err),
      "expected ETIMEDOUT or IO::TimeoutError, got #{err.class}: #{err.message}"
  end
end
