# frozen_string_literal: true

require "benchmark"

# Scenario registry plus the small amount of logic that powers the demo:
# comparing a query run the raw way vs. through its materialized view (including
# the read-through served from a cold, never-built view), refreshing a view,
# selecting which JOB database to run against, and mutating the underlying data.
module DemoComparison
  SAMPLE_ROWS = 8

  Scenario = Struct.new(:key, :label, :complexity, :view_name, :description, :raw_proc, keyword_init: true) do
    def view_class
      view_name.constantize
    end

    def raw_relation
      raw_proc.call
    end

    def sql
      raw_relation.to_sql
    end

    # True when the scenario's view depends on cast_info — the table the demo's
    # "insert cast rows" button mutates.
    def affected_by_mutation?
      view_class.dependency_tables.include?("cast_info")
    end
  end

  SCENARIOS = [
    Scenario.new(
      key: "production_notes",
      label: "Production notes",
      complexity: "Simple",
      view_name: "ProductionNotesView",
      description: "JOB query 1a — a four-table join with a couple of note filters.",
      raw_proc: -> { BenchmarkSources.production_notes_relation }
    ),
    Scenario.new(
      key: "gender_pairing",
      label: "Gender pairing stats",
      complexity: "Complex",
      view_name: "GenderPairingStatsView",
      description: "Aggregates cast pairings by gender across five joined tables. Depends on cast_info.",
      raw_proc: -> { BenchmarkSources.gender_pairing_stats_relation }
    ),
    Scenario.new(
      key: "person_movie_network",
      label: "Person–movie network",
      complexity: "Very complex",
      view_name: "PersonMovieNetworkView",
      description: "Builds a person/movie co-appearance network — the heaviest query in the set.",
      raw_proc: -> { BenchmarkSources.person_movie_network_relation }
    )
  ].freeze

  def self.find(key)
    SCENARIOS.find { |scenario| scenario.key == key }
  end

  # Self-heal the auto-refresh. A view that is materialized and dirty but not
  # currently refreshing means its scheduled background refresh was dropped or
  # failed (in-process :async only retries on new writes). Re-drive it so the
  # demo can never get permanently stuck "out of sync": ensure there is pending
  # maintenance to apply (a refresh with nothing pending is a no-op), then
  # re-schedule the async refresh.
  def self.ensure_refresh_progress(scenario)
    view = scenario.view_class
    return unless view.materialized? && view.dirty? && !view.refreshing?

    store = ActiveRecord::Materialized::MaintenanceStore.new(view)
    store.merge!(ActiveRecord::Materialized::MaintenanceDelta.full_partition) if store.pending.nil?
    ActiveRecord::Materialized::RefreshScheduler.schedule(view)
  rescue StandardError => e
    Rails.logger.warn("demo: could not re-drive refresh for #{scenario.key}: #{e.message}")
  end

  Result = Struct.new(:label, :served, :ms, :row_count, :columns, :rows, keyword_init: true)
  Comparison = Struct.new(:scenario, :raw, :view, :speedup, :matches, keyword_init: true)

  module Runner
    module_function

    # The headline action: run the query both ways and return them together so
    # the page can show the timings, the actual rows, and whether they agree.
    def compare(scenario)
      raw_records, raw_ms = run { scenario.raw_relation.to_a }
      view = scenario.view_class
      served = view.materialized? ? :cache : :read_through
      view_records, view_ms = run { view.all.to_a }

      Comparison.new(
        scenario: scenario,
        raw: tabular("Raw query", :source, raw_ms, raw_records),
        view: tabular(view_label(served), served, view_ms, view_records),
        speedup: view_ms.positive? ? (raw_ms / view_ms).round : nil,
        matches: same_data?(raw_records, view_records)
      )
    end

    def run
      result = nil
      ms = measure { result = yield }
      [result, ms]
    end

    # On a built (warm) view a read hits the cache table; on a cold view the gem
    # transparently reads through to the source, so one path shows both states.
    def view_label(served)
      served == :cache ? "Materialized view (cache)" : "View read-through (source)"
    end

    def refresh(scenario)
      view = scenario.view_class
      existed = view.materialized?
      result = nil
      ms = measure { result = view.rebuild!(confirm: true) }
      { verb: existed ? "Rebuilt" : "Built", ms: ms, row_count: result.row_count }
    end

    # Return a view to its "never built" state so the cold read-through can be
    # demonstrated again — drops the cache table and clears its metadata.
    def unbuild(scenario)
      view = scenario.view_class
      view.connection.drop_table(view.table_name, if_exists: true)
      view.reset_column_information
      view.metadata.record.update!(warm: false, dirty: true, last_refreshed_at: nil, row_count: nil)
      ActiveRecord::Materialized::PartitionState.new(view).reset!
    end

    def measure(&block)
      (Benchmark.realtime(&block) * 1000).round(2)
    end

    def tabular(label, served, ms, records)
      # The cache table's surrogate id is not part of the materialized result (the raw
      # grouped query has none), so drop it from the sample — reusing the single rule
      # ResultComparison also uses for the match verdict, so display and verdict agree.
      ignored = BenchmarkSupport::ResultComparison::IGNORED_COLUMNS
      sample = records.first(SAMPLE_ROWS).map { |record| record.attributes.except(*ignored) }
      Result.new(label: label, served: served, ms: ms, row_count: records.size,
                 columns: sample.first&.keys || [], rows: sample)
    end

    # Compare the full results order-independently (the raw query and the cache may
    # return rows in a different order, which is not a difference) — shared with the
    # CDC scenario's convergence check via BenchmarkSupport::ResultComparison.
    def same_data?(raw_records, view_records)
      BenchmarkSupport::ResultComparison.equivalent?(raw_records, view_records)
    end
  end

  module Mutation
    module_function

    INSERT_COUNT = Integer(ENV.fetch("DEMO_INSERT_COUNT", "5"))

    # Inserts cast_info rows for one post-2000 title, which fires the gem's
    # after_commit callbacks and marks every cast_info-dependent view dirty.
    def insert_cast_members!(count: INSERT_COUNT)
      movie_id = Job::Title.where(Job::Title.arel_table[:production_year].gt(2000)).limit(1).pick(:id)
      female_ids = Job::Name.where(gender: "f").limit(count).pluck(:id)
      base_id = Job::CastInfo.maximum(:id).to_i

      ActiveRecord::Base.transaction do
        female_ids.each_with_index do |person_id, offset|
          Job::CastInfo.create!(id: base_id + offset + 1, person_id: person_id, movie_id: movie_id,
                                person_role_id: 1, note: "demo-insert", nr_order: offset, role_id: 2)
        end
      end
      female_ids.size
    end
  end

  # Selecting which generated JOB database (medium / large / xlarge / …) the demo
  # runs against, and switching ActiveRecord to it at runtime.
  module Database
    module_function

    # The scales worth offering, smallest to largest, with a rough sense of the
    # speedup each one demonstrates (raw query time grows with the data; the
    # cache read stays sub-millisecond).
    STANDARD_SCALES = [
      { scale: "small", speedup: "~10×" },
      { scale: "medium", speedup: "~50×" },
      { scale: "large", speedup: "~1,000×" },
      { scale: "xlarge", speedup: "thousands ×" }
    ].freeze

    # Every standard scale, marked available when its database has been generated.
    def datasets
      generated = generated_by_scale
      STANDARD_SCALES.map do |entry|
        info = generated[entry[:scale]]
        path = info || default_path_for(entry[:scale])
        entry.merge(path: path, available: !info.nil?, current: File.expand_path(path) == current_path,
                    command: generate_command(entry[:scale]))
      end
    end

    def available
      datasets.select { |dataset| dataset[:available] }
    end

    def generated_by_scale
      candidates = Dir[File.join(fixtures_dir, "*.sqlite")] | [current_path]
      candidates.select { |path| File.file?(path) }.uniq.each_with_object({}) do |path, map|
        map[scale_of(path)] = path
      end
    end

    def default_path_for(scale)
      name = scale == "medium" ? "job.sqlite" : "job.#{scale}.sqlite"
      File.join(fixtures_dir, name)
    end

    def generate_command(scale)
      "JOB_DB=benchmark/fixtures/#{File.basename(default_path_for(scale))} " \
        "JOB_SCALE=#{scale} bundle exec rake benchmark:setup"
    end

    def current_path
      File.expand_path(ActiveRecord::Base.connection_db_config.database)
    end

    def use!(path)
      path = File.expand_path(path)
      return if path == current_path

      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: path, pool: 5, timeout: 5000)
      enable_wal!
      reset_schema_caches!
    end

    def enable_wal!
      ActiveRecord::Base.connection.execute("PRAGMA journal_mode=WAL")
    end

    def scale_of(path)
      marker = "#{path}.scale"
      File.exist?(marker) ? File.read(marker).strip : "unknown"
    end

    def fixtures_dir
      File.dirname(current_path)
    end

    # A new database has its own (lazily created) metadata + cache tables, so
    # drop the schema/metadata the gem memoised against the old one.
    def reset_schema_caches!
      [ActiveRecord::Materialized::MetadataRecord, ActiveRecord::Materialized::PartitionRecord]
        .each(&:reset_column_information)
      SCENARIOS.each do |scenario|
        view = scenario.view_class
        view.reset_column_information
        view.remove_instance_variable(:@metadata) if view.instance_variable_defined?(:@metadata)
      end
    end
  end

  module Dataset
    module_function

    def profile
      {
        scale: Database.scale_of(Database.current_path),
        cast_info: Job::CastInfo.count,
        titles: Job::Title.count,
        names: Job::Name.count
      }
    end
  end

  # The change-data-capture scenario: a raw SQL write to a dependency table —
  # bypassing ActiveRecord, so no after_commit callback fires — relayed through the
  # ingestion API to drive the callback-free CdcCompanyLinksView. It runs on the
  # reusable BenchmarkSupport::CdcScenario harness (the same one the integration
  # suite uses), and turns the harness Run into display steps for the animated
  # pipeline the view renders.
  module CdcDemo
    module_function

    VIEW_NAME = "CdcCompanyLinksView"
    LABEL = "Company links by type"

    Step = Struct.new(:title, :detail, :note, keyword_init: true)

    def view_class
      VIEW_NAME.constantize
    end

    # Build the view if cold so the scenario shows a converging *update*, then run the
    # raw-write → ingest → maintain → read flow through the shared harness.
    def run
      view_class.rebuild!(confirm: true) unless view_class.materialized?
      BenchmarkSupport::CdcScenario.new(view: view_class, raw_write: -> { raw_insert }).run
    end

    # A raw SQL INSERT issued straight on the connection, so it bypasses the model's
    # after_commit callbacks entirely. Returns the CDC descriptor a binlog/WAL
    # consumer would relay for this committed change.
    def raw_insert
      connection = view_class.connection
      company_type_id = Integer(connection.select_value("SELECT company_type_id FROM movie_companies LIMIT 1"))
      movie_id = Integer(connection.select_value("SELECT id FROM title LIMIT 1"))
      company_id = Integer(connection.select_value("SELECT id FROM company_name LIMIT 1"))
      next_id = Integer(connection.select_value("SELECT COALESCE(MAX(id), 0) + 1 FROM movie_companies"))
      connection.execute(
        "INSERT INTO movie_companies (id, movie_id, company_id, company_type_id, note) " \
        "VALUES (#{next_id}, #{movie_id}, #{company_id}, #{company_type_id}, 'cdc-demo')"
      )
      { table: "movie_companies", operation: :create, key_attributes: { "company_type_id" => company_type_id } }
    end

    # Map a harness Run onto the five pipeline stages the UI animates.
    def pipeline(run)
      company_type_id = run.descriptor[:key_attributes].values.first
      maintenance = event(run, :maintenance)
      refresh = event(run, :refresh)
      [
        Step.new(title: "Raw SQL write", detail: "INSERT INTO movie_companies … note='cdc-demo'",
                 note: "issued on the connection — no after_commit callback fires"),
        Step.new(title: "Change captured & relayed", detail: descriptor_call(run.descriptor),
                 note: "a binlog / WAL consumer would relay exactly this via ingest_change"),
        Step.new(title: "Scoped maintenance", detail: maintenance_detail(maintenance),
                 note: "only the partition the change touched — never a full rebuild"),
        Step.new(title: "Refresh applied", detail: refresh_detail(refresh),
                 note: "the cache row is recomputed in place"),
        Step.new(title: "Read converged", detail: convergence_detail(run, company_type_id),
                 note: run.converged? ? "the cache now matches the source relation" : "cache did NOT match source")
      ]
    end

    def event(run, stage)
      run.timeline.find { |recorded| recorded.stage == stage }
    end

    def descriptor_call(descriptor)
      keys = descriptor[:key_attributes].map { |name, value| "#{name.inspect} => #{value}" }.join(", ")
      "ingest_change(table: #{descriptor[:table].inspect}, operation: #{descriptor[:operation].inspect}, " \
        "key_attributes: {#{keys}})"
    end

    def maintenance_detail(event)
      return "no maintenance event" if event.nil?

      "scope: #{event.payload[:scope]} · partitions: #{event.payload[:partition_count]}"
    end

    def refresh_detail(event)
      return "no refresh event" if event.nil?

      "mode: #{event.payload[:mode]} · rows: #{event.payload[:row_count]}"
    end

    def convergence_detail(run, company_type_id)
      before = link_count(run.before_rows, company_type_id)
      after = link_count(run.after_rows, company_type_id)
      "company type #{company_type_id}: #{before} → #{after} links"
    end

    def link_count(rows, company_type_id)
      row = rows.find { |record| record.company_type_id == company_type_id }
      row&.link_count
    end
  end
end
