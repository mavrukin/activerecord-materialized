# frozen_string_literal: true

require_relative "integration_helper"
require_relative "support/concurrent_workload"

# Marker module (satisfies RSpec/DescribeClass + the spec-file-path convention) that also holds the
# storm profiles, so they aren't a constant declared inside the example group.
module Concurrency
  # Each ratio drives ~10k operations on the stressed path and ~1k on the other, across several
  # worker processes, while the parent keeps rebuilding for as long as any worker is alive.
  STORMS = {
    "write-heavy (~10k writes / 1k reads)" => { writers: 10, writes: 1_000, readers: 2, reads: 500 },
    "read-heavy (~1k writes / 10k reads)" => { writers: 2, writes: 500, readers: 10, reads: 1_000 }
  }.freeze
end

# #84/#91 — the less-idealized concurrency scenario, driven hard. Separate spawned worker processes
# mutate a scoped-recompute view via callbacks while other workers query it AND the parent rebuilds it
# (atomic swaps) mid-flight. Proves the safety property under real cross-process concurrency at volume:
# no worker crashes, writers' rows are durable, readers never see a torn/empty cache (the #81
# atomic-swap guarantee), and the system re-converges.
#
# #91 runs it at two adversarial ratios — write-heavy (~10k writes serializing on the per-view
# maintenance lock) and read-heavy (~10k reads racing the parent's atomic swaps) — so a light,
# happy-path run can't hide a load/concurrency defect. Runs on MySQL and Postgres — workers are
# spawned (not forked), so each opens its own clean connection (libpq is not fork-safe). SQLite is
# skipped: its in-process :memory: database isn't shared across separate processes.
RSpec.describe Concurrency, :db_matrix do
  IntegrationAdapters.candidates.each do |profile|
    context "with #{profile.label}" do
      before do
        skip("SQLite's in-process :memory: database isn't shared across separate processes") if profile.key == :sqlite
        with_adapter!(profile)
      end

      Concurrency::STORMS.each do |label, sizes|
        it "keeps concurrent writers, readers, and rebuilds correct and convergent — #{label}" do
          view = IntegrationSchema.define_scoped_view("mv_concurrent")
          IntegrationSchema.bulk_seed_line_items(200) # baseline so the cache is never legitimately empty
          view.rebuild!(confirm: true)

          result = BenchmarkSupport::ConcurrentWorkload.new(
            view: view, adapter: profile.key, table: "mv_concurrent", sizes: sizes
          ).run

          expect(result.all_ok?).to be(true)    # no worker crash/error; no torn/missing read (#81)
          expect(result.converged?).to be(true) # the system re-converges after the storm
        end
      end
    end
  end
end
