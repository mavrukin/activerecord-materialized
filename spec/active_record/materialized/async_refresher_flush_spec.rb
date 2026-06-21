# frozen_string_literal: true

require "benchmark"

require "spec_helper"
require "pathname"

BENCHMARK_ROOT = Pathname.new(__dir__).join("..", "..", "..", "benchmark").expand_path

BENCHMARK_RELATION_NAMES = %i[
  gender_pairing_stats_relation company_movie_cross_relation person_movie_network_relation
  cast_coappearance_relation production_notes_relation voicing_actresses_relation
  russian_voice_actors_relation
].freeze

module AsyncRefresherFlushHelpers
  module_function

  def create_cast_row!
    max_id = Job::CastInfo.maximum(:id).to_i
    person_id = Job::Name.where(gender: "f").pick(:id)
    movie_id = Job::Title.where(Job::Title.arel_table[:production_year].gt(2000)).pick(:id)

    Job::CastInfo.create!(
      id: max_id + 1,
      person_id: person_id,
      movie_id: movie_id,
      person_role_id: 1,
      note: "spec-update",
      nr_order: 1,
      role_id: 2
    )
  end
end

RSpec.describe ActiveRecord::Materialized::AsyncRefresher, :benchmark do
  around do |example|
    previous_connection = ActiveRecord::Base.remove_connection
    db_path = BENCHMARK_ROOT.join("fixtures", "job.sqlite")
    skip "Run `rake benchmark:setup` first" unless db_path.exist?

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_path.to_s)
    load BENCHMARK_ROOT.join("support", "benchmark_connection.rb")
    require BENCHMARK_ROOT.join("support", "source_relations.rb").to_s
    BenchmarkSupport.load_materialized_models!

    example.run
  ensure
    ActiveRecord::Base.remove_connection
    ActiveRecord::Base.establish_connection(previous_connection) if previous_connection
  end

  describe ".flush!" do
    let(:view_class) { GenderPairingStatsView }

    before do
      described_class.reset!
      view_class.metadata.clear_maintenance_payload!
      ActiveRecord::Materialized::DependencyRegistry.register(view_class, view_class.dependency_tables)
      view_class.rebuild!(confirm: true)
    end

    it "refreshes in the background after dependency writes so reads stay fast" do
      baseline = view_class.where(gender: "f").pick(:role_pairings).to_i
      AsyncRefresherFlushHelpers.create_cast_row!

      expect(view_class.dirty?).to be(true)
      expect(view_class.where(gender: "f").pick(:role_pairings).to_i).to eq(baseline)

      described_class.flush!

      refreshed = view_class.where(gender: "f").pick(:role_pairings).to_i
      expect(refreshed).to be > baseline

      read_time = Benchmark.realtime { view_class.where(gender: "f").pick(:role_pairings) }
      expect(read_time).to be < 0.1
    end
  end

  # Source relations are not otherwise executed by the suite, so a relation that
  # compiles to invalid SQL (e.g. an Arel join wrapped as a derived table) only
  # surfaces when someone actually runs it. Execute each one here.
  describe "source relations" do
    it "compiles and executes every relation as valid SQL" do
      failures = BENCHMARK_RELATION_NAMES.filter_map do |name|
        BenchmarkSources.public_send(name).limit(1).to_a
        nil
      rescue ActiveRecord::StatementInvalid => e
        "#{name}: #{e.message.lines.first&.strip}"
      end

      expect(failures).to be_empty, "relations with invalid SQL:\n#{failures.join("\n")}"
    end
  end
end
