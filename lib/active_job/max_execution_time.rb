# frozen_string_literal: true

module ActiveJob
  # Declares an enforced upper bound on a job's wall-clock execution time.
  # When set, every TCP socket opened during `perform` gets TCP_USER_TIMEOUT
  # so the Linux kernel forcibly closes wedged connections at the deadline.
  # See SolidQueue::TcpConnection for the underlying mechanism.
  #
  #   class FetchUpstreamJob < ApplicationJob
  #     self.max_execution_time = 30.seconds
  #     def perform(...)
  #       Net::HTTP.get(...)
  #     end
  #   end
  module MaxExecutionTime
    extend ActiveSupport::Concern

    included do
      class_attribute :max_execution_time, instance_accessor: false

      around_perform do |job, block|
        if (max = job.class.max_execution_time)
          SolidQueue::TcpConnection.with_timeout(MaxExecutionTime.headroom_seconds(max)) { block.call }
        else
          block.call
        end
      end
    end

    # The TCP_USER_TIMEOUT we set is slightly less than max_execution_time
    # so the kernel kills the socket *before* any outer guard. At production
    # scales (10s+) we reserve a 5s headroom for the rescue handler; below
    # that we use 90% of max so very short timeouts still get enforced.
    def self.headroom_seconds(max)
      max_f = max.to_f
      max_f >= 10 ? max_f - 5 : max_f * 0.9
    end
  end
end
