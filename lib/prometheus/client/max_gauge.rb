# encoding: UTF-8

require 'prometheus/client/metric'

# need to be configured with a TTL?
# we want to send something down to the store on each increment/decrement/set
# but the annoying thing is that we don't have the actual value
# so we can introduce an intermediate metric store

module Prometheus
  module Client
    # A Gauge is a metric that exposes merely an instantaneous value or some
    # snapshot thereof.
    class MaxGauge < Metric
      def initialize(name,
                     docstring:,
                     labels: [],
                     preset_labels: {},
                     store_settings: {})
        ttl = store_settings.delete :ttl
        super
        @q = MaxQueue.new(@store, ttl)
      end

      def type
        :gauge
      end

      # Sets the value for the given label set
      def set(value, labels: {})
        unless value.is_a?(Numeric)
          raise ArgumentError, 'value must be a number'
        end

        @q.set(value, label_set_for(labels))
      end

      # Increments Gauge value by 1 or adds the given value to the Gauge.
      # (The value can be negative, resulting in a decrease of the Gauge.)
      def increment(by: 1, labels: {})
        label_set = label_set_for(labels)
        @q.increment(by, label_set)
      end

      # Decrements Gauge value by 1 or subtracts the given value from the Gauge.
      # (The value can be negative, resulting in a increase of the Gauge.)
      def decrement(by: 1, labels: {})
        label_set = label_set_for(labels)
        @q.increment(-by, label_set)
      end


      private

      class MaxQueue

        # @return [Numeric]
        attr_reader :current_max

        # @return [Numeric] sliding window size, in seconds
        attr_reader :ttl

        def initialize(store, ttl)
          @cleanup_q = Queue.new
          @lock = Mutex.new
          @store = store
          @ttl = ttl

          @trailing_history = []
          @current_max = 0

          start_worker_thread
          append Snapshot.new(0, {}, current_time)
        end

        def set(value, labels)
          @lock.synchronize do
            append Snapshot.new(value, labels, current_time)
          end
        end

        def increment(value, labels)
          @lock.synchronize do
            new_value = @trailing_history.last.value + value
            append Snapshot.new(new_value, labels, current_time)
          end
        end


        private

        Snapshot = Struct.new(:value, :labels, :timestamp)

        def current_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC_RAW)
        end

        def append(snapshot)
          if snapshot.value > @current_max
            @current_max = snapshot.value
            @store.set(labels: snapshot.labels, val: @current_max)
          end

          @trailing_history << snapshot
          @cleanup_q << snapshot
        end

        # @note You may only remove a snapshot if it is the oldest snapshot
        def remove(snapshot)
          oldest_snapshot = @trailing_history.shift

          # assert
          raise 'data inconsistency' unless snapshot.eql?(oldest_snapshot)

          # we need to keep at least one value in the history in order
          # for this system to work; this helps if we go through a quiet
          # period (longer than ttl)
          if @trailing_history.empty?
            oldest_snapshot.timestamp = current_time
            append oldest_snapshot
          end

          max_snapshot = @trailing_history.max { |lhs, rhs|
            lhs.value <=> rhs.value
          }

          @current_max = max_snapshot.value
          @store.set(labels: max_snapshot.labels, val: @current_max)
        end

        # Wait for the oldest snapshot to expire, and then clean it up
        # and update relevant state.
        def expire_next_snapshot
          snapshot = @cleanup_q.deq

          snapshot_age = current_time - snapshot.timestamp
          remaining_ttl = @ttl - snapshot_age
          if remaining_ttl.positive?
            sleep(remaining_ttl)
          end

          @lock.synchronize do
            remove(snapshot)
          end
        end

        def start_worker_thread
          Thread.new do
            loop do
              expire_next_snapshot
            end
          end
        end

      end

    end
  end
end
