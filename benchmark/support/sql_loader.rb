# frozen_string_literal: true

module BenchmarkSupport
  module SqlLoader
    module_function

    def load(relative_path)
      path = BENCHMARK_ROOT.join("queries", relative_path)
      strip_sql_comments(File.read(path))
    end

    def strip_sql_comments(sql)
      sql.lines.reject { |line| line.strip.start_with?("--") }.join.strip
    end
  end
end
