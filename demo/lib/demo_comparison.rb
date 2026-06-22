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

  Result = Struct.new(:label, :served, :ms, :row_count, :columns, :rows, keyword_init: true)
  Comparison = Struct.new(:scenario, :raw, :view, :speedup, :matches, keyword_init: true)

  module Runner
    module_function

    # The headline action: run the query both ways and return them together so
    # the page can show the timings, the actual rows, and whether they agree.
    def compare(scenario)
      raw = measure_raw(scenario)
      view = measure_view(scenario)
      speedup = view.ms.positive? ? (raw.ms / view.ms).round : nil
      Comparison.new(scenario: scenario, raw: raw, view: view, speedup: speedup, matches: rows_match?(raw, view))
    end

    def measure_raw(scenario)
      rows = nil
      ms = measure { rows = scenario.raw_relation.to_a }
      tabular("Raw query", :source, ms, rows)
    end

    # Reading through the View. On a built (warm) view this hits the cache table;
    # on a cold view the gem transparently reads through to the source query, so
    # this single path demonstrates both "no MV yet" and "fast cached read".
    def measure_view(scenario)
      view = scenario.view_class
      served = view.materialized? ? :cache : :read_through
      rows = nil
      ms = measure { rows = view.all.to_a }
      tabular(served == :cache ? "Materialized view (cache)" : "View read-through (source)", served, ms, rows)
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
      sample = records.first(SAMPLE_ROWS).map(&:attributes)
      Result.new(label: label, served: served, ms: ms, row_count: records.size,
                 columns: sample.first&.keys || [], rows: sample)
    end

    def rows_match?(raw, view)
      shared = raw.columns & view.columns
      return false if shared.empty?

      raw.rows.map { |row| row.values_at(*shared) } == view.rows.map { |row| row.values_at(*shared) }
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

    SCALE_ORDER = %w[small medium large xlarge stress unknown].freeze

    def available
      candidates = Dir[File.join(fixtures_dir, "*.sqlite")] | [current_path]
      candidates.select { |path| File.file?(path) }.uniq.map { |path| describe(path) }
                .sort_by { |db| SCALE_ORDER.index(db[:scale]) || SCALE_ORDER.size }
    end

    def describe(path)
      { path: path, name: File.basename(path), scale: scale_of(path), current: path == current_path }
    end

    def current_path
      File.expand_path(ActiveRecord::Base.connection_db_config.database)
    end

    def use!(path)
      path = File.expand_path(path)
      return if path == current_path

      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: path, pool: 5, timeout: 5000)
      reset_schema_caches!
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
end
