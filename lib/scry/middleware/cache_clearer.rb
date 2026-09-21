# frozen_string_literal: true

module Scry
  module Middleware
    # Rack middleware that clears thread-local permission caches after each
    # request, preventing stale data from leaking across requests in
    # multi-threaded servers (Puma, Falcon, etc.).
    class CacheClearer
      # Manual cache clearing for non-Rack contexts. Call this at the end of
      # any non-HTTP execution context to prevent stale cached permissions:
      #
      #   # Sidekiq middleware:
      #   class SidekiqCacheClearer
      #     def call(_worker, _job, _queue)
      #       yield
      #     ensure
      #       Scry::Middleware::CacheClearer.clear_current_thread!
      #     end
      #   end
      #
      #   # ActiveJob callback:
      #   around_perform do |_job, block|
      #     block.call
      #   ensure
      #     Scry::Middleware::CacheClearer.clear_current_thread!
      #   end
      #
      #   # Custom threads:
      #   Thread.new do
      #     process_work
      #   ensure
      #     Scry::Middleware::CacheClearer.clear_current_thread!
      #   end
      def self.clear_current_thread!
        Scry.clear_thread_caches!
      end

      def initialize(app)
        @app = app
      end

      def call(env)
        @app.call(env)
      ensure
        Scry.clear_thread_caches!
      end
    end
  end
end
