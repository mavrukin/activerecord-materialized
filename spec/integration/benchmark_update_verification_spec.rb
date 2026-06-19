# frozen_string_literal: true

require "benchmark"

require "spec_helper"
require "pathname"

BENCHMARK_ROOT = Pathname.new(__dir__).join("..", "..", "benchmark").expand_path

RSpec.describe "benchmark update verification", :benchmark do
  before(:all) do
    @previous_connection = ActiveRecord::Base.remove_connection
    db_path = BENCHMARK_ROOT.join("fixtures", "job.sqlite")
    skip "Run `rake benchmark:setup` first" unless db_path.exist?

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_path.to_s)
    load BENCHMARK_ROOT.join("support", "benchmark_connection.rb")
    BenchmarkSupport.load_materialized_models!
  end

  after(:all) do
    ActiveRecord::Base.remove_connection
    ActiveRecord::Base.establish_connection(@previous_connection)
  end

  let(:view_class) { GenderPairingStatsView }

  it "refreshes in the background after dependency writes so reads stay fast" do
    baseline = view_class.where(gender: "f").pick(:role_pairings).to_i

    connection = ActiveRecord::Base.connection
    max_id = connection.select_value("SELECT COALESCE(MAX(id), 0) FROM cast_info").to_i
    person_id = connection.select_value("SELECT id FROM name WHERE gender = 'f' LIMIT 1")
    movie_id = connection.select_value("SELECT id FROM title WHERE production_year > 2000 LIMIT 1")

    connection.execute(
      "INSERT INTO cast_info (id, person_id, movie_id, person_role_id, note, nr_order, role_id) " \
      "VALUES (#{max_id + 1}, #{person_id}, #{movie_id}, 1, 'spec-update', 1, 2)"
    )

    expect(view_class.dirty?).to be(true)
    expect(view_class.where(gender: "f").pick(:role_pairings).to_i).to eq(baseline)

    ActiveRecord::Materialized::AsyncRefresher.flush!

    refreshed = view_class.where(gender: "f").pick(:role_pairings).to_i
    expect(refreshed).to be > baseline

    read_time = Benchmark.realtime { view_class.where(gender: "f").pick(:role_pairings) }
    expect(read_time).to be < 0.1
  end
end
