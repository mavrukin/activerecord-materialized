# frozen_string_literal: true

module BenchmarkSupport
  # Forks concurrent writer and reader processes against a real database to stress a
  # view under production-like load: writers mutate a scoped-recompute view (callback
  # + immediate maintenance) while readers continuously query it AND the parent
  # triggers rebuilds (atomic swaps) mid-flight. Deliberately less idealized than a
  # fork-join-then-read — reads happen *during* writes and swaps.
  #
  # Fork hygiene: the parent disconnects before forking so no live socket is inherited
  # (native DB drivers are not fork-safe); every process — children and parent — then
  # opens its own connection. Children terminate with exit! (skipping RSpec's at_exit
  # in the fork); pass/fail travels via exit status. No sleep — bounded iteration
  # counts; assertions are on exit status + convergence, not timing.
  #
  # Convergence is checked after a final rebuild (a full, deterministic re-aggregation
  # from the now-quiescent source). Whether the *scoped* path converges without a
  # rebuild under concurrent maintenance is #75's concern (a cross-process lock);
  # asserting it here, pre-#75, would be racy. What this proves is the safety property:
  # no process crashes, no writer loses a committed row, no reader sees a torn/empty
  # cache — and the system re-converges.
  class ConcurrentWorkload
    DEFAULT_SIZES = { writers: 4, readers: 2, writes: 15, reads: 40, rebuilds: 4 }.freeze

    Result = Struct.new(:statuses, :converged, keyword_init: true) do
      def all_ok? = statuses.all?(&:zero?)
      def converged? = converged
    end

    def initialize(view:, config:, write:, sizes: {})
      @view = view
      @config = config
      @write = write # ->(worker, i) performing one write on the view's dependency
      @sizes = DEFAULT_SIZES.merge(sizes)
    end

    def run
      ActiveRecord::Base.connection_handler.clear_all_connections! # no live connection inherited across fork
      pids = fork_writers + fork_readers
      reconnect! # the parent's own connection for the mid-flight rebuilds
      rebuild_during_storm
      statuses = reap(pids)
      @view.rebuild!(confirm: true) # storm over: deterministic re-aggregation from the source
      Result.new(statuses: statuses, converged: converged?)
    end

    private

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
          warn "[concurrent_workload] child #{pid} unclean: sig=#{status.termsig} exit=#{status.exitstatus}"
        end
        status.exitstatus || 1
      end
    end

    def fork_writers
      Array.new(@sizes[:writers]) { |worker| child { write_batch(worker) } }
    end

    def fork_readers
      Array.new(@sizes[:readers]) { child { read_loop } }
    end

    # A write always commits, but its immediate maintenance may transiently defer under
    # concurrency — another process holds the refresh guard (AlreadyRefreshingError) or a
    # rebuild's DDL collides with the maintenance query. Both are RefreshErrors and both
    # are benign here: the row is durable and the system re-converges. #75 (cross-process
    # lock) removes these defers in production.
    def write_batch(worker)
      @sizes[:writes].times do |i|
        @write.call(worker, i)
      rescue ActiveRecord::Materialized::Refresher::RefreshError
        nil
      end
    end

    # A reader must never see a torn/empty cache — the direct proof that a rebuild's
    # swap is atomic (#81) and that scoped maintenance is transactional.
    def read_loop
      @sizes[:reads].times do
        raise "torn read: empty cache during concurrent maintenance" if @view.unscoped.none?
      end
    end

    def child(&block)
      fork do
        reconnect! # parent cleared before forking, so this opens a fresh connection
        ok = run_child(&block)
        $stderr.flush # exit! skips stdio flushing, which would drop the failure warning
        exit!(ok ? 0 : 1)
      end
    end

    def run_child
      yield
      true
    rescue StandardError => e
      warn "[concurrent_workload] #{e.class}: #{e.message.lines.first&.strip}"
      false
    end

    def reconnect!
      ActiveRecord::Base.establish_connection(@config)
    end

    def converged?
      ResultComparison.equivalent?(@view.unscoped.to_a, @view.resolved_source.to_a)
    end
  end
end
