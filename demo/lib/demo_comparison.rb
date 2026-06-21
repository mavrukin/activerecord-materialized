# frozen_string_literal: true

require "benchmark"

# Scenario registry plus the small amount of logic that powers the demo:
# running a query the raw way vs. through its materialized view, refreshing a
# view, and mutating the underlying data.
module DemoComparison
  SAMPLE_ROWS = 12

  Scenario = Struct.new(:key, :label, :complexity, :view_name, :description, :raw_proc, keyword_init: true) do
    def view_class
      view_name.constantize
    end

    def raw_relation
      raw_proc.call
    end

    # True when the scenario's view depends on cast_info — the table the demo's
    # "insert a cast member" button mutates.
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

  Result = Struct.new(:scenario, :mode, :ms, :row_count, :columns, :rows, :note, keyword_init: true)

  module Runner
    module_function

    def raw(scenario)
      rows = nil
      ms = measure { rows = scenario.raw_relation.to_a }
      tabular(scenario, "Raw query", ms, rows)
    end

    def materialized(scenario)
      view = scenario.view_class
      unless view.table_exists?
        return Result.new(scenario: scenario, mode: "Materialized view", columns: [], rows: [],
                          note: "Not built yet — click “Build / refresh” first.")
      end

      rows = nil
      ms = measure { rows = view.all.to_a }
      tabular(scenario, "Materialized view", ms, rows)
    end

    def refresh(scenario)
      view = scenario.view_class
      existed = view.table_exists?
      result = nil
      ms = measure { result = view.refresh! }
      verb = existed ? "Refreshed the cache table" : "Bootstrapped the cache table"
      Result.new(scenario: scenario, mode: "Build / refresh", ms: ms, row_count: result.row_count,
                 columns: [], rows: [], note: "#{verb} — #{result.row_count} rows materialized.")
    end

    def measure(&block)
      (Benchmark.realtime(&block) * 1000).round(2)
    end

    def tabular(scenario, mode, ms, records)
      sample = records.first(SAMPLE_ROWS).map(&:attributes)
      Result.new(scenario: scenario, mode: mode, ms: ms, row_count: records.size,
                 columns: sample.first&.keys || [], rows: sample, note: nil)
    end
  end

  module Mutation
    module_function

    # Inserts a new cast_info row, which fires the gem's after_commit callbacks
    # and marks every view that depends on cast_info dirty.
    def insert_cast_member!
      Job::CastInfo.create!(
        id: Job::CastInfo.maximum(:id).to_i + 1,
        person_id: Job::Name.where(gender: "f").limit(1).pick(:id),
        movie_id: Job::Title.where(Job::Title.arel_table[:production_year].gt(2000)).limit(1).pick(:id),
        person_role_id: 1,
        note: "demo-insert",
        nr_order: 1,
        role_id: 2
      )
    end
  end

  module Dataset
    module_function

    def profile
      {
        scale: detect_scale,
        cast_info: Job::CastInfo.count,
        titles: Job::Title.count,
        names: Job::Name.count
      }
    end

    def detect_scale
      database = ActiveRecord::Base.connection_db_config.database
      marker = "#{database}.scale"
      File.exist?(marker) ? File.read(marker).strip : "unknown"
    end
  end
end
