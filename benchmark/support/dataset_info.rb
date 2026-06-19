# frozen_string_literal: true

module BenchmarkSupport
  SCALE_THRESHOLDS = {
    "small" => 0,
    "medium" => 50_000,
    "large" => 400_000,
    "xlarge" => 1_500_000,
    "stress" => 5_000_000
  }.freeze

  SLOW_BENCHMARK_MIN_CAST_INFO = 1_500_000

  DatasetStats = Struct.new(
    :cast_info_rows,
    :title_rows,
    :movie_companies_rows,
    :detected_scale,
    :scale_file,
    keyword_init: true
  ) do
    def sufficient_for_slow_benchmark?
      cast_info_rows >= SLOW_BENCHMARK_MIN_CAST_INFO
    end
  end

  module DatasetInfo
    module_function

    def collect(connection: ActiveRecord::Base.connection, db_path: default_db_path)
      cast_info_rows = count_rows(connection, "cast_info")
      title_rows = count_rows(connection, "title")
      movie_companies_rows = count_rows(connection, "movie_companies")
      scale_file = scale_file_for(db_path)

      DatasetStats.new(
        cast_info_rows: cast_info_rows,
        title_rows: title_rows,
        movie_companies_rows: movie_companies_rows,
        detected_scale: detect_scale(cast_info_rows, scale_file),
        scale_file: scale_file
      )
    end

    def print_report(stats)
      puts "Dataset profile:"
      puts "  detected scale: #{stats.detected_scale}"
      puts formatted_row("cast_info rows", stats.cast_info_rows)
      puts formatted_row("title rows", stats.title_rows)
      puts formatted_row("movie_companies rows", stats.movie_companies_rows)
      puts "  scale marker:   #{stats.scale_file || 'none (run benchmark:setup to create)'}"
      puts
    end

    def formatted_row(label, count)
      formatted_count = count.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
      "  #{label}: #{formatted_count}"
    end

    def ensure_slow_benchmark!(stats)
      return if stats.sufficient_for_slow_benchmark?

      warn <<~MSG

        ERROR: Database is too small for the slow-query benchmark.

        Detected #{stats.detected_scale} scale (#{stats.cast_info_rows} cast_info rows).
        Slow benchmarks require at least #{SLOW_BENCHMARK_MIN_CAST_INFO} cast_info rows (xlarge or stress).

        Regenerate the database:

          JOB_SCALE=xlarge bundle exec rake benchmark:setup
          bundle exec rake benchmark:slow

        For consistently multi-second queries on fast hardware, use stress:

          JOB_SCALE=stress bundle exec rake benchmark:setup
          bundle exec rake benchmark:slow

      MSG
      exit 1
    end

    def detect_scale(cast_info_rows, scale_file)
      return File.read(scale_file).strip if scale_file && File.exist?(scale_file)

      SCALE_THRESHOLDS.sort_by { |_name, min| -min }.find { |_name, min| cast_info_rows >= min }&.first || "unknown"
    end

    def scale_file_for(db_path)
      "#{db_path}.scale"
    end

    def default_db_path
      ENV.fetch("JOB_DB", BenchmarkSupport::BENCHMARK_ROOT.join("fixtures", "job.sqlite").to_s)
    end

    def count_rows(connection, table)
      connection.select_value("SELECT COUNT(*) FROM #{table}").to_i
    end
  end
end
