# frozen_string_literal: true

module BenchmarkSupport
  module TableFormatter
    module_function

    COMPARE_HEADER = {
      query: "Query",
      raw: "Raw (s)",
      mv_read: "MV read (s)",
      refresh: "Refresh(ms)",
      speedup: "Speedup"
    }.freeze

    COMPARE_ROW = "%<query>-35s %<raw>12.4f %<mv_read>12.4f %<refresh>10d %<speedup>8.1fx\n"

    SLOW_HEADER = {
      query: "Query",
      raw: "Raw (s)",
      mv_read: "MV read (s)",
      refresh: "Refresh(ms)",
      speedup: "Speedup",
      check: "Check"
    }.freeze

    SLOW_ROW = "%<query>-28s %<raw>12.4f %<mv_read>12.4f %<refresh>10d %<speedup>8.1fx %<check>6s\n"

    VERIFY_HEADER = {
      stage: "Stage",
      time: "Time",
      pairings: "female pairings"
    }.freeze

    VERIFY_ROW = "%<stage>-36s %<time>14s %<pairings>14d\n"

    def print_compare_header
      printf("%<query>-35s %<raw>12s %<mv_read>12s %<refresh>10s %<speedup>8s\n", COMPARE_HEADER)
    end

    def print_compare_row(row)
      printf(COMPARE_ROW, row)
    end

    def print_slow_header
      printf("%<query>-28s %<raw>12s %<mv_read>12s %<refresh>10s %<speedup>8s %<check>6s\n", SLOW_HEADER)
    end

    def print_slow_row(row)
      printf(SLOW_ROW, row)
    end

    def print_verify_header
      printf("%<stage>-36s %<time>14s %<pairings>14s\n", VERIFY_HEADER)
    end

    def print_verify_row(row)
      printf(VERIFY_ROW, row)
    end
  end
end
