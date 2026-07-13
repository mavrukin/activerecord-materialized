# frozen_string_literal: true

require_relative "instrumentation_recorder"
require_relative "result_comparison"

module BenchmarkSupport
  # Drives — and validates — the CDC / raw-SQL-write story end to end against ANY
  # materialized view: perform a write that bypasses ActiveRecord (so no commit
  # callback fires), relay it through +ActiveRecord::Materialized.ingest_change+, and
  # confirm the view converges via SCOPED maintenance, all observed through the
  # engine's real instrumentation events.
  #
  # Schema-agnostic on purpose: the demo drives it with the JOB schema to visualize
  # the flow; the real-DB integration suite drives it with its own schema to assert
  # correctness on MySQL / Postgres. The verdicts ({Run#converged?}, {Run#scoped?})
  # are the reusable validation checks.
  #
  # The view should be fed by the ingestion API (+change_source :none+) and refresh
  # +:immediate+, so a relayed change is applied synchronously within {#run}.
  class CdcScenario
    Run = Struct.new(
      :descriptor, :timeline, :before_rows, :after_rows, :source_rows, :converged, :scoped,
      keyword_init: true
    ) do
      # The cache matches what the source relation would produce right now.
      def converged? = converged

      # Maintenance was scoped to the affected partition(s), never a full recompute.
      def scoped? = scoped
    end

    # view:      the materialized View subclass (a +change_source :none+ view).
    # raw_write: a proc that performs the out-of-band write (e.g.
    #            +connection.execute("INSERT ...")+) and returns the CDC descriptor
    #            hash (+{ table:, operation:, key_attributes:/before:/after: }+) a
    #            change-stream consumer would relay for it.
    def initialize(view:, raw_write:)
      @view = view
      @raw_write = raw_write
    end

    def run
      recorder = InstrumentationRecorder.new
      before = cache_rows
      descriptor = nil
      recorder.capture do
        descriptor = @raw_write.call                            # raw write — no callback fires
        ActiveRecord::Materialized.ingest_change(**descriptor)  # relayed via the CDC ingestion API
      end
      build_run(descriptor, recorder.for_view(@view), before)
    end

    private

    def build_run(descriptor, timeline, before)
      after = cache_rows
      source = source_rows
      Run.new(
        descriptor: descriptor, timeline: timeline, before_rows: before, after_rows: after,
        source_rows: source, converged: ResultComparison.equivalent?(after, source),
        scoped: scoped?(timeline)
      )
    end

    # Scoped when every maintenance the change drove was partition-scoped (and there
    # was at least one) — i.e. it never widened to a full recompute.
    def scoped?(timeline)
      maintenance = timeline.select { |event| event.stage == :maintenance }
      maintenance.any? && maintenance.all? { |event| event.payload[:scope] == :scoped }
    end

    def cache_rows
      @view.unscoped.to_a
    end

    def source_rows
      @view.resolved_source.to_a
    end
  end
end
