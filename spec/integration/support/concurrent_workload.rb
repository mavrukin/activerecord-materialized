# frozen_string_literal: true

module BenchmarkSupport
  # Stresses a view under production-like load by running concurrent writer and reader
  # workers as separate SPAWNED processes (see concurrent_worker.rb) while the parent
  # rebuilds the view (atomic swaps) mid-flight — a less-idealized "distributed feel"
  # than fork-join-then-read. Spawned (not forked) workers each open their own clean
  # connection, so this works on Postgres too (libpq is not fork-safe). No sleep —
  # bounded iteration counts; assertions are on worker exit status + convergence.
  #
  # Convergence is checked after a final rebuild (a full, deterministic re-aggregation
  # from the now-quiescent source). Whether the *scoped* path converges without a
  # rebuild under concurrent maintenance is #75's concern (a cross-process lock);
  # asserting it here, pre-#75, would be racy. What this proves is the safety property:
  # no worker crashes, no writer loses a committed row, no reader sees a torn/empty
  # cache — and the system re-converges.
  class ConcurrentWorkload
    DEFAULT_SIZES = { writers: 4, readers: 2, writes: 15, reads: 40, rebuilds: 4 }.freeze
    GEM_ROOT = File.expand_path("../../..", __dir__)
    WORKER = File.expand_path("concurrent_worker.rb", __dir__)

    Result = Struct.new(:statuses, :converged, keyword_init: true) do
      def all_ok? = statuses.all?(&:zero?)
      def converged? = converged
    end

    def initialize(view:, adapter:, table:, sizes: {})
      @view = view
      @adapter = adapter # the IntegrationAdapters key (e.g. :postgres)
      @table = table     # the view's cache table name, so a worker can attach to it
      @sizes = DEFAULT_SIZES.merge(sizes)
    end

    def run
      pids = spawn_role("writer", @sizes[:writers], @sizes[:writes]) +
             spawn_role("reader", @sizes[:readers], @sizes[:reads])
      rebuild_during_storm
      statuses = reap(pids)
      @view.rebuild!(confirm: true) # storm over: deterministic re-aggregation from the source
      Result.new(statuses: statuses, converged: converged?)
    end

    private

    def spawn_role(role, count, iterations)
      Array.new(count) do |id|
        env = {
          "ARM_WORKER_ROLE" => role, "ARM_WORKER_ID" => id.to_s, "ARM_WORKER_ITERATIONS" => iterations.to_s,
          "ARM_WORKER_ADAPTER" => @adapter.to_s, "ARM_WORKER_TABLE" => @table
        }
        Process.spawn(env, Gem.ruby, WORKER, chdir: GEM_ROOT) # inherits ARM_*/BUNDLE_* env
      end
    end

    def rebuild_during_storm
      @sizes[:rebuilds].times do
        @view.rebuild!(confirm: true) # force atomic swaps while readers read
      rescue ActiveRecord::Materialized::Refresher::RefreshError
        nil # a worker holds the refresh guard / collides mid-cycle; skip (benign under concurrency)
      end
    end

    def reap(pids)
      pids.map do |pid|
        status = Process.wait2(pid).last
        unless status.success?
          warn "[concurrent_workload] worker #{pid} unclean: sig=#{status.termsig} exit=#{status.exitstatus}"
        end
        status.exitstatus || 1
      end
    end

    def converged?
      ResultComparison.equivalent?(@view.unscoped.to_a, @view.resolved_source.to_a)
    end
  end
end
