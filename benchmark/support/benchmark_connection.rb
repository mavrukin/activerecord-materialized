# frozen_string_literal: true

require "active_record"
require "pathname"

module BenchmarkSupport
  BENCHMARK_ROOT = Pathname.new(__dir__).join("..").expand_path
  GEM_ROOT = BENCHMARK_ROOT.join("..").expand_path

  def self.default_db_path
    ENV.fetch("JOB_DB", BENCHMARK_ROOT.join("fixtures", "job.sqlite").to_s)
  end

  def self.ensure_database!(db_path)
    return db_path if File.exist?(db_path)

    warn "Database not found at #{db_path}. Run: rake benchmark:setup"
    load BENCHMARK_ROOT.join("scripts", "generate_job_database.rb").to_s
    default_db_path
  end

  def self.connect!
    $LOAD_PATH.unshift GEM_ROOT.join("lib").to_s
    require "activerecord/materialized"
    require "active_support/time"

    Time.zone = "UTC"

    db_path = ensure_database!(default_db_path)
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_path)
    require_relative "source_relations"
    load_materialized_models!
    db_path
  end

  def self.load_job_models!
    require_relative "job_models"
    Job.register_models!
  end

  def self.load_materialized_models!
    load_job_models!
    Dir[BENCHMARK_ROOT.join("materialized_models", "*.rb")].each { |file| require file }
  end

  def self.timed(iterations: Integer(ENV.fetch("BENCH_ITERATIONS", "3")))
    times = []
    result = nil
    iterations.times do
      elapsed = Benchmark.realtime { result = yield }
      times << elapsed
    end
    [times.sum / times.size, result]
  end
end

require "benchmark"
