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

    # The cache table's surrogate primary key is not part of the materialized
    # result (the raw grouped query has none), so ignore it everywhere.
    IGNORED_COLUMNS = ["id"].freeze

    def tabular(label, served, ms, records)
      sample = records.first(SAMPLE_ROWS).map { |record| record.attributes.except(*IGNORED_COLUMNS) }
      Result.new(label: label, served: served, ms: ms, row_count: records.size,
                 columns: sample.first&.keys || [], rows: sample)
    end

    # Compare the full results order-independently: the raw query and the cache
    # may return rows in a different order, which is not a difference.
    def same_data?(raw_records, view_records)
      return false if raw_records.size != view_records.size

      shared = (attribute_keys(raw_records) & attribute_keys(view_records)) - IGNORED_COLUMNS
      normalize(raw_records, shared) == normalize(view_records, shared)
    end

    def attribute_keys(records)
      records.first&.attributes&.keys || []
    end

    def normalize(records, columns)
      records.map { |record| record.attributes.values_at(*columns) }.sort_by(&:to_s)
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
