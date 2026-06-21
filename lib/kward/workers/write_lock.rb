require "thread"

module Kward
  module Workers
    # Cooperative ownership guard for workspace-mutating worker tools.
    class WriteLock
      def initialize
        @owner_id = nil
        @mutex = Mutex.new
      end

      attr_reader :owner_id

      def acquire(owner_id)
        owner = owner_id.to_s
        return false if owner.empty?

        @mutex.synchronize do
          return true if @owner_id == owner
          return false if @owner_id

          @owner_id = owner
          true
        end
      end

      def owned_by?(owner_id)
        @mutex.synchronize { @owner_id == owner_id.to_s }
      end

      def release(owner_id)
        @mutex.synchronize do
          @owner_id = nil if @owner_id == owner_id.to_s
        end
      end
    end
  end
end
