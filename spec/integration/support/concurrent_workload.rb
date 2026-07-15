# frozen_string_literal: true

require_relative "../../../benchmark/support/result_comparison"

module BenchmarkSupport
  # Stresses a view under production-like load by running concurrent writer and reader
  # workers as separate SPAWNED processes (see concurrent_worker.rb) while the parent
  # rebuilds the view (atomic swaps) mid-flight — a less-idealized "distributed feel"
  # than fork-join-then-read. Spawned (not forked) workers each open their own clean
  # connection, so this works on Postgres too (libpq is not fork-safe). No sleep —
  # bounded iteration counts; assertions are on worker exit status + convergence.
  #
  # The parent keeps rebuilding for as long as any worker is alive (reaping each as it
  # exits), so reader queries run concurrently with the parent's atomic swaps — the
  # window the #81 no-torn-read guarantee protects. A fixed count of rebuilds would
  # instead finish during the workers' ~500ms boot, before a single query is issued,
  # and exercise nothing.
  #
  # Convergence is checked after a final rebuild (a full, deterministic re-aggregation
  # from the now-quiescent source). Whether the *scoped* path converges without a
  # rebuild under concurrent maintenance is #75's concern (a cross-process lock);
  # asserting it here, pre-#75, would be racy. What this proves is the safety property:
  # no worker crashes, no writer loses a committed row, no reader sees a torn/empty
  # cache — and the system re-converges.
  class ConcurrentWorkload
    # reads is well above writes so readers stay alive across many parent swap cycles
    # (each read is cheap); the rebuild loop is bounded by that worker lifetime.
    DEFAULT_SIZES = { writers: 4, readers: 2, writes: 15, reads: 500 }.freeze
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
      statuses = rebuild_while_workers_run(pids) # atomic swaps overlap live reads + writes
      @view.rebuild!(confirm: true)              # storm over: deterministic re-aggregation
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

    # Rebuild the view repeatedly for the whole time the workers run, so an atomic swap
    # overlaps their in-flight queries; reap each worker as it exits (non-blocking) and
    # return exit statuses in pid order. Each turn does a real rebuild (DB I/O), which
    # paces the loop without a sleep.
    def rebuild_while_workers_run(pids)
      statuses = {}
      until statuses.size == pids.size
        rebuild_once
        pids.each do |pid|
          next if statuses.key?(pid)

          reaped, status = Process.wait2(pid, Process::WNOHANG)
          statuses[pid] = exit_code(status) if reaped
        end
      end
      pids.map { |pid| statuses.fetch(pid) }
    end

    def rebuild_once
      @view.rebuild!(confirm: true) # force an atomic swap while readers read
    rescue ActiveRecord::Materialized::Refresher::RefreshError
      nil # a worker holds the refresh guard / collides mid-cycle; skip (benign under concurrency)
    end

    def exit_code(status)
      unless status.success?
        warn "[concurrent_workload] worker unclean: sig=#{status.termsig} exit=#{status.exitstatus}"
      end
      status.exitstatus || 1
    end

    def converged?
      ResultComparison.converged?(@view)
    end
  end
end
